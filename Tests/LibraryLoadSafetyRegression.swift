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
    static var assertions = 0
    static let stamp = Date(timeIntervalSince1970: 1_700_000_000)
    static func require(_ value: @autoclosure () throws -> Bool, _ description: String) throws {
        guard try value() else { throw Failure(description: description) }
        assertions += 1
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

    // This focused regression uses the production store, repository, package
    // validator, review, journal, atomic batch adapter and indexer. Only the
    // provider's already-produced synthetic bytes and its normal wire manifest
    // are fixture data; no provider/AppKit/PDF rendering is invoked.
    @MainActor
    struct OCRFixture {
        var store: PaperStore
        var fault: FaultingRepository
        var initial: PersistedLibrary
        var originalBytes: Data
        var directory: URL
        var sourceID: String { initial.managedDocuments[0].id }
        var siblingID: String { initial.managedDocuments[1].id }
        var source: ManagedDocument { store.managedDocuments.first { $0.id == sourceID }! }
        var originalURL: URL { store.managedDocumentURL(initial.managedDocuments[0]) }
        var disk: DiskLibraryRepository { fault.disk }
        func durable() throws -> PersistedLibrary {
            try disk.decoder.decode(PersistedLibrary.self, from: Data(contentsOf: disk.libraryURL))
        }
    }
    static func unwrap<T>(_ value: T?, _ description: String) throws -> T {
        guard let value else { throw Failure(description: description) }; return value
    }
    static func runAsync(_ name: String, category: String = "OCR revision ordering",
                         _ body: (URL) async throws -> Void) async throws {
        let directory = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await body(directory)
        passed += 1
        print("PASS \(category) \(name)")
        fflush(stdout)
    }
    static func mustReject(_ description: String, _ body: () async throws -> Void) async throws {
        var rejected = false
        do { try await body() } catch { rejected = true }
        try require(rejected, description)
    }
    static func ocrFixture(_ directory: URL, missingSourceOrder: Bool = true) throws -> OCRFixture {
        let prefix = UUID().uuidString
        let primary = DocumentFolder(id: prefix + "-folder", libraryKind: .experimentData,
                                     name: "Synthetic OCR records", createdAt: stamp, updatedAt: stamp, sortOrder: 0)
        let other = DocumentFolder(id: prefix + "-other", libraryKind: .experimentData,
                                   name: "Synthetic other scope", createdAt: stamp, updatedAt: stamp, sortOrder: 1)
        let png = try unwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aP6kAAAAASUVORK5CYII="), "synthetic PNG missing")
        let original = ManagedDocument(id: prefix + "-source", folderID: primary.id,
            originalName: "source.png", displayName: "Synthetic source", storedName: "source.png", fileExtension: "png",
            tags: ["original-tag"], byteCount: Int64(png.count), uploadedAt: stamp, updatedAt: stamp,
            contentText: "original indexed sentinel", contentIndexedAt: stamp, sortOrder: missingSourceOrder ? nil : 1)
        let siblingBytes = Data("existing sibling bytes".utf8), otherBytes = Data("other scope bytes".utf8)
        let sibling = ManagedDocument(id: prefix + "-sibling", folderID: primary.id,
            originalName: "sibling.txt", displayName: "Existing sibling", storedName: "sibling.txt", fileExtension: "txt",
            tags: ["sibling-tag"], byteCount: Int64(siblingBytes.count), uploadedAt: stamp.addingTimeInterval(10), updatedAt: stamp,
            contentText: "sibling indexed sentinel", contentIndexedAt: stamp, sortOrder: 0)
        let unrelated = ManagedDocument(id: prefix + "-unrelated", folderID: other.id,
            originalName: "unrelated.txt", displayName: "Other scope sentinel", storedName: "other.txt", fileExtension: "txt",
            tags: [], byteCount: Int64(otherBytes.count), uploadedAt: stamp, updatedAt: stamp,
            contentText: "unrelated indexed sentinel", contentIndexedAt: stamp, sortOrder: 0)
        var library = fixture(); library.papers[0].sortOrder = 0; library.existingWorks[0].sortOrder = 0
        library.documentFolders = [primary, other]
        library.managedDocuments = [original, sibling, unrelated] // Durable array order deliberately differs from UI order.
        let disk = repository(directory)
        for (document, bytes) in zip(library.managedDocuments, [png, siblingBytes, otherBytes]) {
            let folder = library.documentFolders.first { $0.id == document.folderID }!
            let url = LibraryPaths.managedDocuments.appendingPathComponent(folder.libraryKind.rawValue)
                .appendingPathComponent(folder.id).appendingPathComponent(document.storedName)
            try write(bytes, url)
        }
        let initialData = try encode(library)
        try write(initialData, disk.libraryURL)
        let fault = FaultingRepository(disk), store = PaperStore(repository: fault)
        try require(!store.libraryLoadFailed, "OCR fixture failed actual schema-32 load")
        try require(try Data(contentsOf: disk.libraryURL) == initialData, "loading normalized raw fixture on disk")
        try require(store.managedDocuments.first { $0.id == original.id }?.sortOrder == 1,
                    "real load did not normalize memory source to order 1")
        return .init(store: store, fault: fault, initial: library, originalBytes: png, directory: directory)
    }
    static func fixtureRequest(_ fixture: OCRFixture, action: ResearchExternalAction) throws -> ResearchPreparedExchange {
        let source = fixture.source, url = fixture.store.managedDocumentURL(source)
        let fingerprint = try GaoActionFileAccess.fingerprint(at: url)
        let item = GaoActionItem(id: "fixture-input", relativePath: "payload/source.png", uti: "public.png",
                                 byteCount: fingerprint.byteCount, sha256: fingerprint.sha256)
        let parameters: [String: GaoJSONValue] = action == .ocrFiles
            ? ["outputs": .array([.string("text"), .string("json")])] : [:]
        let manifest = GaoActionManifest(sourceBundleID: ResearchExchangePaths.bundleID,
            targetBundleID: action.providerBundleID, action: action.rawValue, items: [item], parameters: parameters)
        let package = try GaoActionPackageWriter().write(manifest: manifest, files: [item.id: url],
            outgoingRoot: ResearchExchangePaths.root.appendingPathComponent("Outgoing"))
        let written = try JSONDecoder().decode(GaoActionManifest.self,
            from: GaoActionFileAccess.readPrivateData(at: package.appendingPathComponent("manifest.json")))
        let session = ResearchExchangeSession(requestID: written.requestID, providerBundleID: written.targetBundleID,
            action: action, requestNonce: written.nonce, packageURL: package.absoluteString, createdAt: Date(),
            sources: [.init(itemID: item.id, documentID: source.id, originalFileURL: url.standardizedFileURL.absoluteString,
                sha256: fingerprint.sha256, byteCount: fingerprint.byteCount, identity: fingerprint.identity,
                documentVersion: action == .openDocument ? source.updatedAt : nil)], state: "prepared", resultIDs: [], importedEditedSHA256: nil)
        try GaoActionFileAccess.writePrivateData(JSONEncoder().encode(session),
            to: ResearchExchangePaths.root.appendingPathComponent("Sessions/" + written.requestID + ".json"))
        return .init(packageURL: package, requestID: written.requestID, action: action, parameters: parameters)
    }
    static func ocrReview(_ fixture: OCRFixture) throws -> (ResearchPreparedExchange, PendingExchangeResultReview) {
        let request = try fixtureRequest(fixture, action: .ocrFiles)
        let binding = try unwrap(fixture.store.documentLibrary.exchangeClient.loadSession(request.requestID).sources.first,
                                 "OCR source binding missing")
        let first = fixture.directory.appendingPathComponent("recognized.txt")
        let json = fixture.directory.appendingPathComponent("recognized.json")
        let third = fixture.directory.appendingPathComponent("recognized-extra.txt")
        try write(Data("synthetic first OCR output needle-one".utf8), first)
        try write(Data("synthetic third OCR output needle-three".utf8), third)
        let jsonValue: [String: Any] = ["schemaVersion": 1,
            "sources": [["id": "fixture-source", "sha256": binding.sha256]],
            "pages": [["sourceID": "fixture-source", "originalSHA256": binding.sha256, "pageNumber": 1,
                       "status": "completed", "lines": [["readingOrder": 1, "text": "synthetic page-one text"]]]]]
        try write(JSONSerialization.data(withJSONObject: jsonValue), json)
        let files = [first, json, third]
        let items = files.enumerated().map { offset, file in
            GaoActionItem(id: "output-\(offset)", relativePath: "payload/output-\(offset).\(file.pathExtension)",
                          uti: file.pathExtension == "json" ? "public.json" : "public.utf8-plain-text",
                          byteCount: 0, sha256: String(repeating: "0", count: 64))
        }
        let source: GaoJSONValue = .object(["sourceID": .string("fixture-source"), "sourceItemID": .string(binding.itemID),
            "sourceSHA256": .string(binding.sha256), "outputItemIDs": .array(items.map { .string($0.id) }),
            "pages": .array([.object(["pageNumber": .number(1), "status": .string("completed"), "lineCount": .number(1)])])])
        let outputs = items.map { item -> GaoJSONValue in
            .object(["resultItemID": .string(item.id), "sourceID": .string("fixture-source"),
                     "sourceItemID": .string(binding.itemID), "sourceSHA256": .string(binding.sha256)])
        }
        let provenance: [String: GaoJSONValue] = ["engine": .string("Synthetic OCR fixture"), "engineVersion": .string("1"),
            "languages": .array([.string("en-US")]), "sources": .array([source]), "outputs": .array(outputs), "networkUsed": .bool(false)]
        let result = GaoActionManifest(kind: "result", sourceBundleID: ResearchExternalAction.ocrFiles.providerBundleID,
            targetBundleID: ResearchExchangePaths.bundleID, action: ResearchExternalAction.ocrFiles.rawValue,
            items: items, inReplyTo: request.requestID, status: "completed", provenance: provenance)
        let package = try GaoActionPackageWriter().write(manifest: result,
            files: Dictionary(uniqueKeysWithValues: zip(items.map(\.id), files)),
            outgoingRoot: fixture.directory.appendingPathComponent("ProviderOutgoing"))
        let review = try fixture.store.documentLibrary.receiveExchangeResultForReview(at: package)
        try require(review.canApply && review.result.ocrOutputs.count == 3 && fixture.store.managedDocuments.count == 3,
                    "normal review did not retain three outputs behind explicit approval")
        try require(review.ocrReviewPages.values.allSatisfy { $0.first?.text == "synthetic page-one text" },
                    "normal JSON page association lost original source mapping")
        return (request, review)
    }
    static func unchangedSentinels(_ fixture: OCRFixture) throws {
        let durable = try fixture.durable()
        try require(durable.papers == fixture.initial.papers && durable.existingWorks == fixture.initial.existingWorks,
                    "OCR changed paper/work sentinels")
        try require(durable.rewardCity == fixture.initial.rewardCity && durable.documentFolders == fixture.initial.documentFolders,
                    "OCR changed game/folder sentinels")
    }
    static func noAppliedReceipt(_ fixture: OCRFixture, _ request: ResearchPreparedExchange, _ review: PendingExchangeResultReview) throws {
        try require(try fixture.store.documentLibrary.exchangeClient.loadSession(request.requestID).appliedResults?[review.id] == nil,
                    "uncommitted/unindexed OCR acquired an applied business receipt")
    }

    /// Exercise the same provider package writer and receiver as a normal
    /// Send-result click. Packaging paths are transport-only: every wrapper
    /// gets new nested directories/basenames, UUID, nonce and lifetime, while
    /// verified item IDs, extensions, bytes, UTIs and full provenance stay put.
    static func repackedOCRReview(_ fixture: OCRFixture, template: PendingExchangeResultReview,
                                  store: PaperStore, round: Int) throws -> PendingExchangeResultReview {
        var manifest = template.result.package.manifest
        manifest.requestID = UUID().uuidString
        let files = Dictionary(uniqueKeysWithValues: template.result.package.stagedItems.map { ($0.item.id, $0.url) })
        for index in manifest.items.indices {
            let ext = (manifest.items[index].relativePath as NSString).pathExtension
            manifest.items[index].relativePath = "payload/rewrap-\(UUID().uuidString)/nested-\(UUID().uuidString)/\(UUID().uuidString).\(ext)"
        }
        var writer = GaoActionPackageWriter()
        // Distinct valid TTLs avoid relying on a wall-clock sleep/millisecond
        // boundary to prove that transport-only lifetime fields changed.
        writer.limits.ttl = TimeInterval(110 + round)
        let package = try writer.write(manifest: manifest, files: files,
            outgoingRoot: fixture.directory.appendingPathComponent("FreshProviderOutgoing"))
        let review = try store.documentLibrary.receiveExchangeResultForReview(at: package)
        let actual = review.result.package.manifest, original = template.result.package.manifest
        try require(actual.requestID != original.requestID && actual.nonce != original.nonce && actual.expiresAt != original.expiresAt,
                    "fresh provider wrapper did not change UUID/nonce/lifetime")
        try require(actual.items.map(\.relativePath) != original.items.map(\.relativePath),
                    "fresh provider wrapper retained transport paths")
        try require(actual.provenance == original.provenance && actual.status == original.status &&
                    actual.parameters == original.parameters && actual.references == original.references,
                    "repack fixture changed semantic provenance/status/parameters/references")
        try require(actual.items.map(\.id) == original.items.map(\.id) &&
                    actual.items.map(\.sha256) == original.items.map(\.sha256) &&
                    actual.items.map(\.byteCount) == original.items.map(\.byteCount) &&
                    actual.items.map(\.uti) == original.items.map(\.uti) &&
                    actual.items.map { ($0.relativePath as NSString).pathExtension } ==
                    original.items.map { ($0.relativePath as NSString).pathExtension },
                    "fresh wrapper changed stable item identity/content/extension/UTI")
        try require(review.canApply && review.result.ocrOutputs.count == 3,
                    "fresh normal provider result was not reviewable")
        return review
    }

    /// File bytes and directory membership, including empty directories. Only
    /// isolated test roots are admitted; no real library/preferences are read.
    static func isolatedTree(_ directory: URL) throws -> [String: String] {
        let dataOverride = try unwrap(ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"], "isolated data override absent")
        let rawAllowed = URL(fileURLWithPath: (dataOverride as NSString).deletingLastPathComponent, isDirectory: true)
        let allowed = rawAllowed.resolvingSymlinksInPath().standardizedFileURL
        let rawParts = directory.pathComponents
        try require([rawAllowed.pathComponents, allowed.pathComponents].contains { prefix in
            rawParts.count > prefix.count && Array(rawParts.prefix(prefix.count)) == prefix
        } && !rawParts.contains("..") && !rawParts.contains("."),
                    "audit raw path escaped isolated fixture root: \(directory.path) outside \(rawAllowed.path)")
        // A missing tree contains no files to audit. Do not ask Foundation to
        // resolve its nonexistent suffix: only the existing base becomes/tmp.
        guard FileManager.default.fileExists(atPath: directory.path) else { return [:] }
        let candidate = directory.resolvingSymlinksInPath().standardizedFileURL
        let allowedParts = allowed.pathComponents, candidateParts = candidate.pathComponents
        try require(candidateParts.count > allowedParts.count &&
                    Array(candidateParts.prefix(allowedParts.count)) == allowedParts,
                    "audit escaped isolated fixture root: \(candidate.path) outside \(allowed.path)")
        var result: [String: String] = [:]
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else {
            throw Failure(description: "cannot enumerate isolated audit tree")
        }
        for case let file as URL in iterator {
            let values = try file.resourceValues(forKeys: Set(keys))
            try require(values.isSymbolicLink != true, "unexpected symlink in isolated fixture")
            let name = String(file.path.dropFirst(directory.path.count + 1))
            if values.isDirectory == true { result["directory:" + name] = "directory" }
            else {
                try require(values.isRegularFile == true, "unexpected nonregular isolated fixture")
                let data = try GaoActionFileAccess.readPrivateData(at: file, maximumBytes: 128 * 1_048_576)
                result["file:" + name] = "\(data.count):" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            }
        }
        return result
    }

    static func sealedOCRState(_ fixture: OCRFixture) throws -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for path in ["Metadata/ImportJobs", "Metadata/ProcessedRequests", "Metadata/DocumentProvenance",
                     "Metadata/AttachmentRevisions", "Metadata/DocumentHistory", "Snapshots"] {
            result[path] = try isolatedTree(ResearchExchangePaths.root.appendingPathComponent(path))
        }
        result["ManagedDocuments"] = try isolatedTree(LibraryPaths.managedDocuments)
        return result
    }

    static func assertRepackedOCRPreserved(_ fixture: OCRFixture, store: PaperStore,
                                           ids: [String], libraryBytes: Data,
                                           sealed: [String: [String: String]]) throws {
        let durable = try fixture.durable(), originals = Set(fixture.initial.managedDocuments.map(\.id))
        try require(try Data(contentsOf: fixture.disk.libraryURL) == libraryBytes, "fresh wrapper/reload rewrote durable business records or index metadata")
        try require(durable.managedDocuments.count == 6 && Set(store.managedDocuments.map(\.id)) == originals.union(ids),
                    "fresh wrapper/reload changed exact original+derived document identity set")
        try require(durable.managedDocuments.filter { originals.contains($0.id) } == fixture.initial.managedDocuments,
                    "fresh wrapper changed preexisting complete durable records")
        try require(try Data(contentsOf: fixture.originalURL) == fixture.originalBytes, "fresh wrapper altered original source bytes")
        try require(try sealedOCRState(fixture) == sealed, "fresh wrapper created/changed a job, snapshot, provenance, revision or attachment")
        let matches = store.documentLibrary.documents(in: fixture.source.folderID, search: "synthetic page-one text")
        try require(Set(matches.map(\.id)) == Set(ids), "fresh wrapper/reload lost actual indexed OCR search results")
        for id in ids {
            let document = try unwrap(durable.managedDocuments.first { $0.id == id }, "derived record absent after repack")
            let provenance = try unwrap(store.documentProvenance(for: id), "derived provenance absent after repack")
            let revision = try unwrap(store.documentRevision(for: id), "derived relation absent after repack")
            try require(document.contentIndexedAt != nil && (document.contentText ?? "").contains("synthetic page-one text"),
                        "fresh wrapper/reload lost durable page text/index timestamp")
            try require(provenance.targetRecordID == fixture.sourceID && provenance.pages.first?.text == "synthetic page-one text" &&
                        revision.originalDocumentID == fixture.sourceID && revision.kind == "ocrDerived",
                        "fresh wrapper/reload lost full source/page association")
        }
        try unchangedSentinels(fixture)
    }

    static func ocrResultRepack() async throws {
        try require(LibrarySchema.currentVersion == 32, "repack regression must use actual schema32")
        try await runAsync("fresh-random-paths-and-reload-share-one-job", category: "OCR result repack") { directory in
            let fixture = try ocrFixture(directory)
            let (request, firstReview) = try ocrReview(fixture)
            let first = try await fixture.store.documentLibrary.applyExchangeResult(firstReview, userApproved: true)
            try require(first.importedCount == 3 && first.duplicateCount == 0 && !first.replayed && Set(first.documentIDs).count == 3,
                        "first approved OCR did not import exactly3 unique derived IDs")
            let firstIntent = try unwrap(fixture.store.documentLibrary.exchangeClient.loadSession(request.requestID)
                .resultIntents?[firstReview.id], "first OCR semantic intent absent")
            let fingerprint = try unwrap(firstIntent.semanticFingerprintV2, "first OCR did not durably bind v2 semantic fingerprint")
            let jobID = try unwrap(UUID(uuidString: firstIntent.jobID), "first OCR invalid job UUID")
            let journal = try fixture.store.documentLibrary.transactionJournal()
            let job = try unwrap(journal.job(requestID: jobID), "first OCR durable job absent")
            try require(job.stage == .completed && job.recordsCommitted && job.items.map(\.documentID) == first.documentIDs,
                        "first3 business records are not bound to the completed original job")
            let raw = try Data(contentsOf: fixture.disk.libraryURL), sealed = try sealedOCRState(fixture)
            try assertRepackedOCRPreserved(fixture, store: fixture.store, ids: first.documentIDs, libraryBytes: raw, sealed: sealed)
            var seenResults = Set([firstReview.id]), seenNonces = Set([firstReview.result.package.manifest.nonce])
            var seenLifetimes = Set([firstReview.result.package.manifest.expiresAt])
            for round in 1...3 {
                let current = round == 3 ? PaperStore(repository: fixture.fault) : fixture.store
                try require(!current.libraryLoadFailed && current.managedDocuments.count == 6,
                            "real PaperStore reload failed or silently lost completed records")
                let review = try repackedOCRReview(fixture, template: firstReview, store: current, round: round)
                try require(seenResults.insert(review.id).inserted && seenNonces.insert(review.result.package.manifest.nonce).inserted &&
                            seenLifetimes.insert(review.result.package.manifest.expiresAt).inserted,
                            "each repeated normal Send must use a fresh transport envelope")
                let replay = try await current.documentLibrary.applyExchangeResult(review, userApproved: true)
                try require(replay.importedCount == 0 && replay.duplicateCount == 3 && replay.replayed && replay.documentIDs == first.documentIDs,
                            "fresh repack must return0 imports/3 duplicates/replayed and the original3 IDs")
                let session = try current.documentLibrary.exchangeClient.loadSession(request.requestID)
                let intent = try unwrap(session.resultIntents?[review.id], "fresh repack has no durable intent")
                let receipt = try unwrap(session.appliedResults?[review.id], "fresh repack has no applied receipt")
                try require(intent.jobID == firstIntent.jobID && intent.semanticFingerprintV2 == fingerprint,
                            "fresh repack changed semantic fingerprint or original job binding")
                try require(receipt.receiptID == firstIntent.jobID && receipt.importedDocumentIDs == first.documentIDs,
                            "fresh repack receipt silently names a new job or document set")
                try assertRepackedOCRPreserved(fixture, store: current, ids: first.documentIDs, libraryBytes: raw, sealed: sealed)
            }
        }
        try await runAsync("legacy-without-fingerprint-or-full-manifest-refuses", category: "OCR result repack") { directory in
            let fixture = try ocrFixture(directory)
            let (request, firstReview) = try ocrReview(fixture)
            let first = try await fixture.store.documentLibrary.applyExchangeResult(firstReview, userApproved: true)
            try require(first.importedCount == 3 && first.documentIDs.count == 3, "legacy seed did not actually commit3 records")
            let client = fixture.store.documentLibrary.exchangeClient
            var session = try client.loadSession(request.requestID)
            var binding = try unwrap(session.resultIntents?[firstReview.id], "legacy seed binding absent")
            binding.semanticFingerprintV2 = nil
            session.resultIntents?[firstReview.id] = binding
            // Historical sessions kept only this canonical manifest SHA, not
            // full original manifest bytes. Remove only the new optional fp.
            try GaoActionFileAccess.writePrivateData(JSONEncoder().encode(session),
                to: ResearchExchangePaths.root.appendingPathComponent("Sessions/" + request.requestID + ".json"))
            try require(try client.loadSession(request.requestID).resultIntents?[firstReview.id]?.semanticFingerprintV2 == nil,
                        "legacy fixture accidentally retained a v2 fingerprint")
            let review = try repackedOCRReview(fixture, template: firstReview, store: fixture.store, round: 4)
            let raw = try Data(contentsOf: fixture.disk.libraryURL), sealed = try sealedOCRState(fixture)
            var rejectedLegacy = false
            do { _ = try await fixture.store.documentLibrary.applyExchangeResult(review, userApproved: true) }
            catch ResearchDocumentImportError.legacyResultReviewRequired { rejectedLegacy = true }
            try require(rejectedLegacy, "unproven legacy fresh envelope was silently folded or imported")
            try require(try client.loadSession(request.requestID).appliedResults?[review.id] == nil &&
                        client.loadSession(request.requestID).resultIntents?[review.id] == nil,
                        "legacy refusal created a new intent/applied receipt")
            try assertRepackedOCRPreserved(fixture, store: fixture.store, ids: first.documentIDs, libraryBytes: raw, sealed: sealed)
        }
        try await runAsync("exact-legacy-envelope-repairs-receipt-without-promoting-fingerprint", category: "OCR result repack") { directory in
            let fixture = try ocrFixture(directory)
            let (request, review) = try ocrReview(fixture)
            let first = try await fixture.store.documentLibrary.applyExchangeResult(review, userApproved: true)
            let client = fixture.store.documentLibrary.exchangeClient
            var session = try client.loadSession(request.requestID)
            var binding = try unwrap(session.resultIntents?[review.id], "exact legacy seed intent absent")
            let semanticID = try unwrap(UUID(uuidString: binding.jobID), "exact legacy seed job invalid")
            let envelopeID = try unwrap(UUID(uuidString: review.id), "exact legacy result UUID invalid")
            let journal = try fixture.store.documentLibrary.transactionJournal()
            var legacyJob = try unwrap(journal.job(requestID: semanticID), "exact legacy seed full journal absent")
            try require(legacyJob.stage == .completed && legacyJob.recordsCommitted && first.documentIDs.count == 3,
                        "exact legacy fixture did not start with a real completed three-record plan")
            // Model the old envelope-ID journal shape using its full immutable
            // real completed plan. No fabricated attachment or provenance is
            // admitted, and the old semantic seed remains untouched.
            legacyJob.requestID = envelopeID
            let metadata = ResearchExchangePaths.root.appendingPathComponent("Metadata")
            try GaoActionFileAccess.writePrivateData(JSONEncoder().encode(legacyJob),
                to: metadata.appendingPathComponent("ImportJobs/" + envelopeID.uuidString.lowercased() + ".json"))
            let oldIndex = metadata.appendingPathComponent("ProcessedRequests/" + semanticID.uuidString.lowercased() + ".json")
            var processed = try JSONDecoder().decode(ProcessedRequest.self,
                from: GaoActionFileAccess.readPrivateData(at: oldIndex))
            processed.requestID = envelopeID
            try GaoActionFileAccess.writePrivateData(JSONEncoder().encode(processed),
                to: metadata.appendingPathComponent("ProcessedRequests/" + envelopeID.uuidString.lowercased() + ".json"))
            binding.jobID = envelopeID.uuidString; binding.semanticFingerprintV2 = nil
            session.resultIntents?[review.id] = binding
            session.appliedResults?.removeValue(forKey: review.id)
            try GaoActionFileAccess.writePrivateData(JSONEncoder().encode(session),
                to: ResearchExchangePaths.root.appendingPathComponent("Sessions/" + request.requestID + ".json"))
            let raw = try Data(contentsOf: fixture.disk.libraryURL), sealed = try sealedOCRState(fixture)
            let recovered = try await fixture.store.documentLibrary.applyExchangeResult(review, userApproved: true)
            try require(recovered.importedCount == 0 && recovered.duplicateCount == 3 && recovered.replayed &&
                        recovered.documentIDs == first.documentIDs,
                        "exact pre-semantic envelope did not repair only its original receipt")
            let restored = try client.loadSession(request.requestID)
            try require(restored.resultIntents?[review.id]?.jobID == envelopeID.uuidString &&
                        restored.resultIntents?[review.id]?.semanticFingerprintV2 == nil,
                        "exact legacy recovery promoted unproven intent into a V2 match")
            try require(restored.appliedResults?[review.id]?.receiptID == envelopeID.uuidString &&
                        restored.appliedResults?[review.id]?.importedDocumentIDs == first.documentIDs,
                        "exact legacy recovery receipt changed job or document IDs")
            try assertRepackedOCRPreserved(fixture, store: fixture.store, ids: first.documentIDs, libraryBytes: raw, sealed: sealed)
            let fresh = try repackedOCRReview(fixture, template: review, store: fixture.store, round: 6)
            var rejectedFresh = false
            do { _ = try await fixture.store.documentLibrary.applyExchangeResult(fresh, userApproved: true) }
            catch ResearchDocumentImportError.legacyResultReviewRequired { rejectedFresh = true }
            try require(rejectedFresh, "exact legacy receipt repair incorrectly authorized a different fresh wrapper")
            try require(try client.loadSession(request.requestID).appliedResults?[fresh.id] == nil,
                        "unknown fresh legacy wrapper acquired an applied receipt")
            try assertRepackedOCRPreserved(fixture, store: fixture.store, ids: first.documentIDs, libraryBytes: raw, sealed: sealed)
        }
        try await completedOCRReplayConflicts()
    }

    static func completedOCROrdering() async throws {
        try await runAsync("completed-replay-preserves-saved-and-manual-order", category: "Completed OCR ordering") { directory in
            let fixture = try ocrFixture(directory)
            let (request, firstReview) = try ocrReview(fixture)
            let first = try await fixture.store.documentLibrary.applyExchangeResult(firstReview, userApproved: true)
            try require(first.importedCount == 3 && first.documentIDs.count == 3, "ordering seed did not commit three OCR derivatives")
            let binding = try unwrap(fixture.store.documentLibrary.exchangeClient.loadSession(request.requestID)
                .resultIntents?[firstReview.id], "ordering seed intent absent")
            let jobID = try unwrap(UUID(uuidString: binding.jobID), "ordering seed job UUID invalid")
            let job = try unwrap(fixture.store.documentLibrary.transactionJournal().job(requestID: jobID), "ordering seed job absent")
            for item in job.items {
                try require(try DocumentLibraryStore.decodeImportRecord(item.recordData).document.sortOrder == nil,
                            "ordering regression must start from actual nil-order frozen OCR records")
            }
            let beforeLoad = try Data(contentsOf: fixture.disk.libraryURL), beforeDocuments = try fixture.durable().managedDocuments
            let current = PaperStore(repository: fixture.fault)
            try require(!current.libraryLoadFailed && Data(contentsOf: fixture.disk.libraryURL) == beforeLoad,
                        "normal load unexpectedly wrote normalized order to disk")
            try require(current.managedDocuments.filter { first.documentIDs.contains($0.id) }.allSatisfy { $0.sortOrder != nil }
                        && beforeDocuments.filter { first.documentIDs.contains($0.id) }.allSatisfy { $0.sortOrder == nil },
                        "load did not create the real memory-nonnil/durable-nil ordering split")
            // An unrelated normal save (including a choose import) persists
            // the whole load-normalized collection through this same API.
            try current.saveThrowing()
            let saved = try fixture.durable().managedDocuments
            try require(saved.filter { first.documentIDs.contains($0.id) }.allSatisfy { $0.sortOrder != nil },
                        "normal save did not persist normalized OCR order")
            for previous in beforeDocuments {
                var before = previous
                var after = try unwrap(saved.first { $0.id == previous.id }, "normal save lost a preexisting record")
                before.sortOrder = nil; after.sortOrder = nil
                try require(before == after, "normal save changed a field besides display order")
            }
            @MainActor func replayPreservingCurrentState(_ review: PendingExchangeResultReview, _ phase: String) async throws {
                let raw = try Data(contentsOf: fixture.disk.libraryURL), memory = current.managedDocuments
                let sealed = try sealedOCRState(fixture)
                let replay: ResearchImportJournal.Outcome
                do { replay = try await current.documentLibrary.applyExchangeResult(review, userApproved: true) }
                catch { throw Failure(description: "completed OCR \(phase) replay rejected legal display order: \(error)") }
                try require(replay.importedCount == 0 && replay.duplicateCount == 3 && replay.replayed
                            && replay.documentIDs == first.documentIDs, "ordered completed replay changed job outcome or document IDs")
                let session = try current.documentLibrary.exchangeClient.loadSession(request.requestID)
                try require(session.resultIntents?[review.id]?.jobID == binding.jobID
                            && session.appliedResults?[review.id]?.receiptID == binding.jobID,
                            "ordered completed replay rebound the original job")
                try require(try Data(contentsOf: fixture.disk.libraryURL) == raw && current.managedDocuments == memory,
                            "completed replay rewrote the current library, display order or in-memory records")
                try require(try sealedOCRState(fixture) == sealed,
                            "completed replay changed a job, snapshot, file, provenance, revision or processed index")
                try require(Set(current.managedDocuments.map(\.id)) == Set(beforeDocuments.map(\.id)),
                            "completed replay added or removed a document ID")
                try require(Set(current.documentLibrary.documents(in: fixture.source.folderID, search: "synthetic page-one text").map(\.id))
                            == Set(first.documentIDs), "ordered replay lost actual indexed OCR search results")
                try require(try Data(contentsOf: fixture.originalURL) == fixture.originalBytes, "ordered replay changed the source bytes")
                try unchangedSentinels(fixture)
            }
            let savedReview = try repackedOCRReview(fixture, template: firstReview, store: current, round: 7)
            try await replayPreservingCurrentState(savedReview, "after-load-and-normal-save")
            let beforeManual = try fixture.durable().managedDocuments
            let ordered = current.managedDocuments.filter { first.documentIDs.contains($0.id) }
                .sorted { ($0.sortOrder ?? -1) < ($1.sortOrder ?? -1) }
            let moving = try unwrap(ordered.last, "manual order source absent"), target = try unwrap(ordered.first, "manual order target absent")
            let saves = fixture.fault.saves
            current.moveManagedDocument(sourceID: moving.id, before: target.id)
            let manual = try fixture.durable().managedDocuments
            let moved = try unwrap(manual.first { $0.id == moving.id }?.sortOrder, "manual source order missing")
            let targetOrder = try unwrap(manual.first { $0.id == target.id }?.sortOrder, "manual target order missing")
            try require(fixture.fault.saves > saves && moved < targetOrder && manual != beforeManual,
                        "production drag-sort did not durably change the display order")
            for previous in beforeManual {
                var before = previous
                var after = try unwrap(manual.first { $0.id == previous.id }, "manual sort lost a record")
                before.sortOrder = nil; after.sortOrder = nil
                try require(before == after, "production drag-sort changed a field besides order")
            }
            let manualReview = try repackedOCRReview(fixture, template: firstReview, store: current, round: 8)
            try await replayPreservingCurrentState(manualReview, "after-manual-sort")
            try await replayPreservingCurrentState(firstReview, "exact-applied-envelope-after-manual-sort")
        }
        try await completedOCRReplayConflicts()
    }

    static func completedOCRReplayConflicts() async throws {
        for mutation in ["derived-file", "derived-metadata", "indexed-text-with-date"] {
            try await runAsync("completed-replay-refuses-" + mutation, category: "OCR result repack") { directory in
                let fixture = try ocrFixture(directory)
                let (request, firstReview) = try ocrReview(fixture)
                let first = try await fixture.store.documentLibrary.applyExchangeResult(firstReview, userApproved: true)
                let id = try unwrap(first.documentIDs.first, "completed replay negative seed has no derived IDs")
                let document = try unwrap(fixture.store.managedDocuments.first { $0.id == id }, "completed replay negative seed record absent")
                if mutation == "derived-file" {
                    try write(Data("legitimate externally changed derived bytes".utf8), fixture.store.managedDocumentURL(document))
                } else if mutation == "derived-metadata" {
                    let index = try unwrap(fixture.store.managedDocuments.firstIndex { $0.id == id }, "derived metadata edit target absent")
                    fixture.store.managedDocuments[index].displayName = "Explicit user-edited derived title"
                    try fixture.store.saveThrowing()
                } else {
                    let index = try unwrap(fixture.store.managedDocuments.firstIndex { $0.id == id }, "derived index edit target absent")
                    try require(fixture.store.managedDocuments[index].contentIndexedAt != nil,
                                "index corruption fixture must retain an actual nonnil index timestamp")
                    fixture.store.managedDocuments[index].contentText = "Damaged stale index text with a surviving timestamp"
                    try fixture.store.saveThrowing()
                }
                let review = try repackedOCRReview(fixture, template: firstReview, store: fixture.store, round: 5)
                let raw = try Data(contentsOf: fixture.disk.libraryURL), sealed = try sealedOCRState(fixture)
                var conflicted = false
                do { _ = try await fixture.store.documentLibrary.applyExchangeResult(review, userApproved: true) }
                catch ResearchDocumentImportError.versionConflict { conflicted = true }
                try require(conflicted, "completed replay ignored a changed derived file/record and forged success")
                try require(try Data(contentsOf: fixture.disk.libraryURL) == raw && sealedOCRState(fixture) == sealed,
                            "completed replay conflict overwrote changed data or created a new job/snapshot/attachment")
                try require(fixture.store.managedDocuments.count == 6 && Data(contentsOf: fixture.originalURL) == fixture.originalBytes,
                            "completed replay conflict changed original source or document cardinality")
                try require(try fixture.store.documentLibrary.exchangeClient.loadSession(request.requestID).appliedResults?[review.id] == nil,
                            "completed replay conflict acquired an applied receipt")
                try unchangedSentinels(fixture)
            }
        }
    }

    static func ocrRevisionOrdering() async throws {
        try require(LibrarySchema.currentVersion == 32, "regression must start from actual schema 32")
        try await runAsync("raw-nil-retained-plan-save-failure-retry") { directory in
            let fixture = try ocrFixture(directory), store = fixture.store
            let (request, review) = try ocrReview(fixture)
            let initialRaw = try Data(contentsOf: fixture.disk.libraryURL)
            let initialMemory = store.managedDocuments
            var interrupt = true, beforeIndex = false, afterIndex = false, beforeCompleted = false
            store.documentLibrary.importFailureInjector = { point in
                try noAppliedReceipt(fixture, request, review)
                if point == .beforeDatabaseCommit && interrupt { interrupt = false; throw ResearchImportJournal.SimulatedCrash() }
                if point == .beforeIndex {
                    beforeIndex = true
                    let durable = try fixture.durable()
                    try require(durable.managedDocuments.count == 6, "index started before whole batch was durable")
                }
                if point == .afterIndex {
                    afterIndex = true
                    let durable = try fixture.durable()
                    try require(durable.managedDocuments.filter { !Set(fixture.initial.managedDocuments.map(\.id)).contains($0.id) }
                        .allSatisfy { $0.contentIndexedAt != nil && ($0.contentText ?? "").contains("synthetic page-one text") },
                        "afterIndex did not retain durable page text/index metadata")
                }
                if point == .beforeCompleted { beforeCompleted = true }
            }
            try await mustReject("injected retained-plan interruption did not stop approval") {
                _ = try await store.documentLibrary.applyExchangeResult(review, userApproved: true)
            }
            let journal = try store.documentLibrary.transactionJournal()
            let intent = try unwrap(store.documentLibrary.exchangeClient.loadSession(request.requestID).resultIntents?[review.id], "frozen intent absent")
            let jobID = try unwrap(UUID(uuidString: intent.jobID), "invalid frozen job ID")
            let frozen = try unwrap(journal.job(requestID: jobID), "retained journal absent")
            try require(frozen.stage == .database && !frozen.recordsCommitted && frozen.items.count == 3,
                        "interruption did not retain its immutable database-stage plan")
            let frozenIDs = frozen.items.map(\.documentID)
            try require(Set(frozenIDs).count == 3 && frozen.items.allSatisfy { $0.effectiveOperation == .revision && $0.revision?.kind == "ocrDerived" },
                        "fixture did not use normal new-ID OCR revisions")
            for item in frozen.items {
                let original = try DocumentLibraryStore.decodeImportRecord(unwrap(item.originalRecordData, "frozen original envelope absent")).document
                try require(original.id == fixture.sourceID && original.sortOrder == 1, "failed-plan original was not actual load-normalized memory")
            }
            try require(try fixture.durable().managedDocuments[0].sortOrder == nil && Data(contentsOf: fixture.disk.libraryURL) == initialRaw,
                        "interruption changed raw nil source ordering")
            try require(store.managedDocuments == initialMemory, "interruption mutated store document memory")
            try noAppliedReceipt(fixture, request, review)
            fixture.fault.failures = 1
            try await mustReject("injected atomic batch-save failure did not abort") {
                _ = try await store.documentLibrary.applyExchangeResult(review, userApproved: true)
            }
            try require(fixture.fault.failures == 0 && store.managedDocuments == initialMemory,
                        "failed whole-batch save did not roll back all new document memory")
            try require(try Data(contentsOf: fixture.disk.libraryURL) == initialRaw, "failed save changed durable original metadata")
            let failed = try unwrap(journal.job(requestID: jobID), "failed plan vanished")
            try require(!failed.recordsCommitted && failed.items.map(\.documentID) == frozenIDs,
                        "failed save rewrote/partially committed the three-ID plan")
            for item in failed.items {
                try require(!FileManager.default.fileExists(atPath: LibraryPaths.managedDocuments.appendingPathComponent(item.destinationRelativePath).path),
                            "uncommitted new attachment was not compensated after save failure")
            }
            try noAppliedReceipt(fixture, request, review)
            let outcome = try await store.documentLibrary.applyExchangeResult(review, userApproved: true)
            try require(outcome.importedCount == 3 && outcome.documentIDs == frozenIDs && store.managedDocuments.count == 6,
                        "same journal retry failed to commit exactly its original three IDs")
            let completed = try unwrap(journal.job(requestID: jobID), "completed journal missing")
            try require(beforeIndex && afterIndex && beforeCompleted && completed.stage == .completed && completed.recordsCommitted,
                        "successful approval did not reach actual durable/index/completed checkpoints")
            let durable = try fixture.durable(), oldIDs = Set(fixture.initial.managedDocuments.map(\.id))
            try require(durable.managedDocuments.filter { oldIDs.contains($0.id) } == fixture.initial.managedDocuments,
                        "OCR append changed complete preexisting durable records, raw nil order or array order")
            try require(try Data(contentsOf: fixture.originalURL) == fixture.originalBytes, "OCR changed source bytes")
            try unchangedSentinels(fixture)
            for document in durable.managedDocuments where !oldIDs.contains(document.id) {
                let relation = try unwrap(store.documentRevision(for: document.id), "completed derivative relation absent")
                let provenance = try unwrap(store.documentProvenance(for: document.id), "completed derivative provenance absent")
                try require(relation.originalDocumentID == fixture.sourceID && relation.kind == "ocrDerived" && provenance.pages.first?.text == "synthetic page-one text",
                            "completed derivative lost original/page association")
            }
            let receipt = try unwrap(store.documentLibrary.exchangeClient.loadSession(request.requestID).appliedResults?[review.id], "completed applied receipt absent")
            try require(receipt.importedDocumentIDs == frozenIDs && receipt.receiptID == jobID.uuidString,
                        "business receipt does not name the completed frozen batch")
            let replay = try await store.documentLibrary.applyExchangeResult(review, userApproved: true)
            try require(replay.replayed && replay.documentIDs == frozenIDs && store.managedDocuments.count == 6,
                        "exact OCR retry duplicated derived records")
        }
        for mutation in ["tags-durable-only", "displayName", "updatedAt", "scope", "stored-path", "source-content", "relative-order"] {
            try await runAsync("refuse-" + mutation) { directory in
                let fixture = try ocrFixture(directory), store = fixture.store
                let (request, review) = try ocrReview(fixture)
                var injected = false, changedRaw: Data?, changedBytes: Data?
                store.documentLibrary.importFailureInjector = { point in
                    guard point == .beforeDatabaseCommit && !injected else { return }
                    injected = true
                    let sourceIndex = try unwrap(store.managedDocuments.firstIndex { $0.id == fixture.sourceID }, "source memory missing")
                    switch mutation {
                    case "tags-durable-only":
                        var durable = try fixture.durable()
                        durable.managedDocuments[0].tags = ["external durable tag"]
                        try write(encode(durable), fixture.disk.libraryURL)
                    case "displayName": store.managedDocuments[sourceIndex].displayName = "Concurrent display edit"; try store.saveThrowing()
                    case "updatedAt": store.managedDocuments[sourceIndex].updatedAt = stamp.addingTimeInterval(60); try store.saveThrowing()
                    case "scope":
                        store.managedDocuments[sourceIndex].folderID = fixture.initial.documentFolders[1].id
                        try write(fixture.originalBytes, store.managedDocumentURL(store.managedDocuments[sourceIndex]))
                        try store.saveThrowing()
                    case "stored-path":
                        store.managedDocuments[sourceIndex].storedName = "concurrent-path.png"
                        try write(fixture.originalBytes, store.managedDocumentURL(store.managedDocuments[sourceIndex]))
                        try store.saveThrowing()
                    case "source-content":
                        var bytes = fixture.originalBytes; bytes[bytes.count - 1] ^= 1
                        try write(bytes, fixture.originalURL); changedBytes = bytes
                    case "relative-order":
                        let siblingIndex = try unwrap(store.managedDocuments.firstIndex { $0.id == fixture.siblingID }, "sibling missing")
                        store.managedDocuments[siblingIndex].sortOrder = 2 // Source still exactly captured order 1, but now first.
                        try store.saveThrowing()
                    default: throw Failure(description: "unknown mutation")
                    }
                    changedRaw = try Data(contentsOf: fixture.disk.libraryURL)
                    try noAppliedReceipt(fixture, request, review)
                }
                try await mustReject("concurrent \(mutation) was accepted by OCR nil-order exception") {
                    _ = try await store.documentLibrary.applyExchangeResult(review, userApproved: true)
                }
                try require(injected && changedRaw != nil, "concurrent mutation did not reach real beforeDatabaseCommit checkpoint")
                try require(try Data(contentsOf: fixture.disk.libraryURL) == changedRaw, "refusal overwrote concurrent durable state")
                try require(try fixture.durable().managedDocuments.count == 3 && store.managedDocuments.count == 3,
                            "conflict partially appended derived records")
                try require(try Data(contentsOf: fixture.originalURL) == (changedBytes ?? fixture.originalBytes), "refusal altered concurrent/original source bytes")
                try noAppliedReceipt(fixture, request, review)
                let intent = try unwrap(store.documentLibrary.exchangeClient.loadSession(request.requestID).resultIntents?[review.id], "conflict plan missing")
                let job = try unwrap(store.documentLibrary.transactionJournal().job(requestID: unwrap(UUID(uuidString: intent.jobID), "invalid job UUID")), "conflict journal missing")
                try require(!job.recordsCommitted && job.items.count == 3, "conflict forged committed journal")
                for item in job.items {
                    try require(!FileManager.default.fileExists(atPath: LibraryPaths.managedDocuments.appendingPathComponent(item.destinationRelativePath).path),
                                "conflict retained an uncommitted final derived attachment")
                }
                try unchangedSentinels(fixture)
            }
        }
        for newVersion in [true, false] {
            try await runAsync(newVersion ? "manual-update-remains-strict" : "non-ocr-revision-remains-strict") { directory in
                let fixture = try ocrFixture(directory), store = fixture.store
                let request = try fixtureRequest(fixture, action: .openDocument)
                let edited = directory.appendingPathComponent("manual-edited.txt")
                try write(Data("explicit manual edited copy".utf8), edited)
                let initialRaw = try Data(contentsOf: fixture.disk.libraryURL)
                var reachedDatabaseAdapter = false
                store.documentLibrary.importFailureInjector = { point in
                    if point == .beforeDatabaseCommit { reachedDatabaseAdapter = true }
                }
                try await mustReject("non-OCR operation incorrectly inherited nil-order relaxation") {
                    try await store.importEditedDocumentCopy(for: fixture.source, from: edited, asNewVersion: newVersion)
                }
                try require(try Data(contentsOf: fixture.disk.libraryURL) == initialRaw && fixture.durable().managedDocuments.count == 3,
                            "strict non-OCR refusal changed original durable records")
                try require(store.managedDocuments.count == 3 && Data(contentsOf: fixture.originalURL) == fixture.originalBytes,
                            "strict non-OCR refusal changed source bytes or document cardinality")
                try require(try store.documentLibrary.exchangeClient.loadSession(request.requestID).importedEditedSHA256 == nil,
                            "non-OCR rejection forged edited-copy imported receipt")
                let operation: ResearchImportJournal.Operation = newVersion ? .update : .revision
                let job = try unwrap(store.documentLibrary.transactionJournal().recentJobs(limit: Int.max).first { job in
                    job.items.count == 1 && job.items[0].expectedOriginal?.documentID == fixture.sourceID
                }, "non-OCR fixture failed before creating its normal strict-CAS journal")
                try require(reachedDatabaseAdapter && job.items[0].effectiveOperation == operation && job.validationCompleted && !job.recordsCommitted
                            && job.stage == .failed && job.errorCode == "operationFailed" && job.resumeStage == .commitJournal,
                            "non-OCR refusal did not reach the strict production database adapter")
                try unchangedSentinels(fixture)
            }
        }
    }

    static func main() async throws {
        guard let path = ProcessInfo.processInfo.environment["GAO_LIBRARY_LOAD_TEST_ROOT"],
              ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"] != nil,
              ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1" else {
            throw Failure(description: "isolated test environment is required")
        }
        root = URL(fileURLWithPath: path, isDirectory: true)
        try require(root.path.hasPrefix("/private/tmp/"), "fixture root must be private tmp")
        defer { try? FileManager.default.removeItem(at: root) }
        try require(LibraryPaths.legacyApplicationSupport.path.hasPrefix(root.deletingLastPathComponent().path), "test hook escaped into real legacy storage")

        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments == ["--case", "ocr-revision-ordering"] {
            try await ocrRevisionOrdering()
            print("OCR revision ordering: \(passed) isolated groups, \(assertions) assertions passed; no GUI, live data or real preferences were used.")
            return
        }
        if arguments == ["--case", "ocr-result-repack"] {
            try await ocrResultRepack()
            print("OCR result repack: \(passed) isolated groups, \(assertions) assertions passed; no GUI, live data or real preferences were used.")
            return
        }
        if arguments == ["--case", "completed-ocr-ordering"] {
            try await completedOCROrdering()
            print("Completed OCR ordering: \(passed) isolated groups, \(assertions) assertions passed; no GUI, live data or real preferences were used.")
            return
        }
        try require(arguments.isEmpty, "unknown focused test case")

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
