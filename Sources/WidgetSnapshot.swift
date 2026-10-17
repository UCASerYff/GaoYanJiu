import Foundation
import CryptoKit
import Darwin

/// One self-contained, versioned publication. `updatedAt` remains on the wire so
/// an older installed extension can read an upgrade without changing its kinds.
struct ResearchWidgetSnapshot: Codable, Equatable {
    static let groupID = "5G96498KGJ.com.academic-achievement.manager"
    static let currentSchemaVersion = 2
    struct Paper: Codable, Identifiable, Equatable {
        let id: String
        let title: String
        let number: String
        let since: Date
        let terminal: Bool
        func days(at date: Date, calendar: Calendar = .autoupdatingCurrent) -> Int {
            max(0, calendar.dateComponents([.day], from: calendar.startOfDay(for: since), to: calendar.startOfDay(for: date)).day ?? 0)
        }
    }
    struct Count: Codable, Identifiable, Equatable {
        let id: String
        let label: String
        let count: Int
    }
    let schemaVersion: Int
    let dataChangedAt: Date
    let dataChangedAtBasis: String
    let generatedAt: Date
    let sourceModifiedAt: Date?
    let sourceSchemaVersion: Int?
    let sourceRevision: String?
    let contentRevision: String?
    let revision: String?
    let english: Bool
    let papers: [Paper]
    let categories: [Count]
    let authors: [Count]
    let totalWorks: Int
    var updatedAt: Date { dataChangedAt }

    init(updatedAt: Date, english: Bool, papers: [Paper], categories: [Count], authors: [Count], totalWorks: Int,
         generatedAt: Date? = nil, sourceModifiedAt: Date? = nil, sourceSchemaVersion: Int? = nil,
         sourceRevision: String? = nil, dataChangedAtBasis: String? = nil) {
        schemaVersion = sourceRevision == nil ? 1 : Self.currentSchemaVersion
        dataChangedAt = updatedAt
        self.dataChangedAtBasis = dataChangedAtBasis ?? (sourceRevision == nil ? "legacy-publication" : "observed-projection")
        self.generatedAt = generatedAt ?? updatedAt
        self.sourceModifiedAt = sourceModifiedAt
        self.sourceSchemaVersion = sourceSchemaVersion
        self.sourceRevision = sourceRevision
        self.english = english
        self.papers = papers
        self.categories = categories
        self.authors = authors
        self.totalWorks = totalWorks
        contentRevision = sourceRevision == nil ? nil : Self.contentRevision(english: english, papers: papers, categories: categories, authors: authors, totalWorks: totalWorks)
        revision = sourceRevision == nil ? nil : Self.publicationRevision(changedAt: updatedAt, basis: self.dataChangedAtBasis,
            generatedAt: self.generatedAt, modifiedAt: sourceModifiedAt, sourceSchema: sourceSchemaVersion,
            sourceRevision: sourceRevision, contentRevision: contentRevision)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, updatedAt, dataChangedAt, dataChangedAtBasis, generatedAt, sourceModifiedAt, sourceSchemaVersion, sourceRevision, contentRevision, revision
        case english, papers, categories, authors, totalWorks
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...Self.currentSchemaVersion).contains(schemaVersion) else { throw ResearchWidgetStorage.Failure.unsupportedSchema }
        dataChangedAt = try c.decodeIfPresent(Date.self, forKey: .dataChangedAt) ?? c.decode(Date.self, forKey: .updatedAt)
        dataChangedAtBasis = try c.decodeIfPresent(String.self, forKey: .dataChangedAtBasis) ?? "legacy-publication"
        generatedAt = try c.decodeIfPresent(Date.self, forKey: .generatedAt) ?? dataChangedAt
        sourceModifiedAt = try c.decodeIfPresent(Date.self, forKey: .sourceModifiedAt)
        sourceSchemaVersion = try c.decodeIfPresent(Int.self, forKey: .sourceSchemaVersion)
        sourceRevision = try c.decodeIfPresent(String.self, forKey: .sourceRevision)
        contentRevision = try c.decodeIfPresent(String.self, forKey: .contentRevision)
        revision = try c.decodeIfPresent(String.self, forKey: .revision)
        english = try c.decode(Bool.self, forKey: .english)
        papers = try c.decode([Paper].self, forKey: .papers)
        categories = try c.decode([Count].self, forKey: .categories)
        authors = try c.decode([Count].self, forKey: .authors)
        totalWorks = try c.decode(Int.self, forKey: .totalWorks)
        try validate()
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(dataChangedAt, forKey: .updatedAt)
        try c.encode(dataChangedAt, forKey: .dataChangedAt)
        try c.encode(dataChangedAtBasis, forKey: .dataChangedAtBasis)
        try c.encode(generatedAt, forKey: .generatedAt)
        try c.encodeIfPresent(sourceModifiedAt, forKey: .sourceModifiedAt)
        try c.encodeIfPresent(sourceSchemaVersion, forKey: .sourceSchemaVersion)
        try c.encodeIfPresent(sourceRevision, forKey: .sourceRevision)
        try c.encodeIfPresent(contentRevision, forKey: .contentRevision)
        try c.encodeIfPresent(revision, forKey: .revision)
        try c.encode(english, forKey: .english)
        try c.encode(papers, forKey: .papers)
        try c.encode(categories, forKey: .categories)
        try c.encode(authors, forKey: .authors)
        try c.encode(totalWorks, forKey: .totalWorks)
    }
    func validate() throws {
        guard dataChangedAt.timeIntervalSince1970.isFinite, generatedAt.timeIntervalSince1970.isFinite,
              totalWorks >= 0, totalWorks <= 1_000_000, papers.count <= 50_000,
              Set(papers.map(\.id)).count == papers.count,
              papers.allSatisfy({ !$0.id.isEmpty && $0.since.timeIntervalSince1970.isFinite }),
              [categories, authors].allSatisfy({ values in
                  values.count <= 256 && Set(values.map(\.id)).count == values.count &&
                  values.allSatisfy { !$0.id.isEmpty && (0...totalWorks).contains($0.count) } &&
                  values.reduce(0, { $0 + $1.count }) == totalWorks
              }) else { throw ResearchWidgetStorage.Failure.invalidSnapshot }
        if schemaVersion == Self.currentSchemaVersion {
            guard let sourceRevision, Self.isDigest(sourceRevision), let sourceModifiedAt,
                  sourceModifiedAt.timeIntervalSince1970.isFinite, let sourceSchemaVersion, sourceSchemaVersion > 0,
                  ["legacy-publication", "source-write-baseline", "observed-projection"].contains(dataChangedAtBasis),
                  contentRevision == Self.contentRevision(english: english, papers: papers, categories: categories, authors: authors, totalWorks: totalWorks),
                  revision == Self.publicationRevision(changedAt: dataChangedAt, basis: dataChangedAtBasis, generatedAt: generatedAt,
                    modifiedAt: sourceModifiedAt, sourceSchema: sourceSchemaVersion, sourceRevision: sourceRevision, contentRevision: contentRevision)
            else { throw ResearchWidgetStorage.Failure.invalidSnapshot }
        }
    }
    /// Business values exclude language/labels and all generation/read times.
    /// Refreshing a portal, an index, or the city cannot make unchanged stats new.
    func hasSameBusinessValues(as other: Self) -> Bool {
        func counts(_ values: [Count]) -> [String: Int] { Dictionary(uniqueKeysWithValues: values.map { ($0.id, $0.count) }) }
        return papers.sorted { $0.id < $1.id } == other.papers.sorted { $0.id < $1.id } &&
            counts(categories) == counts(other.categories) && counts(authors) == counts(other.authors) && totalWorks == other.totalWorks
    }
    private struct Content: Codable {
        let english: Bool; let papers: [Paper]; let categories: [Count]; let authors: [Count]; let totalWorks: Int
    }
    private static func contentRevision(english: Bool, papers: [Paper], categories: [Count], authors: [Count], totalWorks: Int) -> String {
        let value = Content(english: english, papers: papers, categories: categories, authors: authors, totalWorks: totalWorks)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return ResearchWidgetStorage.digest((try? encoder.encode(value)) ?? Data())
    }
    private struct Publication: Codable {
        let changedAt: Date; let basis: String; let generatedAt: Date; let modifiedAt: Date?
        let sourceSchema: Int?; let sourceRevision: String?; let contentRevision: String?
    }
    private static func publicationRevision(changedAt: Date, basis: String, generatedAt: Date, modifiedAt: Date?,
                                            sourceSchema: Int?, sourceRevision: String?, contentRevision: String?) -> String {
        let value = Publication(changedAt: changedAt, basis: basis, generatedAt: generatedAt, modifiedAt: modifiedAt,
                                sourceSchema: sourceSchema, sourceRevision: sourceRevision, contentRevision: contentRevision)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return ResearchWidgetStorage.digest((try? encoder.encode(value)) ?? Data())
    }
    static func isDigest(_ value: String) -> Bool { value.count == 64 && value.allSatisfy { "0123456789abcdef".contains($0) } }
    static var fileURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupID)?.appendingPathComponent("statistics.json")
    }
}

enum ResearchWidgetSchedule {
    /// Entries carry the same successful read time. A future midnight is a display
    /// date, not evidence that the extension read a newer business publication.
    static func entryDates(from date: Date, calendar: Calendar = .autoupdatingCurrent) -> [Date] {
        [date] + (1...7).compactMap { calendar.date(byAdding: .day, value: $0, to: calendar.startOfDay(for: date)) }
    }
    static func nextRefresh(after date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        let nextMidnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date.addingTimeInterval(3600)
        return min(nextMidnight, date.addingTimeInterval(3600))
    }
}

/// Both host and extension use these exact bytes and validation rules. No path
/// falls back to a default/empty library or to a different App Group.
enum ResearchWidgetStorage {
    enum Failure: String, Error { case missing, unavailable, unsafeFile, changedDuringRead, unsupportedSchema, invalidSnapshot, sourceChanged, writeFailed }
    struct FileValue { let data: Data; let modifiedAt: Date; let revision: String }
    struct ReadValue {
        let snapshot: ResearchWidgetSnapshot?
        let readAt: Date
        let source: String // "statistics", "last-good", or "unavailable"
        let failure: String?
    }
    struct ReadStatus: Codable {
        let requestedAt: Date
        let source: String
        let failure: String?
        let schemaVersion: Int?
        let revision: String?
        let sourceRevision: String?
        let dataChangedAt: Date?
        let dataChangedAtBasis: String?
        let generatedAt: Date?
        let sourceModifiedAt: Date?
        let requestKind: String?
        let lastSuccessfulRead: ReadEvidence?
        let lastTimelineAttempt: ReadEvidence?
        let lastTimelineSuccess: ReadEvidence?
        let lastSnapshotAt: Date?
    }
    struct ReadEvidence: Codable {
        let requestedAt: Date
        let source: String
        let failure: String?
        let revision: String?
        let sourceRevision: String?
        let generatedAt: Date?
        let dataChangedAt: Date?
    }
    static func lastGoodURL(for url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent("statistics.last-good.json") }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func directoryFD(at url: URL) throws -> Int32 {
        var components = url.pathComponents.filter { $0 != "/" }
        guard url.isFileURL, !components.contains(".."), !components.contains(".") else { throw Failure.unsafeFile }
        // Fixed macOS aliases only; never resolve a user-controlled ancestor.
        if let first = components.first, ["tmp", "var", "etc"].contains(first) { components.insert("private", at: 0) }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? Failure.missing : Failure.unavailable }
        for part in components {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw Failure.unsafeFile }
            fd = next
        }
        return fd
    }
    private static func sameFile(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
    static func readFile(at url: URL, maximumBytes: Int = 8 * 1_048_576) throws -> FileValue {
        let parent = try directoryFD(at: url.deletingLastPathComponent())
        defer { Darwin.close(parent) }
        let fd = openat(parent, url.lastPathComponent, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw errno == ENOENT ? Failure.missing : Failure.unavailable }
        defer { Darwin.close(fd) }
        var before = stat(); var after = stat(); var pathState = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_size >= 0,
              before.st_size <= maximumBytes else { throw Failure.unsafeFile }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw Failure.unavailable }
            if count == 0 { break }
            guard data.count <= maximumBytes - count else { throw Failure.unsafeFile }
            data.append(contentsOf: buffer.prefix(count))
        }
        guard fstat(fd, &after) == 0, fstatat(parent, url.lastPathComponent, &pathState, AT_SYMLINK_NOFOLLOW) == 0,
              sameFile(before, after), sameFile(after, pathState), data.count == before.st_size else { throw Failure.changedDuringRead }
        let modifiedAt = Date(timeIntervalSince1970: Double(after.st_mtimespec.tv_sec) + Double(after.st_mtimespec.tv_nsec) / 1_000_000_000)
        return FileValue(data: data, modifiedAt: modifiedAt, revision: digest(data))
    }
    static func atomicWrite(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let dir = try directoryFD(at: directory)
        defer { Darwin.close(dir) }
        let temporary = ".statistics-" + UUID().uuidString + ".tmp"
        let fd = openat(dir, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.writeFailed }
        defer { Darwin.close(fd); unlinkat(dir, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: written), bytes.count - written)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure.writeFailed }; written += count
            }
        }
        guard fchmod(fd, 0o600) == 0, fsync(fd) == 0, renameat(dir, temporary, dir, url.lastPathComponent) == 0 else { throw Failure.writeFailed }
        if fsync(dir) != 0 && errno != EINVAL && errno != ENOTSUP { throw Failure.writeFailed }
    }
    static func decode(_ data: Data) throws -> ResearchWidgetSnapshot {
        let snapshot = try JSONDecoder().decode(ResearchWidgetSnapshot.self, from: data)
        try snapshot.validate()
        return snapshot
    }
    static func read(at url: URL?, now: Date = Date(), recordStatus: Bool = false, requestKind: String = "unspecified") -> ReadValue {
        var result = ReadValue(snapshot: nil, readAt: now, source: "unavailable", failure: Failure.unavailable.rawValue)
        if let url {
            do { result = ReadValue(snapshot: try decode(readFile(at: url).data), readAt: now, source: "statistics", failure: nil) }
            catch {
                let code = (error as? Failure)?.rawValue ?? "decode-failed"
                if let snapshot = try? decode(readFile(at: lastGoodURL(for: url)).data) {
                    result = ReadValue(snapshot: snapshot, readAt: now, source: "last-good", failure: code)
                } else { result = ReadValue(snapshot: nil, readAt: now, source: "unavailable", failure: code) }
            }
            if recordStatus {
                let statusURL = url.deletingLastPathComponent().appendingPathComponent("statistics.read-status.json")
                let old = (try? readFile(at: statusURL).data).flatMap { try? JSONDecoder().decode(ReadStatus.self, from: $0) }
                let s = result.snapshot
                let evidence = ReadEvidence(requestedAt: now, source: result.source, failure: result.failure,
                    revision: s?.revision, sourceRevision: s?.sourceRevision, generatedAt: s?.generatedAt, dataChangedAt: s?.dataChangedAt)
                let status = ReadStatus(requestedAt: now, source: result.source, failure: result.failure, schemaVersion: s?.schemaVersion,
                                        revision: s?.revision, sourceRevision: s?.sourceRevision, dataChangedAt: s?.dataChangedAt,
                                        dataChangedAtBasis: s?.dataChangedAtBasis,
                                        generatedAt: s?.generatedAt, sourceModifiedAt: s?.sourceModifiedAt, requestKind: requestKind,
                                        lastSuccessfulRead: s != nil ? evidence : old?.lastSuccessfulRead,
                                        lastTimelineAttempt: requestKind == "timeline" ? evidence : old?.lastTimelineAttempt,
                                        lastTimelineSuccess: requestKind == "timeline" && s != nil ? evidence : old?.lastTimelineSuccess,
                                        lastSnapshotAt: requestKind == "snapshot" ? now : old?.lastSnapshotAt)
                if let data = try? JSONEncoder().encode(status) {
                    try? atomicWrite(data, to: statusURL)
                }
            }
        }
        return result
    }
    static func publish(_ snapshot: ResearchWidgetSnapshot, to url: URL,
                        sourceIsCurrent: () throws -> Bool = { true },
                        write: (Data, URL) throws -> Void = { try atomicWrite($0, to: $1) }) throws {
        try snapshot.validate()
        let data = try JSONEncoder().encode(snapshot)
        guard data.count <= 8 * 1_048_576 else { throw Failure.unsafeFile }
        var oldPrimary: Data?
        for slot in [url, lastGoodURL(for: url)] {
            do {
                let old = try readFile(at: slot).data
                if let object = try? JSONSerialization.jsonObject(with: old) as? [String: Any],
                   let schema = object["schemaVersion"] as? Int, schema > ResearchWidgetSnapshot.currentSchemaVersion {
                    throw Failure.unsupportedSchema
                }
                if slot == url { oldPrimary = old }
            } catch Failure.missing { continue }
        }
        guard try sourceIsCurrent() else { throw Failure.sourceChanged }
        // Preserve a valid publication before replacing the primary. Every slot
        // is independently versioned; a crash never combines two generations.
        if let old = oldPrimary, (try? decode(old)) != nil {
            try write(old, lastGoodURL(for: url))
        }
        guard try sourceIsCurrent() else { throw Failure.sourceChanged }
        try write(data, url)
        try write(data, lastGoodURL(for: url))
        guard try sourceIsCurrent() else { throw Failure.sourceChanged }
    }
}
