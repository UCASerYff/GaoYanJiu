import Foundation
import WidgetKit

/// Lifecycle callers request a verified publication; they never change the
/// business timestamp merely to make a widget look recent.
enum ResearchWidgetExportReason: String {
    case startup, libraryReloaded, dataSaved, activation, wake, calendarChanged, languageChanged, retry
}

struct ResearchWidgetExportStatus: Codable {
    let pending: Bool
    let reason: String
    let lastAttemptAt: Date
    let lastPublishedAt: Date?
    let failure: String?
    let schemaVersion: Int?
    let revision: String?
    let sourceRevision: String?
}

/// Pure projection of the real, successfully decoded on-disk library. This is
/// also used by isolated fixtures, rather than a second statistics algorithm.
enum ResearchWidgetProjection {
    static func make(library: PersistedLibrary, source: ResearchWidgetStorage.FileValue,
                     previous: ResearchWidgetSnapshot?, english: Bool, now: Date) -> ResearchWidgetSnapshot {
        let works = library.existingWorks
        let categories = ExistingWorkType.allCases.flatMap { type -> [ResearchWidgetSnapshot.Count] in
            if type == .patent {
                var result = PatentType.allCases.map { subtype in
                    ResearchWidgetSnapshot.Count(id: "patent-\(subtype.rawValue)", label: subtype.title,
                        count: works.filter { $0.type == .patent && $0.patentType == subtype }.count)
                }
                result.append(.init(id: "patent-unspecified", label: english ? "Other patents" : "未细分专利",
                                    count: works.filter { $0.type == .patent && $0.patentType == nil }.count))
                return result.filter { $0.count > 0 }
            }
            let count = works.filter { $0.type == type }.count
            return count == 0 ? [] : [.init(id: type.rawValue, label: type.title, count: count)]
        }
        var authors = AuthorPosition.allCases.map { position in
            ResearchWidgetSnapshot.Count(id: position.rawValue, label: position.title, count: works.filter { $0.authorPosition == position }.count)
        }
        let unassigned = works.filter { $0.authorPosition == nil }.count
        if unassigned > 0 { authors.append(.init(id: "unassigned", label: english ? "Unassigned" : "未填写", count: unassigned)) }
        let papers = library.papers.filter { !$0.hidden }.map { p in
            ResearchWidgetSnapshot.Paper(id: p.id, title: p.title, number: p.manuscriptID, since: p.statusSince,
                                         terminal: SubmissionStatusClassifier.isTerminal(p.status))
        }
        let candidate = ResearchWidgetSnapshot(updatedAt: source.modifiedAt, english: english, papers: papers,
                                               categories: categories, authors: authors, totalWorks: works.count,
                                               generatedAt: now, sourceModifiedAt: source.modifiedAt,
                                               sourceSchemaVersion: library.version, sourceRevision: source.revision)
        let changedAt = previous.flatMap { candidate.hasSameBusinessValues(as: $0) ? $0.dataChangedAt : nil } ?? source.modifiedAt
        let basis = previous.map { candidate.hasSameBusinessValues(as: $0) ? $0.dataChangedAtBasis : "observed-projection" } ?? "source-write-baseline"
        return ResearchWidgetSnapshot(updatedAt: changedAt, english: english, papers: papers, categories: categories,
                                      authors: authors, totalWorks: works.count, generatedAt: now,
                                      sourceModifiedAt: source.modifiedAt, sourceSchemaVersion: library.version, sourceRevision: source.revision, dataChangedAtBasis: basis)
    }
    static func readLibrary(at url: URL, maximumSchema: Int) throws -> (PersistedLibrary, ResearchWidgetStorage.FileValue) {
        let source = try ResearchWidgetStorage.readFile(at: url, maximumBytes: 128 * 1_048_576)
        let schema = try DiskLibraryRepository.libraryVersion(in: source.data)
        // Maintenance performs no migrations. Older libraries must first pass
        // the normal protected migration; newer ones remain untouched.
        guard schema == maximumSchema else { throw ResearchWidgetStorage.Failure.unsupportedSchema }
        try DiskLibraryRepository.validateStructure(source.data, version: schema)
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let library = try decoder.decode(PersistedLibrary.self, from: source.data)
        guard Set(library.papers.map(\.id)).count == library.papers.count,
              Set(library.existingWorks.map(\.id)).count == library.existingWorks.count else { throw ResearchWidgetStorage.Failure.invalidSnapshot }
        return (library, source)
    }
}

/// The same transaction is used by normal saves and explicit CLI maintenance.
/// Explicit paths/IO let fixtures exercise failure and recovery on private data.
enum ResearchWidgetPublication {
    struct Result { let snapshot: ResearchWidgetSnapshot; let previous: ResearchWidgetSnapshot?; let hadPending: Bool }
    static func statusURL(for url: URL) -> URL { url.deletingLastPathComponent().appendingPathComponent("statistics.export-status.json") }
    static func status(at url: URL) -> ResearchWidgetExportStatus? {
        (try? ResearchWidgetStorage.readFile(at: statusURL(for: url)).data)
            .flatMap { try? JSONDecoder().decode(ResearchWidgetExportStatus.self, from: $0) }
    }
    static func refresh(libraryURL: URL, snapshotURL: URL, maximumSchema: Int, english: Bool,
                        reason: String, now: Date = Date(),
                        write: (Data, URL) throws -> Void = { try ResearchWidgetStorage.atomicWrite($0, to: $1) }) throws -> Result {
        let oldStatus = status(at: snapshotURL)
        var candidate: ResearchWidgetSnapshot?
        func record(pending: Bool, failure: String?) throws {
            let value = ResearchWidgetExportStatus(pending: pending, reason: reason, lastAttemptAt: now,
                lastPublishedAt: pending ? oldStatus?.lastPublishedAt : now, failure: failure,
                schemaVersion: candidate?.schemaVersion, revision: candidate?.revision, sourceRevision: candidate?.sourceRevision)
            try write(JSONEncoder().encode(value), statusURL(for: snapshotURL))
        }
        do {
            let (library, source) = try ResearchWidgetProjection.readLibrary(at: libraryURL, maximumSchema: maximumSchema)
            let previous = ResearchWidgetStorage.read(at: snapshotURL, now: now).snapshot
            let snapshot = ResearchWidgetProjection.make(library: library, source: source, previous: previous, english: english, now: now)
            candidate = snapshot
            try record(pending: true, failure: nil)
            try ResearchWidgetStorage.publish(snapshot, to: snapshotURL, sourceIsCurrent: {
                try ResearchWidgetStorage.readFile(at: libraryURL, maximumBytes: 128 * 1_048_576).revision == source.revision
            }, write: write)
            try record(pending: false, failure: nil)
            return Result(snapshot: snapshot, previous: previous, hadPending: oldStatus?.pending == true)
        } catch {
            try? record(pending: true, failure: (error as? ResearchWidgetStorage.Failure)?.rawValue ?? "decode-or-publish-failed")
            throw error
        }
    }
    static func recordUnavailable(at url: URL?, reason: String, now: Date) {
        guard let url else { return }
        let oldStatus = status(at: url)
        let value = ResearchWidgetExportStatus(pending: true, reason: reason, lastAttemptAt: now,
            lastPublishedAt: oldStatus?.lastPublishedAt, failure: "unavailable", schemaVersion: nil, revision: nil, sourceRevision: nil)
        if let data = try? JSONEncoder().encode(value) { try? ResearchWidgetStorage.atomicWrite(data, to: statusURL(for: url)) }
    }
}

@MainActor
private final class ResearchWidgetRetryState {
    static var states: [ObjectIdentifier: ResearchWidgetRetryState] = [:]
    var pending = false
    var attempts = 0
    var task: Task<Void, Never>?
    var lastReloadAt: Date?
    static func state(for store: PaperStore) -> ResearchWidgetRetryState {
        let key = ObjectIdentifier(store)
        if let state = states[key] { return state }
        let state = ResearchWidgetRetryState(); states[key] = state; return state
    }
}

#if RESEARCH_WIDGET_STORE_REGRESSION
/// Available only in the isolated store-link test binary. Production builds
/// cannot redirect their App Group publication or replace WidgetKit requests.
@MainActor
enum ResearchWidgetStoreRegressionHooks {
    static var reloadKinds: [String] = []
    static var failNextPrimaryWrite = false

    static func snapshotURL(libraryURL: URL) -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1",
              let path = environment["GAO_WIDGET_STORE_TEST_ROOT"],
              path.hasPrefix("/private/tmp/"), path.hasSuffix(".noindex") else { return nil }
        // URL.standardizedFileURL rewrites an existing /private/tmp tree to
        // /tmp on macOS. Compare explicit paths without resolving that alias;
        // the production no-follow file IO still validates every component.
        let root = URL(fileURLWithPath: path, isDirectory: true)
        guard root.path == path, !root.pathComponents.contains(".."), !root.pathComponents.contains("."),
              environment["GAO_RESEARCH_DATA_DIR"] == root.appendingPathComponent("Data").path,
              libraryURL.isFileURL, libraryURL.path == root.appendingPathComponent("Data/library.json").path else { return nil }
        return root.appendingPathComponent("Widget/statistics.json")
    }

    static func write(_ data: Data, to url: URL) throws {
        if failNextPrimaryWrite && url.lastPathComponent == "statistics.json" {
            failNextPrimaryWrite = false
            throw ResearchWidgetStorage.Failure.writeFailed
        }
        try ResearchWidgetStorage.atomicWrite(data, to: url)
    }
}
#endif

extension PaperStore {
    private func reloadWidgetsForCurrentRelease(force: Bool, reason: ResearchWidgetExportReason, state: ResearchWidgetRetryState) {
        let release = ResearchBundle.bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let key = "lastWidgetLayoutRelease"
        guard force || ResearchBundle.defaults.string(forKey: key) != release else { return }
        if reason == .activation, let last = state.lastReloadAt, Date().timeIntervalSince(last) < 30 { return }
        // These are requests, not acknowledgements that WidgetKit rendered them.
#if RESEARCH_WIDGET_STORE_REGRESSION
        ResearchWidgetStoreRegressionHooks.reloadKinds += ["ResearchSubmissionDuration", "ResearchAchievementStatistics"]
#else
        WidgetCenter.shared.reloadTimelines(ofKind: "ResearchSubmissionDuration")
        WidgetCenter.shared.reloadTimelines(ofKind: "ResearchAchievementStatistics")
#endif
        state.lastReloadAt = Date()
        ResearchBundle.defaults.set(release, forKey: key)
    }

    func retryPendingWidgetSnapshot() {
#if RESEARCH_WIDGET_STORE_REGRESSION
        let url = ResearchWidgetStoreRegressionHooks.snapshotURL(libraryURL: repository.libraryURL)
#else
        guard ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"] == nil else { return }
        let url = ResearchWidgetSnapshot.fileURL
#endif
        let state = ResearchWidgetRetryState.state(for: self)
        let persisted = url.flatMap { ResearchWidgetPublication.status(at: $0) }
        guard state.pending || persisted?.pending == true else { return }
        exportWidgetSnapshot(reason: .retry)
    }

    func exportWidgetSnapshot(reason: ResearchWidgetExportReason = .dataSaved) {
        // CLI product fixtures cannot touch a real shared container.
#if RESEARCH_WIDGET_STORE_REGRESSION
        let url = ResearchWidgetStoreRegressionHooks.snapshotURL(libraryURL: repository.libraryURL)
#else
        guard ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"] == nil else { return }
        let url = ResearchWidgetSnapshot.fileURL
#endif
        let state = ResearchWidgetRetryState.state(for: self)
        let attemptedAt = Date()
        do {
            guard !libraryLoadFailed, let url else {
                ResearchWidgetPublication.recordUnavailable(at: url, reason: reason.rawValue, now: attemptedAt)
                throw ResearchWidgetStorage.Failure.unavailable
            }
#if RESEARCH_WIDGET_STORE_REGRESSION
            let write = ResearchWidgetStoreRegressionHooks.write
#else
            let write = ResearchWidgetStorage.atomicWrite
#endif
            let result = try ResearchWidgetPublication.refresh(libraryURL: repository.libraryURL, snapshotURL: url,
                maximumSchema: repository.currentVersion, english: AppLocalization.language == .english,
                reason: reason.rawValue, now: attemptedAt, write: write)
            let snapshot = result.snapshot
            let wasPending = state.pending || result.hadPending
            state.pending = false; state.attempts = 0; state.task?.cancel(); state.task = nil
            let changed = result.previous?.contentRevision != snapshot.contentRevision || result.previous?.schemaVersion != snapshot.schemaVersion
            reloadWidgetsForCurrentRelease(force: changed || wasPending || reason != .dataSaved, reason: reason, state: state)
            NSLog("Research widget publication: schema=%d revision=%@ dataChangedAt=%@ generatedAt=%@",
                  snapshot.schemaVersion, snapshot.revision ?? "legacy", snapshot.dataChangedAt.description, snapshot.generatedAt.description)
        } catch {
            state.pending = true
            let code = (error as? ResearchWidgetStorage.Failure)?.rawValue ?? "decode-or-publish-failed"
            NSLog("Research widget publication pending: reason=%@ failure=%@", reason.rawValue, code)
            // Bounded retry only after an actual failure. A subsequent lifecycle
            // event starts a fresh bounded attempt, never a periodic reload loop.
            if reason != .retry { state.attempts = 0; state.task?.cancel(); state.task = nil }
            let delays: [UInt64] = [2, 10, 30]
            guard state.task == nil, state.attempts < delays.count else { return }
            let delay = delays[state.attempts]; state.attempts += 1
            state.task = Task { @MainActor [weak self] in
                do { try await Task.sleep(nanoseconds: delay * 1_000_000_000) } catch { return }
                state.task = nil
                guard let self, state.pending else { return }
                self.exportWidgetSnapshot(reason: .retry)
            }
        }
    }
}

/// Explicit non-GUI maintenance entry points. They do not construct PaperStore,
/// initialize a library, run migrations/indexing, or change preference defaults.
public enum ResearchWidgetMaintenance {
    @MainActor public static func refreshFromDisk() throws -> Data {
        guard ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"] == nil,
              let url = ResearchWidgetSnapshot.fileURL else { throw ResearchWidgetStorage.Failure.unavailable }
        _ = try ResearchWidgetPublication.refresh(libraryURL: LibraryPaths.library, snapshotURL: url,
            maximumSchema: LibrarySchema.currentVersion, english: AppLocalization.language == .english, reason: "maintenance")
        WidgetCenter.shared.reloadTimelines(ofKind: "ResearchSubmissionDuration")
        WidgetCenter.shared.reloadTimelines(ofKind: "ResearchAchievementStatistics")
        return diagnostics()
    }

    public static func diagnostics() -> Data {
        var output: [String: Any] = ["formatVersion": 1, "observedAt": stamp(Date())]
        if ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"] != nil {
            output["failure"] = "isolated-fixture-no-real-container"
            return json(output)
        }
        let url = ResearchWidgetSnapshot.fileURL
        let read = ResearchWidgetStorage.read(at: url)
        output["publicationSource"] = read.source
        output["publicationReadFailure"] = read.failure ?? NSNull()
        if let snapshot = read.snapshot { output["snapshot"] = metadata(snapshot) }
        do {
            let (library, source) = try ResearchWidgetProjection.readLibrary(at: LibraryPaths.library, maximumSchema: LibrarySchema.currentVersion)
            let projected = ResearchWidgetProjection.make(library: library, source: source, previous: read.snapshot,
                                                          english: AppLocalization.language == .english, now: Date())
            output["library"] = ["schemaVersion": library.version, "revision": source.revision,
                                  "modifiedAt": stamp(source.modifiedAt), "visiblePapers": projected.papers.count,
                                  "totalWorks": projected.totalWorks]
            output["businessValuesMatch"] = read.snapshot.map { $0.hasSameBusinessValues(as: projected) } ?? false
            output["sourceRevisionMatches"] = read.snapshot?.sourceRevision == source.revision
        } catch { output["libraryReadFailure"] = (error as? ResearchWidgetStorage.Failure)?.rawValue ?? "decode-failed" }
        if let url {
            let directory = url.deletingLastPathComponent()
            // This is the extension's existing successful-read evidence; this
            // diagnostic call never updates or substitutes its own observedAt.
            if let data = try? ResearchWidgetStorage.readFile(at: directory.appendingPathComponent("statistics.read-status.json")).data,
               let status = try? JSONDecoder().decode(ResearchWidgetStorage.ReadStatus.self, from: data) {
                output["widgetReadStatus"] = ["lastAttemptAt": stamp(status.requestedAt), "requestKind": status.requestKind as Any? ?? NSNull(),
                    "source": status.source, "failure": status.failure as Any? ?? NSNull()]
                output["widgetLastRead"] = status.lastSuccessfulRead.map(evidenceMetadata) as Any? ?? NSNull()
                output["widgetLastTimelineRead"] = status.lastTimelineSuccess.map(evidenceMetadata) as Any? ?? NSNull()
                output["widgetLastTimelineAttempt"] = status.lastTimelineAttempt.map(evidenceMetadata) as Any? ?? NSNull()
                output["widgetLastSnapshotAt"] = status.lastSnapshotAt.map(stamp) as Any? ?? NSNull()
            } else { output["widgetLastRead"] = NSNull() }
            if let data = try? ResearchWidgetStorage.readFile(at: directory.appendingPathComponent("statistics.export-status.json")).data,
               let status = try? JSONDecoder().decode(ResearchWidgetExportStatus.self, from: data) {
                output["exportStatus"] = ["pending": status.pending, "reason": status.reason,
                    "lastAttemptAt": stamp(status.lastAttemptAt), "lastPublishedAt": status.lastPublishedAt.map(stamp) as Any? ?? NSNull(),
                    "failure": status.failure as Any? ?? NSNull()]
            }
        }
        return json(output)
    }
    private static func metadata(_ snapshot: ResearchWidgetSnapshot) -> [String: Any] {
        ["schemaVersion": snapshot.schemaVersion, "revision": snapshot.revision as Any? ?? NSNull(),
         "contentRevision": snapshot.contentRevision as Any? ?? NSNull(), "sourceRevision": snapshot.sourceRevision as Any? ?? NSNull(),
         "dataChangedAt": stamp(snapshot.dataChangedAt), "dataChangedAtBasis": snapshot.dataChangedAtBasis,
         "generatedAt": stamp(snapshot.generatedAt), "sourceModifiedAt": snapshot.sourceModifiedAt.map(stamp) as Any? ?? NSNull(),
         "visiblePapers": snapshot.papers.count, "totalWorks": snapshot.totalWorks,
         "categoryTotal": snapshot.categories.reduce(0) { $0 + $1.count }, "authorTotal": snapshot.authors.reduce(0) { $0 + $1.count }]
    }
    private static func evidenceMetadata(_ evidence: ResearchWidgetStorage.ReadEvidence) -> [String: Any] {
        ["requestedAt": stamp(evidence.requestedAt), "source": evidence.source,
         "failure": evidence.failure as Any? ?? NSNull(), "revision": evidence.revision as Any? ?? NSNull(),
         "sourceRevision": evidence.sourceRevision as Any? ?? NSNull(), "generatedAt": evidence.generatedAt.map(stamp) as Any? ?? NSNull(),
         "dataChangedAt": evidence.dataChangedAt.map(stamp) as Any? ?? NSNull()]
    }
    private static func stamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    private static func json(_ value: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])) ?? Data("{\"failure\":\"diagnostic-encoding\"}".utf8)
    }
}
