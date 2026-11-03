import Foundation
import Darwin

@main enum StartupDiagnosticsFileRegression {
    static let fm = FileManager.default
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        if !(try value()) { throw NSError(domain: "StartupTimingRegression", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    static func rejects(_ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw NSError(domain: "StartupTimingRegression", code: 2, userInfo: [NSLocalizedDescriptionKey: "Unsafe timing input accepted"])
    }
    static func rows(_ data: Data) throws -> [[String: Any]] {
        let object = try JSONSerialization.jsonObject(with: data)
        if let document = object as? [String: Any] { return document["events"] as! [[String: Any]] }
        return object as! [[String: Any]]
    }
    static func sameEvents(_ data: Data) throws -> Bool {
        try NSArray(array: rows(data)).isEqual(to: rows(ResearchStartupDiagnostics.snapshot()))
    }
    static func plainEvent(processID: Int32 = getpid()) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["format": "gaoseries.research-startup", "schemaVersion": 1,
            "processID": processID, "appVersion": "4.12", "build": "13", "clock": "CLOCK_MONOTONIC",
            "events": [["phase": "host-entry", "monotonicSeconds": 1.0, "mainThread": true]]], options: [.sortedKeys])
    }
    static func write(_ data: Data, _ file: URL, mode: Int16 = 0o600) throws {
        try data.write(to: file); guard chmod(file.path, mode_t(mode)) == 0 else { throw ResearchStartupDiagnosticsFile.Failure.unavailable }
    }
    static func privateDirectory(_ path: URL) throws {
        try fm.createDirectory(at: path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(path.path, 0o700) == 0 else { throw ResearchStartupDiagnosticsFile.Failure.unavailable }
    }
    static func fixtureMetadata(_ path: URL, _ label: String) {
        var st = stat()
        if lstat(path.path, &st) == 0 {
            print("Synthetic timing fixture \(label): mode=\(String(st.st_mode & 0o777, radix: 8)) uid=\(st.st_uid) currentUID=\(getuid()) nlink=\(st.st_nlink) bytes=\(st.st_size)", terminator: "\n")
            fflush(stdout)
        }
    }
    static func main() throws {
        guard CommandLine.arguments.count == 3 else { fatalError("case and isolated absolute directory required") }
        let name = CommandLine.arguments[1], root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try require(root.path.hasPrefix("/private/tmp/") && root.path.contains(".noindex/"), "Test root escaped isolation")
        try privateDirectory(root)
        let output = root.appendingPathComponent("timing.noindex", isDirectory: true)
        let valid = try plainEvent()
        switch name {
        case "readiness":
            ResearchStartupDiagnostics.mark("host-entry")
            try require(!fm.fileExists(atPath: output.path), "mark unexpectedly created an output directory")
            let file = ResearchStartupDiagnostics.enablePrivateFileOutput(appVersion: "4.12", build: "13", directory: output)
            try require(ResearchStartupDiagnostics.enablePrivateFileOutput(appVersion: "4.12", build: "13", directory: output) == file, "Enabled duplicate writer")
            ResearchStartupDiagnostics.mark("library-read-ready")
            ResearchStartupDiagnostics.mark("widget-publication-pending")
            ResearchStartupDiagnostics.mark("content-first-appeared")
            ResearchStartupDiagnostics.flushPrivateFileOutput()
            fixtureMetadata(output, "directory")
            fixtureMetadata(file, "file-before-first-read")
            print("Synthetic Foundation standardization matches existing lexical path: \(output.path == output.standardizedFileURL.path)")
            fflush(stdout)
            var phases = try rows(Data(contentsOf: file)).compactMap { $0["phase"] as? String }
            try require(!phases.contains("startup-data-ready"), "Pending widget became ready")
            ResearchStartupDiagnostics.mark("widget-publication-ready")
            ResearchStartupDiagnostics.mark("content-first-appeared")
            ResearchStartupDiagnostics.flushPrivateFileOutput()
            fixtureMetadata(file, "file-before-maintenance-read")
            let data = try ResearchStartupDiagnosticsFile.readNewest(directory: output, processID: getpid())
            phases = try rows(data).compactMap { $0["phase"] as? String }
            try require(phases.filter { $0 == "content-first-appeared" }.count == 2, "Existing content event semantics changed")
            try require(phases.filter { $0 == "startup-data-ready" }.count == 1, "Content boundary did not complete readiness")
            try require(try sameEvents(data), "Final private file differs from captured events")
            let document = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            try require(document["appVersion"] as? String == "4.12" && document["build"] as? String == "13" &&
                        document["processID"] as? Int32 == getpid() && document["clock"] as? String == "CLOCK_MONOTONIC", "Run metadata mismatch")
            let attributes = try fm.attributesOfItem(atPath: file.path)
            try require((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600, "Timing file is not private")
            let directoryAttributes = try fm.attributesOfItem(atPath: output.path)
            try require((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700, "Timing directory is not private")
        case "bounded":
            ResearchStartupDiagnostics.mark("host-entry")
            let file = ResearchStartupDiagnostics.enablePrivateFileOutput(appVersion: "4.12", build: "13", directory: output)
            ResearchStartupDiagnostics.mark("PRIVATE_USER_FIELD_MUST_NOT_APPEAR")
            ResearchStartupDiagnostics.mark("repository-read-finished", elapsed: .nan)
            ResearchStartupDiagnostics.mark("repository-read-finished", elapsed: -1)
            DispatchQueue.concurrentPerform(iterations: 500) { _ in
                ResearchStartupDiagnostics.mark("repository-read-finished", elapsed: 0.001)
            }
            ResearchStartupDiagnostics.flushPrivateFileOutput()
            let data = try Data(contentsOf: file), captured = try rows(data)
            try require(captured.count == 128, "Timing limit not enforced")
            try require(!String(decoding: data, as: UTF8.self).contains("PRIVATE_USER_FIELD"), "Unallowlisted text leaked")
            try ResearchStartupDiagnosticsFile.validate(data)
            try require(try sameEvents(data), "Concurrent offers regressed the last snapshot")
        case "symlink":
            let outside = root.appendingPathComponent("outside", isDirectory: true)
            try privateDirectory(outside)
            try fm.createSymbolicLink(at: output, withDestinationURL: outside)
            ResearchStartupDiagnostics.mark("host-entry")
            ResearchStartupDiagnostics.enablePrivateFileOutput(appVersion: "4.12", build: "13", directory: output)
            ResearchStartupDiagnostics.flushPrivateFileOutput()
            try require(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "Writer followed symlink directory")
            try rejects { _ = try ResearchStartupDiagnosticsFile.readNewest(directory: output, processID: getpid()) }
        case "permissions":
            try privateDirectory(output)
            try require(chmod(output.path, 0o755) == 0, "chmod failed")
            ResearchStartupDiagnostics.mark("host-entry")
            ResearchStartupDiagnostics.enablePrivateFileOutput(appVersion: "4.12", build: "13", directory: output)
            ResearchStartupDiagnostics.flushPrivateFileOutput()
            try require(try fm.contentsOfDirectory(atPath: output.path).isEmpty, "Writer used non-private directory")
        case "unsafe-read":
            try privateDirectory(output)
            let file = output.appendingPathComponent("startup-\(getpid())-\(UUID().uuidString).json")
            let outside = root.appendingPathComponent("outside.json")
            try write(valid, outside)
            try fm.createSymbolicLink(at: file, withDestinationURL: outside)
            try rejects { _ = try ResearchStartupDiagnosticsFile.readNewest(directory: output, processID: getpid()) }
            try fm.removeItem(at: file)
            try fm.linkItem(at: outside, to: file)
            try rejects { _ = try ResearchStartupDiagnosticsFile.readNewest(directory: output, processID: getpid()) }
            try fm.removeItem(at: file)
            try write(Data("[{\"phase\":\"host-entry\",\"monotonicSeconds\":1,\"mainThread\":true,\"private\":\"rejected\"}]".utf8), file)
            try rejects { _ = try ResearchStartupDiagnosticsFile.readNewest(directory: output, processID: getpid()) }
            try write(valid, file, mode: 0o644)
            try rejects { _ = try ResearchStartupDiagnosticsFile.readNewest(directory: output, processID: getpid()) }
            try write(valid, file)
            let duplicateText = String(decoding: valid, as: UTF8.self).replacingOccurrences(of: "\"phase\":\"host-entry\"",
                with: "\"phase\":\"PRIVATE_HIDDEN_MUST_NOT_LEAK\",\"phase\":\"host-entry\"")
            try require(duplicateText.contains("PRIVATE_HIDDEN"), "Duplicate-key fixture not constructed")
            try write(Data(duplicateText.utf8), file)
            // Foundation may keep the first or the last duplicate value. Both
            // rejecting it and returning only sanitized allowed values are safe.
            if let sanitized = try? ResearchStartupDiagnosticsFile.readNewest(directory: output, processID: getpid()) {
                try require(!String(decoding: sanitized, as: UTF8.self).contains("PRIVATE_HIDDEN"), "Raw duplicate-key text leaked")
                try ResearchStartupDiagnosticsFile.validate(sanitized)
            }
            try write(try plainEvent(processID: getpid() + 1), file)
            try rejects { _ = try ResearchStartupDiagnosticsFile.readNewest(directory: output, processID: getpid()) }
            try write(valid, file)
            let second = output.appendingPathComponent("startup-\(getpid())-\(UUID().uuidString).json")
            try write(valid, second)
            try rejects { _ = try ResearchStartupDiagnosticsFile.readNewest(directory: output, processID: getpid()) }
            try require(try Data(contentsOf: outside) == valid, "Read path modified another file")
        case "retention":
            try privateDirectory(output)
            for index in 1...10 {
                let file = output.appendingPathComponent("startup-\(1000 + index)-\(UUID().uuidString).json")
                try write(try plainEvent(processID: Int32(1000 + index)), file)
                try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(index))], ofItemAtPath: file.path)
            }
            let unknown = output.appendingPathComponent("unrelated.json")
            let unsafe = output.appendingPathComponent("startup-999-\(UUID().uuidString).json")
            try write(Data("private sentinel".utf8), unknown)
            try write(valid, unsafe, mode: 0o644)
            ResearchStartupDiagnostics.mark("host-entry")
            ResearchStartupDiagnostics.enablePrivateFileOutput(appVersion: "4.12", build: "13", directory: output)
            ResearchStartupDiagnostics.flushPrivateFileOutput()
            let names = try fm.contentsOfDirectory(atPath: output.path)
            try require(names.count == 10, "Did not retain eight timing files plus untouched unknown entries")
            try require(try Data(contentsOf: unknown) == Data("private sentinel".utf8), "Pruned unrelated data")
            try require(fm.fileExists(atPath: unsafe.path), "Pruned an unsafe entry")
            try require(!names.contains { $0.contains("partial") }, "Left intermediate timing files")
        case "concurrent-read":
            ResearchStartupDiagnostics.mark("host-entry")
            ResearchStartupDiagnostics.enablePrivateFileOutput(appVersion: "4.12", build: "13", directory: output)
            ResearchStartupDiagnostics.flushPrivateFileOutput()
            DispatchQueue.concurrentPerform(iterations: 80) { index in
                if index % 2 == 0 { ResearchStartupDiagnostics.mark("repository-read-finished", elapsed: 0) }
                else if let data = try? ResearchStartupDiagnosticsFile.readNewest(directory: output, processID: getpid()) {
                    precondition((try? ResearchStartupDiagnosticsFile.validate(data)) != nil, "Returned partial timing JSON")
                }
            }
            ResearchStartupDiagnostics.flushPrivateFileOutput()
            let data = try ResearchStartupDiagnosticsFile.readNewest(directory: output, processID: getpid())
            try require(try sameEvents(data), "Concurrent reading lost final snapshot")
        case "invalid-json":
            for data in [Data("[]".utf8), Data("{}".utf8), Data("[{\"phase\":\"host-entry\",\"monotonicSeconds\":true,\"mainThread\":true}]".utf8),
                         Data("[{\"phase\":\"host-entry\",\"monotonicSeconds\":1,\"mainThread\":1}]".utf8),
                         Data(repeating: 0x20, count: ResearchStartupDiagnosticsFile.maximumBytes + 1)] {
                try rejects { try ResearchStartupDiagnosticsFile.validate(data) }
            }
        default: fatalError("Unknown directed case")
        }
        print("PASS startup-private-timing \(name)")
    }
}
