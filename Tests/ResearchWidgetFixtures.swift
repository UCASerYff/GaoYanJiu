import Foundation
import Darwin

// Real production types/projector/publisher are compiled in the same module.
// Preferences alone are isolated; no PaperStore, app, or widget host is started.
final class UserDefaults {
    static let standard = UserDefaults(domain: "widget.standard")
    static let didChangeNotification = Notification.Name("ResearchWidgetFixtureDefaultsChanged")
    private static let lock = NSLock()
    private static var values: [String: [String: Any]] = [:]
    private let domain: String
    private init(domain: String) { self.domain = domain }
    convenience init?(suiteName: String?) {
        guard suiteName == "com.academic-achievement.manager.test.Research" else { return nil }
        self.init(domain: suiteName!)
    }
    func object(forKey key: String) -> Any? { Self.lock.lock(); defer { Self.lock.unlock() }; return Self.values[domain]?[key] }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    func set(_ value: Any?, forKey key: String) { Self.lock.lock(); defer { Self.lock.unlock() }; Self.values[domain, default: [:]][key] = value }
    func removeObject(forKey key: String) { set(nil, forKey: key) }
}

@main struct ResearchWidgetFixtures {
    struct Failure: Error { let message: String }
    static var root: URL!
    static var checks = 0
    static func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw Failure(message: message) }; checks += 1
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw Failure(message: message)
    }
    static func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    static let first = date("2026-10-14T06:00:00Z")
    static let later = date("2026-10-17T06:00:00Z")
    static func calendar(_ zone: String) -> Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: zone)!; return value }
    static func directory(_ name: String) throws -> URL {
        let url = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func work(_ id: String, type: ExistingWorkType = .journalArticle, author: AuthorPosition? = .first, patent: PatentType? = nil) -> ExistingWork {
        ExistingWork(id: id, title: "fixture", type: type, venue: "", authors: "", completedAt: first, identifier: "", url: "", notes: "",
                     attachments: [], createdAt: first, updatedAt: first, patentType: patent, journalISSN: nil, journalMetrics: nil, authorPosition: author)
    }
    static func paper(_ id: String, hidden: Bool = false) -> PaperRecord {
        PaperRecord(key: id, sourceID: "manual", site: "fixture", url: "", manuscriptID: "fixture", title: "fixture", journal: "fixture",
                    status: "under review", checkedAt: first, statusSince: first, statusSinceSource: "fixture", previousStatus: nil,
                    changed: false, hidden: hidden, history: [])
    }
    static func writeLibrary(_ library: PersistedLibrary, repository: DiskLibraryRepository, modifiedAt: Date) throws -> ResearchWidgetStorage.FileValue {
        // Explicit fixture seed, never the real initialize/migrate path.
        try GaoActionFileAccess.writePrivateData(repository.encoder.encode(library), to: repository.libraryURL)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: repository.libraryURL.path)
        return try ResearchWidgetStorage.readFile(at: repository.libraryURL)
    }
    static func make(_ library: PersistedLibrary, source: ResearchWidgetStorage.FileValue, previous: ResearchWidgetSnapshot? = nil, now: Date = later, english: Bool = false) -> ResearchWidgetSnapshot {
        ResearchWidgetProjection.make(library: library, source: source, previous: previous, english: english, now: now)
    }
    static func pipeline() throws {
        let path = try directory("pipeline")
        let repo = DiskLibraryRepository(applicationSupportURL: path.appendingPathComponent("Data"), legacyApplicationSupportURL: path.appendingPathComponent("NoLegacy"), migrationBackupsURL: path.appendingPathComponent("NoBackups"))
        let snapshotURL = path.appendingPathComponent("statistics.json")
        var library = PersistedLibrary(papers: [paper("visible"), paper("hidden", hidden: true)], existingWorks: [work("one"), work("two", type: .patent, author: nil)])
        var source = try writeLibrary(library, repository: repo, modifiedAt: first)
        let (decoded, pinned) = try ResearchWidgetProjection.readLibrary(at: repo.libraryURL, maximumSchema: LibrarySchema.currentVersion)
        var snapshot = make(decoded, source: pinned)
        try require(snapshot.totalWorks == 2 && snapshot.papers.count == 1, "Real library projection differs")
        try require(snapshot.categories.first(where: { $0.id == "patent-unspecified" })?.count == 1 && snapshot.authors.first(where: { $0.id == "unassigned" })?.count == 1, "Unspecified authors/patents lost")
        try require(snapshot.sourceModifiedAt == first && snapshot.dataChangedAt == first && snapshot.generatedAt == later, "Source/generation timestamps conflated")
        try require(snapshot.dataChangedAtBasis == "source-write-baseline", "Unknown history invented")
        try ResearchWidgetStorage.publish(snapshot, to: snapshotURL)
        // Index/reward/check time writes do not change projected business values.
        library.papers[0].checkedAt = later
        source = try writeLibrary(library, repository: repo, modifiedAt: later)
        let unchanged = make(library, source: source, previous: snapshot, now: later.addingTimeInterval(30))
        try require(unchanged.dataChangedAt == first && unchanged.sourceModifiedAt == later, "Library mtime masked unchanged statistics")
        try require(unchanged.contentRevision == snapshot.contentRevision && unchanged.revision != snapshot.revision, "Publication/content revisions not independent")
        let translated = make(library, source: source, previous: snapshot, english: true)
        try require(translated.dataChangedAt == first && translated.contentRevision != snapshot.contentRevision, "Language changed business time")
        // The exact production projector is exercised for additions/edits/deletes.
        library.existingWorks.append(work("three", type: .book, author: .corresponding))
        snapshot = make(library, source: source, previous: snapshot)
        try require(snapshot.totalWorks == 3 && snapshot.dataChangedAt == later && snapshot.categories.first(where: { $0.id == "book" })?.count == 1, "Addition not projected")
        library.existingWorks[0].type = .software; library.existingWorks[0].authorPosition = .second
        snapshot = make(library, source: source, previous: snapshot)
        try require(snapshot.categories.first(where: { $0.id == "journalArticle" }) == nil && snapshot.authors.first(where: { $0.id == "second" })?.count == 1, "Edit did not move category/authorship")
        library.existingWorks.removeAll { $0.id == "two" }
        library.papers[0].hidden = true
        snapshot = make(library, source: source, previous: snapshot)
        try require(snapshot.totalWorks == 2 && snapshot.papers.isEmpty && snapshot.categories.reduce(0, { $0 + $1.count }) == 2 && snapshot.authors.reduce(0, { $0 + $1.count }) == 2, "Deletion/visibility totals stale")
        try ResearchWidgetStorage.publish(snapshot, to: snapshotURL)
        try require(try ResearchWidgetStorage.decode(ResearchWidgetStorage.readFile(at: snapshotURL).data) == snapshot, "Published generation mixed")
        let read = ResearchWidgetStorage.read(at: snapshotURL, now: later.addingTimeInterval(90), recordStatus: true, requestKind: "timeline")
        try require(read.source == "statistics" && read.readAt != snapshot.generatedAt && read.snapshot?.dataChangedAt == later, "Read/generation/data time conflated")
        let status = try JSONDecoder().decode(ResearchWidgetStorage.ReadStatus.self, from: ResearchWidgetStorage.readFile(at: path.appendingPathComponent("statistics.read-status.json")).data)
        try require(status.source == "statistics" && status.requestedAt == read.readAt && status.revision == snapshot.revision, "Read evidence not bound to publication")
        let previewAt = later.addingTimeInterval(120)
        _ = ResearchWidgetStorage.read(at: snapshotURL, now: previewAt, recordStatus: true, requestKind: "snapshot")
        try FileManager.default.removeItem(at: snapshotURL)
        try FileManager.default.removeItem(at: ResearchWidgetStorage.lastGoodURL(for: snapshotURL))
        let failedAt = later.addingTimeInterval(150)
        _ = ResearchWidgetStorage.read(at: snapshotURL, now: failedAt, recordStatus: true, requestKind: "timeline")
        let failed = try JSONDecoder().decode(ResearchWidgetStorage.ReadStatus.self, from: ResearchWidgetStorage.readFile(at: path.appendingPathComponent("statistics.read-status.json")).data)
        try require(failed.lastSuccessfulRead?.requestedAt == previewAt && failed.lastSuccessfulRead?.revision == snapshot.revision, "Failure erased last successful read")
        try require(failed.lastTimelineSuccess?.requestedAt == read.readAt && failed.lastTimelineSuccess?.revision == snapshot.revision, "Preview replaced actual Timeline read evidence")
        try require(failed.lastTimelineAttempt?.requestedAt == failedAt && failed.lastTimelineAttempt?.source == "unavailable" && failed.lastSnapshotAt == previewAt, "Request kinds/failures conflated")
    }
    static func compatibilityAndFailures() throws {
        let path = try directory("failure")
        let url = path.appendingPathComponent("statistics.json")
        let legacy = ResearchWidgetSnapshot(updatedAt: first, english: false, papers: [paper("x")].map { .init(id: $0.id, title: $0.title, number: "", since: first, terminal: false) }, categories: [.init(id: "book", label: "书", count: 1)], authors: [.init(id: "first", label: "一作", count: 1)], totalWorks: 1)
        try ResearchWidgetStorage.atomicWrite(JSONEncoder().encode(legacy), to: url)
        let source = ResearchWidgetStorage.FileValue(data: Data(), modifiedAt: later, revision: String(repeating: "a", count: 64))
        let upgraded = ResearchWidgetSnapshot(updatedAt: legacy.dataChangedAt, english: legacy.english, papers: legacy.papers, categories: legacy.categories, authors: legacy.authors, totalWorks: 1,
            generatedAt: later, sourceModifiedAt: later, sourceSchemaVersion: 32, sourceRevision: source.revision, dataChangedAtBasis: legacy.dataChangedAtBasis)
        try ResearchWidgetStorage.publish(upgraded, to: url)
        try require(upgraded.dataChangedAt == first && upgraded.dataChangedAtBasis == "legacy-publication", "Legacy publication invented an edit date")
        struct OldReader: Decodable { let updatedAt: Date; let totalWorks: Int }
        try require(try JSONDecoder().decode(OldReader.self, from: ResearchWidgetStorage.readFile(at: url).data).updatedAt == first, "Old installed reader incompatible")
        let validBytes = try ResearchWidgetStorage.readFile(at: url).data
        for corruption in [Data("broken".utf8), Data("{}".utf8)] {
            try ResearchWidgetStorage.atomicWrite(corruption, to: url)
            let read = ResearchWidgetStorage.read(at: url, now: later)
            try require(read.source == "last-good" && read.snapshot == upgraded, "Corruption replaced last-good with zero")
        }
        var object = try JSONSerialization.jsonObject(with: validBytes) as! [String: Any]
        object["schemaVersion"] = 999
        try ResearchWidgetStorage.atomicWrite(JSONSerialization.data(withJSONObject: object), to: url)
        try require(ResearchWidgetStorage.read(at: url).source == "last-good", "Future snapshot did not preserve last-good")
        let futureBytes = try ResearchWidgetStorage.readFile(at: url).data
        try rejects("Publisher downgraded a future snapshot") { try ResearchWidgetStorage.publish(upgraded, to: url) }
        try require(try ResearchWidgetStorage.readFile(at: url).data == futureBytes && ResearchWidgetStorage.decode(ResearchWidgetStorage.readFile(at: ResearchWidgetStorage.lastGoodURL(for: url)).data) == upgraded, "Future generation or last-good overwritten")
        object = try JSONSerialization.jsonObject(with: validBytes) as! [String: Any]
        object["generatedAt"] = 1
        try rejects("Metadata revision tampering accepted") { _ = try ResearchWidgetStorage.decode(JSONSerialization.data(withJSONObject: object)) }
        try FileManager.default.removeItem(at: url)
        try require(ResearchWidgetStorage.read(at: url).snapshot == upgraded, "Missing primary lost last-good")
        try FileManager.default.removeItem(at: ResearchWidgetStorage.lastGoodURL(for: url))
        try require(ResearchWidgetStorage.read(at: url).snapshot == nil, "Missing data fabricated an empty snapshot")
        try ResearchWidgetStorage.publish(upgraded, to: url)
        let original = try ResearchWidgetStorage.readFile(at: url).data
        try rejects("Source race accepted") { try ResearchWidgetStorage.publish(upgraded, to: url, sourceIsCurrent: { false }) }
        try require(try ResearchWidgetStorage.readFile(at: url).data == original, "Source race replaced primary")
        try rejects("Primary write failure ignored") {
            try ResearchWidgetStorage.publish(upgraded, to: url, write: { bytes, target in
                if target == url { throw Failure(message: "injected primary failure") }
                try ResearchWidgetStorage.atomicWrite(bytes, to: target)
            })
        }
        try require(try ResearchWidgetStorage.readFile(at: url).data == original && ResearchWidgetStorage.read(at: url).snapshot == upgraded, "Write failure lost publication")
        var sourceChecks = 0
        try rejects("Source changed between staging and publication") {
            try ResearchWidgetStorage.publish(upgraded, to: url, sourceIsCurrent: { sourceChecks += 1; return sourceChecks == 1 })
        }
        try require(try ResearchWidgetStorage.readFile(at: url).data == original, "Failed generation partially published")
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        try require(mode?.intValue == 0o600, "Snapshot is not private")
        let alias = path.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: path)
        try rejects("Read followed ancestor symlink") { _ = try ResearchWidgetStorage.readFile(at: alias.appendingPathComponent("statistics.json")) }
        try rejects("Write followed ancestor symlink") { try ResearchWidgetStorage.atomicWrite(Data(), to: alias.appendingPathComponent("statistics.json")) }
        let nested = path.appendingPathComponent("Nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: false)
        let nestedFile = nested.appendingPathComponent("current.json")
        try ResearchWidgetStorage.atomicWrite(original, to: nestedFile)
        let nestedAlias = alias.appendingPathComponent("Nested/current.json")
        try rejects("Read followed a nonfinal ancestor symlink") { _ = try ResearchWidgetStorage.readFile(at: nestedAlias) }
        try rejects("Write followed a nonfinal ancestor symlink") { try ResearchWidgetStorage.atomicWrite(Data(), to: nestedAlias) }
        try require(try ResearchWidgetStorage.readFile(at: nestedFile).data == original, "Rejected ancestor write changed original bytes")
        let systemAlias = URL(fileURLWithPath: url.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"))
        try require(try ResearchWidgetStorage.readFile(at: systemAlias).data == original, "Fixed /tmp system alias stopped working")
        let hardlink = path.appendingPathComponent("hardlink.json")
        try require(link(url.path, hardlink.path) == 0, "Fixture hard link failed")
        try rejects("Read accepted multiply linked file") { _ = try ResearchWidgetStorage.readFile(at: url) }
        try FileManager.default.removeItem(at: hardlink)
        try rejects("Read ignored byte limit") { _ = try ResearchWidgetStorage.readFile(at: url, maximumBytes: 1) }
    }
    static func unreadableLibraries() throws {
        let path = try directory("invalid-source")
        let url = path.appendingPathComponent("library.json")
        try rejects("Missing library treated as blank") { _ = try ResearchWidgetProjection.readLibrary(at: url, maximumSchema: 32) }
        let valid = try JSONEncoder().encode(PersistedLibrary())
        var object = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
        object["version"] = 999
        var missingCollection = try JSONSerialization.jsonObject(with: valid) as! [String: Any]
        missingCollection.removeValue(forKey: "portals")
        for bytes in [Data(), Data("{}".utf8), Data("{\"version\":32,\"papers\":[],\"existingWorks\":[]}".utf8), try JSONSerialization.data(withJSONObject: object), try JSONSerialization.data(withJSONObject: missingCollection)] {
            try ResearchWidgetStorage.atomicWrite(bytes, to: url)
            try rejects("Invalid library projected an authoritative zero") { _ = try ResearchWidgetProjection.readLibrary(at: url, maximumSchema: 32) }
            try require(try ResearchWidgetStorage.readFile(at: url).data == bytes, "Rejected source was modified")
        }
    }
    static func pendingRecovery() throws {
        let path = try directory("pending")
        let repo = DiskLibraryRepository(applicationSupportURL: path.appendingPathComponent("Data"), legacyApplicationSupportURL: path.appendingPathComponent("NoLegacy"), migrationBackupsURL: path.appendingPathComponent("NoBackups"))
        let url = path.appendingPathComponent("statistics.json")
        let library = PersistedLibrary(papers: [paper("x")], existingWorks: [work("x")])
        _ = try writeLibrary(library, repository: repo, modifiedAt: first)
        let initial = try ResearchWidgetPublication.refresh(libraryURL: repo.libraryURL, snapshotURL: url, maximumSchema: 32, english: false, reason: "fixture", now: first)
        let initialBytes = try ResearchWidgetStorage.readFile(at: url).data
        try rejects("Publication IO failure ignored") {
            _ = try ResearchWidgetPublication.refresh(libraryURL: repo.libraryURL, snapshotURL: url, maximumSchema: 32, english: false, reason: "fixture-failure", now: later,
                write: { bytes, target in
                    if target == url { throw Failure(message: "injected primary failure") }
                    try ResearchWidgetStorage.atomicWrite(bytes, to: target)
                })
        }
        let pending = ResearchWidgetPublication.status(at: url)
        try require(pending?.pending == true && pending?.lastPublishedAt == first && pending?.failure != nil, "Failure did not durably retain pending/last success")
        try require(try ResearchWidgetStorage.readFile(at: url).data == initialBytes && ResearchWidgetStorage.read(at: url).snapshot == initial.snapshot, "Pending failure discarded last good")
        let repaired = try ResearchWidgetPublication.refresh(libraryURL: repo.libraryURL, snapshotURL: url, maximumSchema: 32, english: false, reason: "retry", now: later)
        try require(repaired.hadPending && repaired.snapshot.dataChangedAt == first && repaired.snapshot.generatedAt == later, "Retry invented business changes")
        try require(ResearchWidgetPublication.status(at: url)?.pending == false && ResearchWidgetPublication.status(at: url)?.lastPublishedAt == later, "Success failed to clear pending")
        var future = try JSONSerialization.jsonObject(with: ResearchWidgetStorage.readFile(at: url).data) as! [String: Any]
        future["schemaVersion"] = 999
        let futureBytes = try JSONSerialization.data(withJSONObject: future)
        try ResearchWidgetStorage.atomicWrite(futureBytes, to: url)
        try rejects("Common publication downgraded future primary") {
            _ = try ResearchWidgetPublication.refresh(libraryURL: repo.libraryURL, snapshotURL: url, maximumSchema: 32, english: false, reason: "future", now: later)
        }
        try require(ResearchWidgetPublication.status(at: url)?.pending == true && ResearchWidgetPublication.status(at: url)?.failure == "unsupportedSchema", "Future primary did not stay pending")
        try require(try ResearchWidgetStorage.readFile(at: url).data == futureBytes && ResearchWidgetStorage.read(at: url).snapshot == repaired.snapshot, "Future preservation lost fallback")
    }
    static func calendarCases() throws {
        func days(_ since: String, _ at: String, _ zone: String) -> Int {
            ResearchWidgetSnapshot.Paper(id: "x", title: "", number: "", since: date(since), terminal: false).days(at: date(at), calendar: calendar(zone))
        }
        try require(days("2026-01-31T23:59:00Z", "2026-02-01T00:01:00Z", "UTC") == 1, "Midnight/month boundary wrong")
        try require(days("2028-02-28T23:00:00Z", "2028-03-01T01:00:00Z", "UTC") == 2, "Leap month wrong")
        try require(days("2026-03-08T07:30:00Z", "2026-03-09T07:30:00Z", "America/Los_Angeles") == 2, "DST 23h day treated as 24h")
        try require(days("2026-11-01T07:30:00Z", "2026-11-02T08:30:00Z", "America/Los_Angeles") == 1, "DST 25h day wrong")
        try require(days("2026-10-16T15:30:00Z", "2026-10-16T16:30:00Z", "Asia/Shanghai") == 1 && days("2026-10-16T15:30:00Z", "2026-10-16T16:30:00Z", "UTC") == 0, "Time-zone calendar ignored")
        try require(days("2026-10-18T00:00:00Z", "2026-10-17T00:00:00Z", "UTC") == 0, "Future date produced negative duration")
        let cal = calendar("America/Los_Angeles")
        let spring = ResearchWidgetSchedule.entryDates(from: date("2026-03-07T20:00:00Z"), calendar: cal)
        let fall = ResearchWidgetSchedule.entryDates(from: date("2026-10-31T20:00:00Z"), calendar: cal)
        try require(spring.count == 8 && spring[2].timeIntervalSince(spring[1]) == 23 * 3600, "Future entries miss spring midnight")
        try require(fall[2].timeIntervalSince(fall[1]) == 25 * 3600, "Future entries miss fall midnight")
        let wake = date("2026-11-04T12:00:00Z")
        try require(ResearchWidgetSchedule.entryDates(from: wake, calendar: cal).first == wake, "Wake uses old entry time")
        let nearMidnight = date("2026-10-31T23:59:00Z")
        try require(ResearchWidgetSchedule.nextRefresh(after: nearMidnight, calendar: calendar("UTC")) == date("2026-11-01T00:00:00Z"), "Refresh skipped nearer midnight")
        try require(WidgetRowLayout(height: 308, itemCount: 9).count == 9 && WidgetRowLayout(height: 128, itemCount: 9).count == 5, "Existing supported layout changed")
        try require(SubmissionDurationWidget().kind == "ResearchSubmissionDuration" && AchievementStatisticsWidget().kind == "ResearchAchievementStatistics", "Stable Widget kinds changed")
    }
    static func main() {
        setbuf(stdout, nil)
        do {
            guard let path = ProcessInfo.processInfo.environment["GAO_WIDGET_TEST_ROOT"], path.hasPrefix("/private/tmp/"),
                  ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1",
                  ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"] == path + "/Data" else { throw Failure(message: "Unsafe fixture environment") }
            root = URL(fileURLWithPath: path, isDirectory: true)
            UserDefaults.standard.set("zh-Hans", forKey: "gqns.language")
            try pipeline(); print("PASS Widget real-library projection/time chain")
            try compatibilityAndFailures(); print("PASS Widget legacy/last-good/atomic-failure/revision")
            try unreadableLibraries(); print("PASS Widget missing/malformed/future library preservation")
            try pendingRecovery(); print("PASS Widget durable pending/retry/future-publication preservation")
            try calendarCases(); print("PASS Widget midnight/month/time-zone/DST/wake/layout")
            print("PASS Widget \(checks) targeted assertions; no GUI or Widget host was started")
        } catch { fputs("FAIL Widget: \(error)\n", stderr); exit(1) }
    }
}
