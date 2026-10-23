import Foundation
import Darwin

#if !RESEARCH_WIDGET_STORE_REGRESSION
#error("Use scripts/test_widget_store.sh with isolated data, publication paths and in-memory defaults.")
#endif

/// Match the existing product integration preference seam. No real preference
/// domain is opened by this executable, including from production sources.
final class UserDefaults {
    static let standard = UserDefaults(domain: "widget-store.standard")
    static let didChangeNotification = Notification.Name("ResearchWidgetStoreDefaultsChanged")
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

@MainActor
@main
struct ResearchWidgetStoreRegression {
    struct Failure: Error, CustomStringConvertible { let description: String }
    enum Injected: Error { case save }
    final class FaultingDiskRepository: LibraryRepository {
        let disk = DiskLibraryRepository()
        var failNextSave = false
        var libraryURL: URL { disk.libraryURL }
        var applicationSupportURL: URL { disk.applicationSupportURL }
        var currentVersion: Int { disk.currentVersion }
        var migrationThresholds: [Int] { disk.migrationThresholds }
        func loadLibrary(migratingWith migrate: (inout PersistedLibrary, Int) -> Void) -> LibraryLoadResult {
            disk.loadLibrary(migratingWith: migrate)
        }
        func saveLibrary(_ library: PersistedLibrary) throws {
            if failNextSave { failNextSave = false; throw Injected.save }
            try disk.saveLibrary(library)
        }
    }
    static var checks = 0
    static var snapshotURL: URL!
    static let since = ISO8601DateFormatter().date(from: "2026-10-21T03:00:00Z")!
    static func require(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try value() else { throw Failure(description: message) }; checks += 1
    }
    static func readSnapshot(_ repository: FaultingDiskRepository) throws -> ResearchWidgetSnapshot {
        let read = ResearchWidgetStorage.read(at: snapshotURL)
        guard let snapshot = read.snapshot else { throw Failure(description: "No readable store publication") }
        try require(read.source == "statistics", "Store publication used fallback unexpectedly")
        let source = try ResearchWidgetStorage.readFile(at: repository.libraryURL)
        try require(snapshot.sourceRevision == source.revision, "Publication is not bound to the durable library")
        return snapshot
    }
    static func durable(_ repository: FaultingDiskRepository) throws -> PersistedLibrary {
        try repository.disk.decoder.decode(PersistedLibrary.self, from: ResearchWidgetStorage.readFile(at: repository.libraryURL).data)
    }
    static func expectReloadPair(since start: Int) throws {
        try require(Array(ResearchWidgetStoreRegressionHooks.reloadKinds.dropFirst(start)) ==
                    ["ResearchSubmissionDuration", "ResearchAchievementStatistics"], "Changed store save did not request both stable widget kinds exactly once")
    }
    static func saveWork(_ store: PaperStore, id: String? = nil, type: ExistingWorkType = .journalArticle,
                         author: AuthorPosition? = .first, patent: PatentType? = nil) -> String {
        store.saveExistingWork(existingID: id, title: "Public synthetic widget fixture", type: type, venue: "Fixture venue",
            authors: "Fixture author", completedAt: since, identifier: "synthetic", url: "", notes: "isolated regression",
            patentType: patent, authorPosition: author, journalISSN: nil, journalMetrics: nil)
    }
    static func savePaper(_ store: PaperStore, id: String? = nil, title: String, status: String = "Under review") -> String {
        store.saveManualSubmission(existingID: id, title: title, venue: "Fixture journal", manuscriptID: "SYNTHETIC-001",
            status: status, statusSince: since, portalURL: "", notes: "isolated regression")
    }
    static func submissionLifecycle(_ store: PaperStore, _ repository: FaultingDiskRepository) throws {
        var start = ResearchWidgetStoreRegressionHooks.reloadKinds.count
        let id = savePaper(store, title: "Synthetic submission before edit")
        var snapshot = try readSnapshot(repository)
        try require(snapshot.papers.count == 1 && snapshot.papers[0].id == id && snapshot.papers[0].title == "Synthetic submission before edit", "Submission add did not reach snapshot")
        try require(try durable(repository).papers.first?.id == id, "Submission add was not durable")
        try expectReloadPair(since: start)

        start = ResearchWidgetStoreRegressionHooks.reloadKinds.count
        try require(savePaper(store, id: id, title: "Synthetic submission after edit", status: "Accepted") == id, "Submission edit changed its ID")
        snapshot = try readSnapshot(repository)
        try require(snapshot.papers.count == 1 && snapshot.papers[0].title == "Synthetic submission after edit" && snapshot.papers[0].terminal, "Submission edit was not projected")
        try expectReloadPair(since: start)

        start = ResearchWidgetStoreRegressionHooks.reloadKinds.count
        store.setArchived(store.papers[0], archived: true)
        try require(try readSnapshot(repository).papers.isEmpty && durable(repository).papers.first?.hidden == true, "Archived submission remained visible")
        try expectReloadPair(since: start)
        store.setArchived(store.papers[0], archived: false)
        try require(try readSnapshot(repository).papers.first?.id == id, "Unarchived submission missing")

        start = ResearchWidgetStoreRegressionHooks.reloadKinds.count
        store.delete(store.papers[0])
        try require(try readSnapshot(repository).papers.isEmpty && durable(repository).papers.isEmpty, "Submission deletion did not reach disk and snapshot")
        guard let item = store.trashItems.first(where: { $0.paper?.id == id }) else { throw Failure(description: "Deleted submission missing from trash") }
        try require(try durable(repository).trashItems.contains(where: { $0.id == item.id && $0.paper?.id == id }), "Submission trash was not durable")
        try expectReloadPair(since: start)
        start = ResearchWidgetStoreRegressionHooks.reloadKinds.count
        store.restoreTrashItem(id: item.id)
        try require(try readSnapshot(repository).papers.first?.id == id && durable(repository).papers.first?.id == id, "Submission restore did not preserve its ID")
        try require(!store.trashItems.contains(where: { $0.id == item.id }), "Restored submission remained in trash")
        try expectReloadPair(since: start)
    }
    static func workLifecycle(_ store: PaperStore, _ repository: FaultingDiskRepository) throws -> String {
        var start = ResearchWidgetStoreRegressionHooks.reloadKinds.count
        let id = saveWork(store)
        var snapshot = try readSnapshot(repository)
        try require(snapshot.totalWorks == 1 && snapshot.categories.first(where: { $0.id == "journalArticle" })?.count == 1 && snapshot.authors.first(where: { $0.id == "first" })?.count == 1, "Work add category/author statistics incorrect")
        try require(try durable(repository).existingWorks.first?.id == id, "Work add was not durable")
        try expectReloadPair(since: start)

        start = ResearchWidgetStoreRegressionHooks.reloadKinds.count
        try require(saveWork(store, id: id, type: .patent, author: .second, patent: .invention) == id, "Work edit changed its ID")
        snapshot = try readSnapshot(repository)
        try require(snapshot.totalWorks == 1 && snapshot.categories.first(where: { $0.id == "patent-invention" })?.count == 1 && snapshot.categories.first(where: { $0.id == "journalArticle" }) == nil, "Work edit did not move category")
        try require(snapshot.authors.first(where: { $0.id == "second" })?.count == 1 && snapshot.authors.first(where: { $0.id == "first" })?.count == 0, "Work edit did not move authorship")
        try expectReloadPair(since: start)

        start = ResearchWidgetStoreRegressionHooks.reloadKinds.count
        store.deleteExistingWork(store.existingWorks[0])
        snapshot = try readSnapshot(repository)
        try require(snapshot.totalWorks == 0 && snapshot.categories.isEmpty && snapshot.authors.allSatisfy { $0.count == 0 }, "Deleted work remained in statistics")
        try require(try durable(repository).existingWorks.isEmpty, "Work deletion was not durable")
        guard let item = store.trashItems.first(where: { $0.work?.id == id }) else { throw Failure(description: "Deleted work missing from trash") }
        try require(try durable(repository).trashItems.contains(where: { $0.id == item.id && $0.work?.id == id }), "Work trash was not durable")
        try expectReloadPair(since: start)
        start = ResearchWidgetStoreRegressionHooks.reloadKinds.count
        store.restoreTrashItem(id: item.id)
        snapshot = try readSnapshot(repository)
        try require(snapshot.totalWorks == 1 && durable(repository).existingWorks.first?.id == id, "Work restore did not preserve durable identity")
        try require(!store.trashItems.contains(where: { $0.id == item.id }), "Restored work remained in trash")
        try expectReloadPair(since: start)
        return id
    }
    static func failuresAndRecovery(_ store: PaperStore, _ repository: FaultingDiskRepository, workID: String) throws {
        var primary = try ResearchWidgetStorage.readFile(at: snapshotURL).data
        var fallback = try ResearchWidgetStorage.readFile(at: ResearchWidgetStorage.lastGoodURL(for: snapshotURL)).data
        let source = try ResearchWidgetStorage.readFile(at: repository.libraryURL).data
        let status = try ResearchWidgetStorage.readFile(at: ResearchWidgetPublication.statusURL(for: snapshotURL)).data
        var start = ResearchWidgetStoreRegressionHooks.reloadKinds.count
        repository.failNextSave = true
        _ = saveWork(store, id: workID, type: .book, author: .corresponding)
        try require(store.lastError != nil && !repository.failNextSave, "Repository save failure was not observed")
        try require(try ResearchWidgetStorage.readFile(at: repository.libraryURL).data == source, "Failed save changed the durable library")
        try require(try ResearchWidgetStorage.readFile(at: snapshotURL).data == primary && ResearchWidgetStorage.readFile(at: ResearchWidgetStorage.lastGoodURL(for: snapshotURL)).data == fallback, "Failed save published unsaved in-memory data")
        try require(try ResearchWidgetStorage.readFile(at: ResearchWidgetPublication.statusURL(for: snapshotURL)).data == status, "Failed library save started a widget publication")
        try require(ResearchWidgetStoreRegressionHooks.reloadKinds.count == start, "Failed library save requested a widget reload")
        store.save()
        var snapshot = try readSnapshot(repository)
        try require(snapshot.categories.first(where: { $0.id == "book" })?.count == 1 && snapshot.authors.first(where: { $0.id == "corresponding" })?.count == 1, "Successful save retry did not publish the durable change")
        try expectReloadPair(since: start)

        primary = try ResearchWidgetStorage.readFile(at: snapshotURL).data
        fallback = try ResearchWidgetStorage.readFile(at: ResearchWidgetStorage.lastGoodURL(for: snapshotURL)).data
        start = ResearchWidgetStoreRegressionHooks.reloadKinds.count
        ResearchWidgetStoreRegressionHooks.failNextPrimaryWrite = true
        _ = saveWork(store, id: workID, type: .software)
        try require(!ResearchWidgetStoreRegressionHooks.failNextPrimaryWrite, "Injected publication failure did not run")
        try require(try durable(repository).existingWorks.first?.type == .software, "Publication failure lost the successfully saved business edit")
        try require(try ResearchWidgetStorage.readFile(at: snapshotURL).data == primary && ResearchWidgetStorage.readFile(at: ResearchWidgetStorage.lastGoodURL(for: snapshotURL)).data == fallback, "Publication failure lost the previous valid publication")
        try require(ResearchWidgetPublication.status(at: snapshotURL)?.pending == true && ResearchWidgetPublication.status(at: snapshotURL)?.failure == "writeFailed", "Publication failure was not durably pending")
        try require(ResearchWidgetStoreRegressionHooks.reloadKinds.count == start, "Failed publication requested a widget reload")
        store.retryPendingWidgetSnapshot()
        snapshot = try readSnapshot(repository)
        try require(snapshot.categories.first(where: { $0.id == "software" })?.count == 1 && snapshot.categories.first(where: { $0.id == "book" }) == nil, "Explicit pending retry did not publish saved business values")
        try require(ResearchWidgetPublication.status(at: snapshotURL)?.pending == false, "Successful retry remained pending")
        try expectReloadPair(since: start)

        start = ResearchWidgetStoreRegressionHooks.reloadKinds.count
        let businessChangedAt = snapshot.dataChangedAt
        store.save()
        snapshot = try readSnapshot(repository)
        try require(snapshot.dataChangedAt == businessChangedAt, "Unchanged durable save invented a business change time")
        try require(ResearchWidgetStoreRegressionHooks.reloadKinds.count == start, "Unchanged save requested unnecessary reloads")
    }
    static func main() {
        setbuf(stdout, nil)
        do {
            guard let path = ProcessInfo.processInfo.environment["GAO_WIDGET_STORE_TEST_ROOT"],
                  path.hasPrefix("/private/tmp/"), path.hasSuffix(".noindex"),
                  ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1",
                  ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"] == path + "/Data" else { throw Failure(description: "Unsafe fixture environment") }
            UserDefaults.standard.set("zh-Hans", forKey: "gqns.language")
            let repository = FaultingDiskRepository()
            guard let url = ResearchWidgetStoreRegressionHooks.snapshotURL(libraryURL: repository.libraryURL) else { throw Failure(description: "Rejected isolated publication path") }
            snapshotURL = url
            try require(ResearchWidgetStoreRegressionHooks.snapshotURL(libraryURL: URL(fileURLWithPath: "/private/tmp/unrelated/library.json")) == nil, "Publication hook accepted an unrelated repository")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try repository.disk.initializeNewLibraryAfterUserConfirmation()
            try repository.disk.saveLibrary(PersistedLibrary(version: LibrarySchema.currentVersion))
            let store = PaperStore(repository: repository)
            try require(!store.libraryLoadFailed, "Isolated store failed to load")
            let baseline = try readSnapshot(repository)
            try require(baseline.totalWorks == 0 && baseline.papers.isEmpty, "Explicit empty fixture baseline incorrect")
            try submissionLifecycle(store, repository)
            print("PASS Widget store submission add/edit/archive/delete/restore -> durable library -> snapshot")
            let workID = try workLifecycle(store, repository)
            print("PASS Widget store achievement add/edit/delete/restore -> durable category/authorship totals")
            try failuresAndRecovery(store, repository, workID: workID)
            print("PASS Widget store failed library save, pending publication failure, explicit retry and unchanged-save behavior")
            print("PASS Widget store \(checks) targeted assertions; no App Group/defaults/WidgetCenter or GUI was used")
            print("Historical 73 widget assertions and user display/click/day/medium confirmations were preserved without rerunning them.")
        } catch { fputs("FAIL Widget store: \(error)\n", stderr); exit(1) }
    }
}
