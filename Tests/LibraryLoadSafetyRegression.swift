import AppKit
import Foundation
import CryptoKit
import PDFKit
import Darwin

#if !LIBRARY_LOAD_SAFETY_TEST
#error("Use scripts/test_library_load.sh: this test requires isolated data and in-memory defaults.")
#endif

/// Test-only isolation of preferences. The persistence/load adapters below
/// are the real product adapters and the real DiskLibraryRepository.
final class UserDefaults {
    static let standard = UserDefaults(domain: "fixture.standard")
    static let didChangeNotification = Notification.Name("ResearchProductFixtureDefaultsChanged")
    private static let lock = NSLock()
    private static var values: [String: [String: Any]] = [:]
    private let domain: String
    private init(domain: String) { self.domain = domain }
    convenience init?(suiteName: String?) {
        guard suiteName == "com.academic-achievement.manager.test.Research" else { return nil }
        self.init(domain: suiteName!)
    }
    func object(forKey key: String) -> Any? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return Self.values[domain]?[key]
    }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func integer(forKey key: String) -> Int { object(forKey: key) as? Int ?? 0 }
    func set(_ value: Any?, forKey key: String) {
        Self.lock.lock(); defer { Self.lock.unlock() }
        Self.values[domain, default: [:]][key] = value
    }
    func removeObject(forKey key: String) { set(nil, forKey: key) }
}

@MainActor
@main
struct LibraryLoadSafetyRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    final class Switch { var fail = false }
    final class FaultingRepository: LibraryRepository {
        let disk: DiskLibraryRepository
        var failures = 0
        var saves = 0
        init(_ disk: DiskLibraryRepository) { self.disk = disk }
        var libraryURL: URL { disk.libraryURL }
        var applicationSupportURL: URL { disk.applicationSupportURL }
        var currentVersion: Int { disk.currentVersion }
        var migrationThresholds: [Int] { disk.migrationThresholds }
        func loadLibrary(migratingWith migrate: (inout PersistedLibrary, Int) -> Void) -> LibraryLoadResult {
            disk.loadLibrary(migratingWith: migrate)
        }
        func saveLibrary(_ library: PersistedLibrary) throws {
            saves += 1
            if failures > 0 { failures -= 1; throw Failure(description: "injected save failure") }
            try disk.saveLibrary(library)
        }
    }
    static var root: URL!
    static var passed = 0
    static let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    static func require(_ value: @autoclosure () throws -> Bool, _ description: String) throws {
        guard try value() else { throw Failure(description: description) }
    }
    static func rejects(_ description: String, _ body: () throws -> Void) throws {
        do { try body() } catch { return }
        throw Failure(description: description)
    }
    static func run(_ name: String, _ body: (URL) throws -> Void) throws {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try body(directory)
        passed += 1
        print("PASS library safety \(name)")
    }
    static func repository(_ directory: URL, read: ((URL) throws -> Data)? = nil,
                           backup: ((Int) throws -> Void)? = nil) -> DiskLibraryRepository {
        DiskLibraryRepository(applicationSupportURL: directory.appendingPathComponent("Data"),
                              legacyApplicationSupportURL: directory.appendingPathComponent("Legacy"),
                              migrationBackupsURL: directory.appendingPathComponent("MigrationBackups"),
                              readData: read ?? { try GaoActionFileAccess.readPrivateData(at: $0, maximumBytes: 16 * 1_048_576) },
                              migrationBackup: backup)
    }
    static func fixture(version: Int = 32) -> PersistedLibrary {
        let paper = PaperRecord(key: "fixture-paper", sourceID: "manual", site: "fixture", url: "", manuscriptID: "P-1",
                                title: "Fixture paper", journal: "Fixture journal", status: "Under Review", checkedAt: stamp,
                                statusSince: stamp, statusSinceSource: "manual", previousStatus: nil, changed: false,
                                hidden: false, history: [StatusEvent(status: "Under Review", checkedAt: stamp)])
        let work = ExistingWork(id: "fixture-work", title: "Fixture work", type: .journalArticle, venue: "Fixture journal",
                                authors: "Fixture author", completedAt: stamp, identifier: "fixture", url: "", notes: "original",
                                attachments: [], createdAt: stamp, updatedAt: stamp, patentType: nil, journalISSN: nil,
                                journalMetrics: nil, authorPosition: .first)
        return PersistedLibrary(version: version, papers: [paper], existingWorks: [work],
                                rewardCity: RewardCityState(coins: 321.25, buildingTickets: 7, lastCoinCollectionAt: stamp))
    }
    static func encode(_ library: PersistedLibrary) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(library)
    }
    static func write(_ data: Data, _ url: URL, modifiedAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.modificationDate: modifiedAt, .posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func modified(_ url: URL) throws -> Date {
        try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!
    }
    static func intact(_ store: PaperStore) throws {
        try require(store.papers.map(\.id) == ["fixture-paper"], "paper IDs were cleared")
        try require(store.existingWorks.map(\.id) == ["fixture-work"], "work IDs were cleared")
        try require(store.rewardCity.coins == 321.25 && store.rewardCity.buildingTickets == 7, "game progress changed")
    }
    static func loaded(_ result: LibraryLoadResult) throws {
        guard case .loaded = result else { throw Failure(description: "expected successful load") }
    }
    static func failed(_ result: LibraryLoadResult) throws {
        guard case .corrupted(let name, _) = result, name == nil else { throw Failure(description: "expected failure with original file in place") }
    }
    static func main() throws {
        guard let path = ProcessInfo.processInfo.environment["GAO_LIBRARY_LOAD_TEST_ROOT"],
              ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"] != nil,
              ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1" else {
            throw Failure(description: "isolated test environment is required")
        }
        root = URL(fileURLWithPath: path, isDirectory: true)
        try require(root.path.hasPrefix("/private/tmp/"), "fixture root must be private tmp")
        defer { try? FileManager.default.removeItem(at: root) }
        try require(LibraryPaths.legacyApplicationSupport.path.hasPrefix(root.deletingLastPathComponent().path), "test hook escaped into real legacy storage")

        try run("explicit-initialization") { directory in
            let disk = repository(directory)
            let store = PaperStore(repository: disk)
            try require(store.libraryLoadFailed && store.libraryLoadFailureReason == .missing, "missing library was treated as empty")
            try require(!FileManager.default.fileExists(atPath: disk.libraryURL.path), "load created a default library")
            try require(store.libraryCanInitializeNew, "genuinely fresh path cannot be explicitly initialized")
            try rejects("save created an absent library") { try disk.saveLibrary(fixture()) }
            try store.initializeNewLibraryAfterUserConfirmation()
            try require(!store.libraryLoadFailed && store.libraryLastReadAt != nil && store.libraryLastModifiedAt != nil, "confirmed initialization did not load")
            let original = try Data(contentsOf: disk.libraryURL)
            try rejects("repeat initialization replaced a library") { try store.initializeNewLibraryAfterUserConfirmation() }
            try require(try Data(contentsOf: disk.libraryURL) == original, "repeat initialization changed bytes")
        }
        try run("existing-evidence-refuses-initialization") { directory in
            for clue in ["Data/Attachments/keep.bin", "Data/library.corrupted-old.json", "Legacy/library.json", "MigrationBackups/keep.json", "AcademicAchievementManager-AutomaticBackups/keep.json"] {
                let base = directory.appendingPathComponent(UUID().uuidString)
                let disk = repository(base)
                let file = base.appendingPathComponent(clue)
                try write(Data("fixture private data".utf8), file)
                try require(!disk.canInitializeNewLibrary, "existing clue allowed initialization")
                try rejects("existing clue was ignored") { try disk.initializeNewLibraryAfterUserConfirmation() }
                try require(try Data(contentsOf: file) == Data("fixture private data".utf8), "existing clue was altered")
            }
        }
        try run("last-good-widget-blocks-new-library") { directory in
            let snapshot = directory.appendingPathComponent("Widget/statistics.last-good.json")
            let bytes = Data("private last-good snapshot fixture".utf8)
            try write(bytes, snapshot)
            let disk = DiskLibraryRepository(applicationSupportURL: directory.appendingPathComponent("Data"),
                                             legacyApplicationSupportURL: directory.appendingPathComponent("Legacy"),
                                             migrationBackupsURL: directory.appendingPathComponent("Backups"),
                                             snapshotEvidenceURLs: [snapshot])
            let store = PaperStore(repository: disk)
            try require(store.libraryLoadFailed && !store.libraryCanInitializeNew, "last-good widget snapshot was ignored")
            try rejects("last-good widget allowed an empty new library") { try store.initializeNewLibraryAfterUserConfirmation() }
            try require(try Data(contentsOf: snapshot) == bytes, "last-good snapshot changed")
        }
        try run("corruption-restart-no-empty-library") { directory in
            let disk = repository(directory)
            let bytes = Data("{truncated-private-fixture".utf8)
            try write(bytes, disk.libraryURL)
            for _ in 0..<3 {
                let fresh = repository(directory)
                let store = PaperStore(repository: fresh)
                try require(store.libraryLoadFailed && store.libraryLoadFailureReason == .corrupted && !store.libraryCanInitializeNew, "corrupt restart became a fresh library")
                store.save()
                try require(try Data(contentsOf: disk.libraryURL) == bytes && modified(disk.libraryURL) == stamp, "corrupt bytes/mtime changed")
                try require(try FileManager.default.contentsOfDirectory(atPath: disk.applicationSupportURL.path) == ["library.json"], "load moved/quarantined source")
            }
        }
        try run("missing-retains-memory-time-and-retry") { directory in
            let disk = repository(directory)
            let original = try encode(fixture())
            try write(original, disk.libraryURL)
            let store = PaperStore(repository: disk)
            try intact(store)
            let readAt = store.libraryLastReadAt
            try FileManager.default.removeItem(at: disk.libraryURL)
            for _ in 0..<2 {
                store.load(); store.save()
                try require(store.libraryLoadFailed && !store.libraryCanInitializeNew, "known missing library became new")
                try intact(store)
                try require(store.libraryLastModifiedAt == stamp && store.libraryLastReadAt == readAt, "failed read forged successful timestamps")
                try require(!FileManager.default.fileExists(atPath: disk.libraryURL.path), "failure recreated missing source")
            }
            try write(original, disk.libraryURL)
            store.load()
            try require(!store.libraryLoadFailed, "restored library could not be retried")
            try require(store.libraryLastModifiedAt == stamp && store.libraryLastReadAt! >= readAt!, "retry did not retain source mtime and record a successful read")
            try intact(store)
            store.existingWorks[0].notes = "after recovery"
            try store.saveThrowing()
        }
        try run("corruption-retains-last-good-memory") { directory in
            let disk = repository(directory)
            let original = try encode(fixture())
            try write(original, disk.libraryURL)
            let store = PaperStore(repository: disk)
            let readAt = store.libraryLastReadAt
            let corrupt = Data("{}".utf8)
            try write(corrupt, disk.libraryURL)
            store.load(); store.save()
            try intact(store)
            try require(store.libraryLoadFailed && store.libraryLastReadAt == readAt && store.libraryLastModifiedAt == stamp, "corrupt load changed last-good state")
            try require(try Data(contentsOf: disk.libraryURL) == corrupt, "corrupt source overwritten")
            try rejects("repository bypassed failed-read latch") { try disk.saveLibrary(fixture()) }
            try write(original, disk.libraryURL); store.load(); try store.saveThrowing()
        }
        try run("unreadable-is-not-corruption-or-new") { directory in
            let control = Switch()
            let disk = repository(directory, read: { url in
                if control.fail { throw CocoaError(.fileReadNoPermission) }
                return try GaoActionFileAccess.readPrivateData(at: url, maximumBytes: 16 * 1_048_576)
            })
            let original = try encode(fixture()); try write(original, disk.libraryURL)
            let store = PaperStore(repository: disk)
            let readAt = store.libraryLastReadAt
            control.fail = true; store.load(); store.save()
            try intact(store)
            try require(store.libraryLoadFailureReason == .unreadable && !store.libraryCanInitializeNew, "permission error became new/corrupt library")
            try require(store.libraryLastReadAt == readAt && store.libraryLastModifiedAt == stamp, "permission failure changed timestamps")
            try require(try Data(contentsOf: disk.libraryURL) == original && modified(disk.libraryURL) == stamp, "permission failure altered source")
            control.fail = false; store.load(); try store.saveThrowing()
        }
        try run("future-schema-before-full-decode") { directory in
            let disk = repository(directory)
            try write(encode(fixture()), disk.libraryURL)
            let store = PaperStore(repository: disk)
            let readAt = store.libraryLastReadAt
            let future = Data("{\"version\":999,\"papers\":{\"new-format\":true}}".utf8)
            try write(future, disk.libraryURL)
            store.load()
            try intact(store)
            try require(store.libraryLoadFailureReason == .futureVersion && store.libraryLastReadAt == readAt, "future schema incorrectly decoded/quarantined")
            try require(try Data(contentsOf: disk.libraryURL) == future && modified(disk.libraryURL) == stamp, "future schema altered")
            try rejects("future schema overwritten") { try disk.saveLibrary(fixture()) }
        }
        try run("structure-validation-and-legacy-compatibility") { directory in
            for text in ["{}", "[]", "null", "{\"version\":true,\"papers\":[]}", "{\"version\":32,\"papers\":[]}", "{\"version\":32,\"papers\":null}"] {
                let disk = repository(directory.appendingPathComponent(UUID().uuidString))
                let data = Data(text.utf8); try write(data, disk.libraryURL)
                try failed(disk.loadLibrary { _, _ in })
                try require(try Data(contentsOf: disk.libraryURL) == data, "invalid structure changed")
            }
            for text in ["{\"papers\":[]}", "{\"version\":31,\"papers\":[]}"] {
                let disk = repository(directory.appendingPathComponent(UUID().uuidString), backup: { _ in })
                try write(Data(text.utf8), disk.libraryURL)
                try loaded(disk.loadLibrary { _, _ in })
            }
        }
        try run("migration-backup-failure-stops-before-migrations") { directory in
            let control = Switch(); control.fail = true
            let disk = repository(directory, backup: { _ in if control.fail { throw Failure(description: "backup fixture failure") } })
            let original = try encode(fixture(version: 31)); try write(original, disk.libraryURL)
            var migrations = 0
            try failed(disk.loadLibrary { _, _ in migrations += 1 })
            try require(migrations == 0, "migration ran after failed backup")
            let store = PaperStore(repository: disk)
            try require(store.libraryLoadFailed && store.libraryLoadFailureReason == .migrationBackupFailed, "backup failure did not block persistence")
            try require(try Data(contentsOf: disk.libraryURL) == original && modified(disk.libraryURL) == stamp, "failed backup migrated source")
            control.fail = false; store.load()
            try require(!store.libraryLoadFailed, "backup retry could not complete")
            try intact(store)
            try require(try DiskLibraryRepository.libraryVersion(in: Data(contentsOf: disk.libraryURL)) == 32, "retry did not persist existing schema")
        }
        try run("save-failure-keeps-disk-and-pending-memory") { directory in
            let disk = repository(directory); let original = try encode(fixture()); try write(original, disk.libraryURL)
            let fault = FaultingRepository(disk); let store = PaperStore(repository: fault)
            let readAt = store.libraryLastReadAt
            store.existingWorks[0].notes = "pending fixture edit"; fault.failures = 2
            for _ in 0..<2 { store.save() }
            try require(store.persistenceAlert != nil && !store.libraryLoadFailed, "save failure warning/retry state wrong")
            try require(try Data(contentsOf: disk.libraryURL) == original && modified(disk.libraryURL) == stamp, "failed save changed original")
            try require(store.existingWorks[0].notes == "pending fixture edit" && store.libraryLastModifiedAt == stamp && store.libraryLastReadAt == readAt, "save failure lost pending memory or forged time")
            store.save()
            try require(store.persistenceAlert == nil && store.libraryLastModifiedAt != stamp, "retry did not persist/reset warning")
            let decoded = try disk.decoder.decode(PersistedLibrary.self, from: Data(contentsOf: disk.libraryURL))
            try require(decoded.existingWorks[0].notes == "pending fixture edit", "retry lost pending edit")
        }
        try run("external-durable-change-not-overwritten") { directory in
            let disk = repository(directory); try write(encode(fixture()), disk.libraryURL)
            try loaded(disk.loadLibrary { _, _ in })
            var external = fixture(); external.existingWorks[0].notes = "external valid change"
            let changed = try encode(external); try write(changed, disk.libraryURL)
            try rejects("stale store overwrote changed durable library") { try disk.saveLibrary(fixture()) }
            try require(try Data(contentsOf: disk.libraryURL) == changed, "valid external change was replaced")
        }
        try run("legacy-copy-is-complete-before-publication") { directory in
            let disk = repository(directory)
            let legacy = disk.legacyApplicationSupportURL
            let original = try encode(fixture())
            let attachment = Data("private legacy attachment fixture".utf8)
            try write(original, legacy.appendingPathComponent("library.json"))
            try write(attachment, legacy.appendingPathComponent("Attachments/fixture.bin"))
            let loadedResult = disk.loadLibrary { _, _ in }
            guard case .loaded(_, _, true, _) = loadedResult else { throw Failure(description: "legacy copy not reported") }
            try require(try Data(contentsOf: disk.libraryURL) == original, "legacy JSON copy differs")
            try require(try Data(contentsOf: disk.applicationSupportURL.appendingPathComponent("Attachments/fixture.bin")) == attachment, "legacy attachment missing")
            try require(try Data(contentsOf: legacy.appendingPathComponent("library.json")) == original, "legacy original changed")
        }
        try run("interrupted-legacy-staging-does-not-publish") { directory in
            let control = Switch(); control.fail = true
            let disk = repository(directory, read: { url in
                if control.fail && url.path.contains(".ResearchLegacyMigration-") { throw Failure(description: "staging verification failure") }
                return try GaoActionFileAccess.readPrivateData(at: url, maximumBytes: 16 * 1_048_576)
            })
            let original = try encode(fixture()); try write(original, disk.legacyApplicationSupportURL.appendingPathComponent("library.json"))
            try failed(disk.loadLibrary { _, _ in })
            try require(!FileManager.default.fileExists(atPath: disk.libraryURL.path), "partial legacy copy became live")
            try require(try Data(contentsOf: disk.legacyApplicationSupportURL.appendingPathComponent("library.json")) == original, "failed legacy copy lost original")
            control.fail = false; try loaded(disk.loadLibrary { _, _ in })
        }
        try run("initialization-race-and-symlink-refused") { directory in
            let disk = repository(directory)
            try require(disk.canInitializeNewLibrary, "fixture should be initially fresh")
            let original = try encode(fixture()); try write(original, disk.libraryURL)
            try rejects("initialization replaced racing valid file") { try disk.initializeNewLibraryAfterUserConfirmation() }
            try require(try Data(contentsOf: disk.libraryURL) == original, "racing valid file changed")
            try FileManager.default.removeItem(at: disk.libraryURL)
            let other = directory.appendingPathComponent("Other.json"); try write(original, other)
            try FileManager.default.createSymbolicLink(at: disk.libraryURL, withDestinationURL: other)
            try failed(disk.loadLibrary { _, _ in })
            try rejects("symlink was overwritten") { try disk.saveLibrary(fixture()) }
            try require(try Data(contentsOf: other) == original, "symlink target changed")
        }
        print("Library safety: \(passed) isolated groups passed; no GUI, live data or real preferences were used.")
    }
}
