import Foundation
import CoreFoundation
import Darwin

/// Only process/version/clock metadata and bounded allowlisted timing events.
/// No research fields, user filenames or settings are accepted.
final class ResearchStartupDiagnosticsFile {
    enum Failure: Error { case unsafe, unsafeDirectory, unsafeFile, changedDuringRead, unavailable, invalid }
    static let maximumBytes = 48 * 1024
    static let defaultDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/GaoSeries/Research/StartupDiagnostics.noindex", isDirectory: true)
    let directory: URL
    let filename: String
    private let processID: Int32
    private let appVersion: String
    private let build: String
    var fileURL: URL { directory.appendingPathComponent(filename) }
    private let queue = DispatchQueue(label: "com.academic-achievement.manager.startup-timing", qos: .utility)
    private let pendingLock = NSLock()
    private var pending: Data?
    private var scheduled = false
    private var failed = false
    private var latestOfferedCount = 0

    init(directory: URL, processID: Int32 = getpid(), appVersion: String, build: String) {
        self.directory = directory
        self.processID = processID
        self.appVersion = appVersion
        self.build = build
        filename = "startup-\(processID)-\(UUID().uuidString).json"
    }
    func enqueue(_ data: Data) {
        guard data.count <= Self.maximumBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let rows = object as? [[String: Any]],
              !rows.isEmpty, rows.count <= 128 else { return }
        pendingLock.lock()
        // Concurrent mark callers can offer an older snapshot after a newer
        // one. Event count is monotonic; never let a late offer regress the file.
        guard !failed, rows.count > latestOfferedCount else { pendingLock.unlock(); return }
        latestOfferedCount = rows.count
        pending = data
        if scheduled { pendingLock.unlock(); return }
        scheduled = true
        // One queued writer at most; later marks replace its pending snapshot.
        queue.async { self.drain() }
        pendingLock.unlock()
    }
    func flush() {
        pendingLock.lock(); pendingLock.unlock()
        queue.sync {}
    }
    private func drain() {
        while true {
            pendingLock.lock()
            guard let data = pending else { scheduled = false; pendingLock.unlock(); return }
            pending = nil
            pendingLock.unlock()
            do { try publish(data) } catch {
                pendingLock.lock(); failed = true; pending = nil; scheduled = false; pendingLock.unlock()
                let code = (error as? Failure).map { String(describing: $0) } ?? "io"
                NSLog("Research startup timing-file unavailable code=%@", code)
                return
            }
        }
    }
    /// Walk with directory descriptors, refusing symlink ancestors before IO.
    private static func openDirectory(_ url: URL, create: Bool) throws -> Int32 {
        let path = url.path
        // Foundation can canonicalize an existing /private/tmp path to /tmp.
        // Do not compare filesystem-dependent URL standardizations; validate
        // lexical components and walk every ancestor with O_NOFOLLOW instead.
        guard url.isFileURL, path.hasPrefix("/"), path != "/", !path.contains("//"),
              !path.utf8.contains(0), !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
        else { throw Failure.unsafe }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.unavailable }
        do {
            for component in path.split(separator: "/").map(String.init) {
                var next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                if next < 0 && errno == ENOENT && create {
                    guard mkdirat(fd, component, 0o700) == 0 || errno == EEXIST else { throw Failure.unavailable }
                    next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                }
                guard next >= 0 else { throw Failure.unsafe }
                close(fd); fd = next
            }
            var st = stat()
            guard fstat(fd, &st) == 0, st.st_uid == getuid(), st.st_mode & S_IFMT == S_IFDIR,
                  st.st_mode & 0o777 == 0o700 else { throw Failure.unsafeDirectory }
            return fd
        } catch { close(fd); throw error }
    }
    private static func nameMatches(_ name: String, processID: Int32? = nil) -> Bool {
        let prefix = processID.map { "startup-\($0)-" } ?? "startup-"
        guard name.hasPrefix(prefix), name.hasSuffix(".json") else { return false }
        let pieces = name.dropFirst(8).dropLast(5).split(separator: "-", maxSplits: 1)
        return pieces.count == 2 && Int32(pieces[0]).map({ $0 > 0 }) == true && UUID(uuidString: String(pieces[1])) != nil
    }
    private static func metadata(_ fd: Int32, _ name: String) throws -> stat {
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_mode & S_IFMT == S_IFREG,
              st.st_uid == getuid(), st.st_nlink == 1, st.st_mode & 0o777 == 0o600,
              st.st_size > 0, st.st_size <= maximumBytes else { throw Failure.unsafeFile }
        return st
    }
    private static func read(_ fd: Int32, _ name: String) throws -> Data {
        let before = try metadata(fd, name)
        let input = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw Failure.unavailable }
        defer { close(input) }
        var opened = stat()
        guard fstat(input, &opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino,
              opened.st_size == before.st_size else { throw Failure.changedDuringRead }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = Darwin.read(input, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw Failure.unavailable }
            if count == 0 { break }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= maximumBytes else { throw Failure.invalid }
        }
        let after = try metadata(fd, name)
        guard before.st_dev == after.st_dev, before.st_ino == after.st_ino,
              before.st_size == after.st_size, before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              result.count == Int(before.st_size) else { throw Failure.changedDuringRead }
        let document = try validatedDocument(result)
        // Do not echo raw input: JSONSerialization collapses duplicate keys.
        // Re-encoding exposes only validated metadata and allowlisted timings.
        return try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
    }
    private static func validatedEvents(_ value: Any) throws -> [[String: Any]] {
        guard let rows = value as? [[String: Any]], !rows.isEmpty, rows.count <= 128,
              rows.first?["phase"] as? String == "host-entry" else { throw Failure.invalid }
        for row in rows {
            let keys = Set(row.keys)
            guard keys.isSubset(of: ["phase", "monotonicSeconds", "elapsedSeconds", "mainThread"]),
                  keys.isSuperset(of: ["phase", "monotonicSeconds", "mainThread"]),
                  let phase = row["phase"] as? String, ResearchStartupDiagnostics.allowedPhases.contains(phase),
                  let clock = row["monotonicSeconds"] as? NSNumber, CFGetTypeID(clock) != CFBooleanGetTypeID(),
                  clock.doubleValue.isFinite, clock.doubleValue >= 0,
                  let main = row["mainThread"] as? NSNumber, CFGetTypeID(main) == CFBooleanGetTypeID()
            else { throw Failure.invalid }
            if let elapsed = row["elapsedSeconds"] {
                guard let value = elapsed as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
                      value.doubleValue.isFinite, value.doubleValue >= 0 else { throw Failure.invalid }
            }
        }
        return rows
    }
    private static func validVersion(_ version: String) -> Bool {
        let fields = version.split(separator: ".", omittingEmptySubsequences: false)
        return version.utf8.count <= 32 && !fields.isEmpty && fields.count <= 4 &&
            fields.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
    }
    private static func validatedDocument(_ data: Data) throws -> [String: Any] {
        guard data.count <= maximumBytes,
              let document = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(document.keys) == ["format", "schemaVersion", "processID", "appVersion", "build", "clock", "events"],
              document["format"] as? String == "gaoseries.research-startup",
              let schema = document["schemaVersion"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(), schema.doubleValue == 1,
              let pid = document["processID"] as? NSNumber, CFGetTypeID(pid) != CFBooleanGetTypeID(),
              pid.int64Value > 0, pid.int64Value <= Int32.max, pid.doubleValue == Double(pid.int64Value),
              let version = document["appVersion"] as? String, validVersion(version),
              let build = document["build"] as? String, !build.isEmpty, build.utf8.count <= 12,
              build.allSatisfy({ $0.isASCII && $0.isNumber }), Int64(build).map({ $0 > 0 }) == true,
              document["clock"] as? String == "CLOCK_MONOTONIC", let events = document["events"]
        else { throw Failure.invalid }
        _ = try validatedEvents(events)
        return document
    }
    static func validate(_ data: Data) throws { _ = try validatedDocument(data) }
    private func document(_ data: Data) throws -> Data {
        let events = try Self.validatedEvents(JSONSerialization.jsonObject(with: data))
        let result = try JSONSerialization.data(withJSONObject: ["format": "gaoseries.research-startup", "schemaVersion": 1,
            "processID": processID, "appVersion": appVersion, "build": build, "clock": "CLOCK_MONOTONIC", "events": events], options: [.sortedKeys])
        try Self.validate(result)
        return result
    }
    private func publish(_ events: Data) throws {
        let data = try document(events)
        let fd = try Self.openDirectory(directory, create: true)
        defer { close(fd) }
        var existing = stat()
        if fstatat(fd, filename, &existing, AT_SYMLINK_NOFOLLOW) == 0 { _ = try Self.metadata(fd, filename) }
        else if errno != ENOENT { throw Failure.unsafe }
        let temporary = ".startup-\(UUID().uuidString).partial.noindex"
        let output = openat(fd, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw Failure.unavailable }
        defer { close(output); unlinkat(fd, temporary, 0) }
        // Calibrate only our newly O_EXCL-created file descriptor; never relax
        // the reader or change an existing/unknown entry's permissions.
        guard fchmod(output, 0o600) == 0 else { throw Failure.unavailable }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(output, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.unavailable }
                offset += count
            }
        }
        guard fsync(output) == 0, renameat(fd, temporary, fd, filename) == 0 else { throw Failure.unavailable }
        guard fsync(fd) == 0 else { throw Failure.unavailable }
        // Never prune unknown files, unsafe entries or another module's logs.
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        let old = names.filter { Self.nameMatches($0) && $0 != filename }.compactMap { name -> (String, stat)? in
            guard let st = try? Self.metadata(fd, name), (try? Self.read(fd, name)) != nil else { return nil }
            return (name, st)
        }.sorted { a, b in
            if a.1.st_mtimespec.tv_sec != b.1.st_mtimespec.tv_sec { return a.1.st_mtimespec.tv_sec > b.1.st_mtimespec.tv_sec }
            if a.1.st_mtimespec.tv_nsec != b.1.st_mtimespec.tv_nsec { return a.1.st_mtimespec.tv_nsec > b.1.st_mtimespec.tv_nsec }
            return a.0 > b.0
        }
        for (name, original) in old.dropFirst(7) {
            if let current = try? Self.metadata(fd, name), current.st_dev == original.st_dev,
               current.st_ino == original.st_ino { _ = unlinkat(fd, name, 0) }
        }
    }
    static func readNewest(directory: URL, processID: Int32) throws -> Data {
        guard processID > 0 else { throw Failure.invalid }
        let fd = try openDirectory(directory, create: false)
        defer { close(fd) }
        let candidates = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { nameMatches($0, processID: processID) }
        // Multiple runs with a reused PID are ambiguous. Root can inspect the
        // exact private filename and compare host-entry to its launch t0.
        guard candidates.count == 1, let name = candidates.first else { throw Failure.unavailable }
        let data = try read(fd, name)
        guard (try validatedDocument(data))["processID"] as? Int32 == processID else { throw Failure.invalid }
        return data
    }
}
