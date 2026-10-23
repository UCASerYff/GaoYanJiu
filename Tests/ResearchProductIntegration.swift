import AppKit
import Foundation
import CryptoKit
import PDFKit
import Darwin

#if !RESEARCH_PRODUCT_INTEGRATION
#error("Use scripts/test_product.sh: this test requires isolated data and in-memory defaults.")
#endif

/// Test-only isolation of preferences. All persistence/import/index adapters below
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
struct ResearchProductIntegration {
    struct Failure: Error, CustomStringConvertible { let description: String }
    enum Injected: Error { case database, checkpoint }

    /// The only substituted behavior is one explicitly requested write failure;
    /// successful reads/writes always run through the production disk repository.
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
            if failNextSave { failNextSave = false; throw Injected.database }
            try disk.saveLibrary(library)
        }
    }
    static var root: URL!
    static func require(_ value: @autoclosure () throws -> Bool, _ description: String) throws {
        guard try value() else { throw Failure(description: description) }
    }
    static func unwrap<T>(_ value: T?, _ description: String) throws -> T {
        guard let value else { throw Failure(description: description) }; return value
    }
    static func rejects(_ description: String, _ operation: () async throws -> Void) async throws {
        do { try await operation() } catch { return }
        throw Failure(description: description)
    }
    static func source(_ name: String, text: String) throws -> URL {
        let url = root.appendingPathComponent("Inputs", isDirectory: true).appendingPathComponent(name)
        try GaoActionFileAccess.writePrivateData(Data(text.utf8), to: url)
        return url
    }
    static func makeStore() throws -> (PaperStore, FaultingDiskRepository) {
        let repository = FaultingDiskRepository()
        // This seed is essential: absent library.json would legitimately trigger
        // the production legacy PaperSignal migration on the user's computer.
        try repository.disk.initializeNewLibraryAfterUserConfirmation()
        try repository.disk.saveLibrary(PersistedLibrary(version: LibrarySchema.currentVersion))
        let store = PaperStore(repository: repository)
        try require(!store.libraryLoadFailed, "Isolated disk library did not load")
        try require(store.managedDocuments.isEmpty && store.documentFolders.isEmpty, "Fixture did not start empty")
        return (store, repository)
    }
    static func folder(_ store: PaperStore) throws -> DocumentFolder {
        let id = try unwrap(store.createDocumentFolder(kind: .importantLiterature, name: "Product integration fixture"), "Cannot create fixture folder")
        return try unwrap(store.documentFolders.first(where: { $0.id == id }), "Fixture folder missing")
    }
    static func importOriginal(_ store: PaperStore, folder: DocumentFolder, text: String = "original scientific fixture") async throws -> ManagedDocument {
        let url = try source("original.txt", text: text)
        let count = try await store.importDocuments(from: [url], into: folder.id)
        try require(count == 1, "Original import did not commit exactly one document")
        return try unwrap(store.managedDocuments.first(where: { $0.folderID == folder.id }), "Original document missing")
    }
    static func durable(_ store: PaperStore) throws -> PersistedLibrary {
        let repository = DiskLibraryRepository()
        let data = try GaoActionFileAccess.readPrivateData(at: repository.libraryURL, maximumBytes: 16 * 1_048_576)
        let saved = try repository.decoder.decode(PersistedLibrary.self, from: data)
        try require(Set(saved.managedDocuments.map(\.id)).count == saved.managedDocuments.count, "Durable duplicate document IDs")
        try require(saved.managedDocuments.map(\.id).sorted() == store.managedDocuments.map(\.id).sorted(), "Memory and disk document IDs diverged")
        for document in saved.managedDocuments {
            let fingerprint = try GaoActionFileAccess.fingerprint(at: store.managedDocumentURL(document))
            try require(fingerprint.byteCount == document.byteCount, "Managed attachment byte count differs from record")
        }
        return saved
    }
    static func freshImport() async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        let first = try source("one.txt", text: "first experiment fixture needle-alpha")
        let second = try source("two.txt", text: "second experiment fixture needle-beta")
        let imported = try await store.importDocuments(from: [first, second], into: target.id)
        try require(imported == 2, "Batch import count incorrect")
        try require(store.managedDocuments.count == 2, "Batch records missing")
        for document in store.managedDocuments {
            try require(document.contentIndexedAt != nil && !(document.contentText ?? "").isEmpty, "Product text extraction/index not persisted")
            try require(store.documentProvenance(for: document.id) != nil, "Product provenance missing")
        }
        try require(store.documents(in: target.id, search: "needle-alpha").count == 1, "Existing library full-text search did not find imported document")
        _ = try durable(store)
    }
    static func newAttachment() async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        let original = try await importOriginal(store, folder: target)
        let originalURL = store.managedDocumentURL(original)
        let originalSHA = try GaoActionFileAccess.fingerprint(at: originalURL).sha256
        _ = try store.documentLibrary.exchangeClient.prepareExternalEdit(documentID: original.id, originalURL: originalURL, originalVersion: original.updatedAt)
        let edited = try source("edited.txt", text: "original scientific fixture") // Same bytes must still allow explicit new attachment.
        try await store.importEditedDocumentCopy(for: original, from: edited, asNewVersion: false)
        try require(store.managedDocuments.count == 2, "Explicit new attachment was deduplicated or added twice")
        try require(Set(store.managedDocuments.map(\.id)).count == 2, "New attachment created a duplicate ID")
        try require(try GaoActionFileAccess.fingerprint(at: originalURL).sha256 == originalSHA, "New attachment changed original bytes")
        let added = try unwrap(store.managedDocuments.first(where: { $0.id != original.id }), "New attachment record absent")
        try require(added.storedName != original.storedName, "New attachment reused original managed path")
        let relation = try unwrap(store.documentRevision(for: added.id), "New attachment relation missing")
        try require(relation.originalDocumentID == original.id, "New attachment relation points to wrong original")
        _ = try durable(store)
        let ids = store.managedDocuments.map(\.id).sorted()
        // Retrying the same completed edit session may return no-op or a clear
        // already-imported rejection; either way it must have no second side effect.
        do { try await store.importEditedDocumentCopy(for: original, from: edited, asNewVersion: false) } catch {}
        try require(store.managedDocuments.map(\.id).sorted() == ids, "Edited-copy retry repeated side effects")
    }
    static func newVersion() async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        let original = try await importOriginal(store, folder: target)
        let originalURL = store.managedDocumentURL(original)
        let originalSHA = try GaoActionFileAccess.fingerprint(at: originalURL).sha256
        _ = try store.documentLibrary.exchangeClient.prepareExternalEdit(documentID: original.id, originalURL: originalURL, originalVersion: original.updatedAt)
        let edited = try source("new-version.txt", text: "revised scientific fixture replacement-needle")
        try await store.importEditedDocumentCopy(for: original, from: edited, asNewVersion: true)
        let updated = try unwrap(store.managedDocuments.first(where: { $0.id == original.id }), "Updated record absent")
        try require(store.managedDocuments.count == 1, "New version changed document cardinality")
        try require(updated.storedName != original.storedName, "New version reused original attachment path")
        try require(try GaoActionFileAccess.fingerprint(at: originalURL).sha256 == originalSHA, "Old managed version was not preserved")
        try require(updated.contentText?.contains("replacement-needle") == true, "New version index was overwritten with stale record state")
        try require(store.documentRevision(for: original.id)?.originalSHA256 == originalSHA, "Revision lacks prior digest")
        let snapshotRoot = ResearchExchangePaths.root.appendingPathComponent("Snapshots")
        let snapshots = (FileManager.default.enumerator(at: snapshotRoot, includingPropertiesForKeys: nil)?.allObjects as? [URL]) ?? []
        let oldCopy = try unwrap(snapshots.first(where: { $0.pathExtension == "data" }), "Private old attachment snapshot missing")
        try require(try GaoActionFileAccess.fingerprint(at: oldCopy).sha256 == originalSHA, "Private old attachment snapshot hash mismatch")
        let oldRecordURL = oldCopy.deletingPathExtension().appendingPathExtension("record.json")
        let oldRecord = try JSONSerialization.jsonObject(with: GaoActionFileAccess.readPrivateData(at: oldRecordURL)) as? [String: Any]
        try require((oldRecord?["document"] as? [String: Any])?["storedName"] as? String == original.storedName, "Private original record snapshot missing")
        for url in [oldCopy, oldRecordURL] {
            let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            try require(mode?.intValue == 0o600, "Old attachment/record snapshot not private")
        }
        _ = try durable(store)
    }
    static func repeatedRequest() async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        let file = try source("request.txt", text: "stable retry fixture")
        let item = GaoActionItem(id: "input", relativePath: "payload/input.txt", uti: "public.utf8-plain-text", byteCount: 0, sha256: String(repeating: "0", count: 64))
        let manifest = GaoActionManifest(sourceBundleID: ResearchExchangePaths.bundleID, targetBundleID: ResearchExchangePaths.bundleID, action: "research.importDocuments", items: [item])
        let packageURL = try GaoActionPackageWriter().write(manifest: manifest, files: [item.id: file], outgoingRoot: root.appendingPathComponent("Sender"))
        let package = try GaoActionPackageValidator(expectedTargetBundleID: ResearchExchangePaths.bundleID).stagePackage(at: packageURL, stagingRoot: root.appendingPathComponent("Incoming"))
        let first = try await store.documentLibrary.importStagedDocuments(package, into: target)
        let retry = try await store.documentLibrary.importStagedDocuments(package, into: target)
        try require(first.documentIDs == retry.documentIDs && retry.replayed, "Same request did not replay durable original outcome")
        try require(store.managedDocuments.count == 1, "Same request added duplicate records")
        _ = try durable(store)
    }
    static func incomingContext(_ store: PaperStore, id: String = UUID().uuidString,
                                text: String = "public incoming fixture", parameters: [String: GaoJSONValue] = [:],
                                uppercaseSHA: Bool = false) throws -> PendingPackageReviewContext {
        let file = try source(UUID().uuidString + ".txt", text: text)
        let item = GaoActionItem(id: "incoming-source", relativePath: "payload/source.txt", uti: "public.utf8-plain-text", byteCount: 0, sha256: String(repeating: "0", count: 64))
        let request = GaoActionManifest(requestID: id, sourceBundleID: "com.gaoseries.GaoWenJian",
                                        targetBundleID: ResearchExchangePaths.bundleID, action: "research.importDocuments",
                                        items: [item], parameters: parameters)
        let packageURL = try GaoActionPackageWriter().write(manifest: request, files: [item.id: file],
                                                            outgoingRoot: root.appendingPathComponent("Sender-" + UUID().uuidString))
        if uppercaseSHA {
            let manifestURL = packageURL.appendingPathComponent("manifest.json")
            var manifest = try JSONDecoder().decode(GaoActionManifest.self, from: GaoActionFileAccess.readPrivateData(at: manifestURL))
            manifest.items[0].sha256 = manifest.items[0].sha256.uppercased()
            try GaoActionFileAccess.writePrivateData(JSONEncoder().encode(manifest), to: manifestURL)
        }
        let raw = try GaoActionFileAccess.readPrivateData(at: packageURL.appendingPathComponent("manifest.json"))
        let package = try GaoActionPackageValidator(expectedTargetBundleID: ResearchExchangePaths.bundleID)
            .stagePackage(at: packageURL, stagingRoot: root.appendingPathComponent("Incoming"))
        try require(package.manifestSHA256 == SHA256.hash(data: raw).map { String(format: "%02x", $0) }.joined(), "Receiver manifest digest is not exact validated bytes")
        return .init(packageURL: packageURL, validatedPackage: package, targetFolderID: "")
    }
    static func incomingHandoff() async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        let context = try incomingContext(store, uppercaseSHA: true)
        try await rejects("Unapproved incoming request changed library") {
            _ = try await store.documentLibrary.approveIncomingDocuments(context, targetFolderID: target.id, userApproved: false)
        }
        try require(store.managedDocuments.isEmpty, "Unapproved request created records")
        store.handleIncomingPackage(at: context.packageURL)
        let pendingID = store.pendingPackageReview?.id
        let other = try incomingContext(store)
        store.handleIncomingPackage(at: other.packageURL)
        try require(store.pendingPackageReview?.id == pendingID, "Second incoming request displaced current review")
        let receipt = try await store.documentLibrary.approveIncomingDocuments(context, targetFolderID: target.id, userApproved: true)
        try require(receipt.state == "completed" && store.managedDocuments.count == 1, "Approved incoming request not committed")
        try require(store.managedDocuments.first?.contentIndexedAt != nil, "Completed receipt preceded indexing")
        let again = try await store.documentLibrary.approveIncomingDocuments(context, targetFolderID: target.id, userApproved: true)
        try require(again.outcome == receipt.outcome && store.managedDocuments.count == 1, "Incoming replay imported twice")
        try require(try store.documentLibrary.cancelIncomingDocuments(context).state == "completed", "Cancellation replaced completed outcome")
        let otherFolder = try unwrap(store.createDocumentFolder(kind: .importantLiterature, name: "Second incoming target"), "Second folder missing")
        try await rejects("Same incoming UUID changed bound target") {
            _ = try await store.documentLibrary.approveIncomingDocuments(context, targetFolderID: otherFolder, userApproved: true)
        }
        let changed = try incomingContext(store, id: receipt.id, text: "changed sender content")
        try await rejects("Changed manifest reused incoming UUID") {
            _ = try await store.documentLibrary.approveIncomingDocuments(changed, targetFolderID: target.id, userApproved: true)
        }
        let resultURL = try store.documentLibrary.prepareIncomingResult(requestID: receipt.id)
        let result = try GaoActionPackageValidator(expectedTargetBundleID: "com.gaoseries.GaoWenJian")
            .stagePackage(at: resultURL, stagingRoot: root.appendingPathComponent("SenderResultReview"))
        try require(result.manifest.status == "completed" && result.manifest.inReplyTo == receipt.id &&
                    result.manifest.items.isEmpty && result.manifest.references.isEmpty && result.manifest.parameters.isEmpty &&
                    result.manifest.errorCode == nil, "Result manifest is not a minimal attachment-free business receipt")
        let provenance = try unwrap(result.manifest.provenance, "Result provenance missing")
        try require(provenance["requestManifestSHA256"] == .string(context.validatedPackage.manifestSHA256) &&
                    provenance["workflowState"] == .string("imported"), "Result not bound to validated request bytes")
        try require(provenance["sources"] == .array([.object(["sourceItemID": .string("incoming-source"),
                    "sourceSHA256": .string(context.validatedPackage.manifest.items[0].sha256), "status": .string("imported")])]), "Result source bindings missing")
        let resultData = try GaoActionFileAccess.readPrivateData(at: resultURL.appendingPathComponent("manifest.json"))
        try require(!String(decoding: resultData, as: UTF8.self).contains(root.path), "Outgoing receipt leaked private fixture paths")
        let secondResult = try store.documentLibrary.prepareIncomingResult(requestID: receipt.id)
        try require(secondResult != resultURL && store.managedDocuments.count == 1, "Resending receipt repeated business import")
        let cancelledContext = try incomingContext(store)
        let closed = try store.documentLibrary.incomingHandoffs.register(cancelledContext.validatedPackage)
        try require(closed.state == "pending", "Closing an unapproved request was treated as cancellation")
        let cancelled = try store.documentLibrary.cancelIncomingReceipt(requestID: closed.id)
        try require(cancelled.state == "cancelled", "Explicit refusal did not persist cancelled")
        try require(try store.documentLibrary.cancelIncomingDocuments(cancelledContext).state == "cancelled", "Cancel replay changed terminal decision")
        let refusedImport = try await store.documentLibrary.approveIncomingDocuments(cancelledContext, targetFolderID: target.id, userApproved: true)
        try require(refusedImport.state == "cancelled" && store.managedDocuments.count == 1, "Cancelled request later imported")
        let cancelledResult = try store.documentLibrary.prepareIncomingResult(requestID: closed.id)
        let checkedCancel = try GaoActionPackageValidator(expectedTargetBundleID: "com.gaoseries.GaoWenJian")
            .stagePackage(at: cancelledResult, stagingRoot: root.appendingPathComponent("CancelResult"))
        try require(checkedCancel.manifest.status == "cancelled" && checkedCancel.manifest.provenance?["saved"] == .bool(false), "History cancellation lost machine receipt")
        let unsupported = try incomingContext(store, parameters: ["targetRecordID": .string("unsupported-record")])
        try await rejects("Unsupported business target silently imported") {
            _ = try await store.documentLibrary.approveIncomingDocuments(unsupported, targetFolderID: target.id, userApproved: true)
        }
        try require(store.managedDocuments.count == 1, "Unsupported record target changed library")
        _ = try durable(store)
    }
    static func incomingReceiptRecovery(indexInterrupted: Bool = false) async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        let context = try incomingContext(store)
        if indexInterrupted {
            store.documentLibrary.importFailureInjector = { if $0 == .beforeIndex { throw ResearchImportJournal.SimulatedCrash() } }
        } else { store.documentLibrary.incomingReceiptCompletionFailureInjector = { throw Injected.checkpoint } }
        try await rejects("Expected receipt-save interruption did not occur") {
            _ = try await store.documentLibrary.approveIncomingDocuments(context, targetFolderID: target.id, userApproved: true)
        }
        try require(store.managedDocuments.count == 1, "Receipt interruption lost committed import")
        try require(try store.documentLibrary.incomingHandoffs.load(context.validatedPackage.manifest.requestID)?.state == "pending", "Unwritten receipt claimed completed")
        store.documentLibrary.incomingReceiptCompletionFailureInjector = nil
        if indexInterrupted {
            let pendingURL = try store.documentLibrary.prepareIncomingResult(requestID: context.validatedPackage.manifest.requestID)
            let pending = try GaoActionPackageValidator(expectedTargetBundleID: "com.gaoseries.GaoWenJian")
                .stagePackage(at: pendingURL, stagingRoot: root.appendingPathComponent("PendingResult"))
            try require(pending.manifest.status == "pending" && pending.manifest.provenance?["saved"] == .bool(false),
                        "Interrupted index was falsely reported completed")
            try await rejects("Unfinished committed transaction was relabelled cancelled") {
                _ = try store.documentLibrary.cancelIncomingDocuments(context)
            }
            store.documentLibrary.importFailureInjector = nil
            store.documentLibrary.importJournal = nil
            _ = try await store.documentLibrary.resumeIncomingHandoffs()
        }
        // Fresh lightweight receiver instances recover the authoritative completed job.
        store.documentLibrary.importJournal = nil
        let result = try store.documentLibrary.prepareIncomingResult(requestID: context.validatedPackage.manifest.requestID)
        let checked = try GaoActionPackageValidator(expectedTargetBundleID: "com.gaoseries.GaoWenJian")
            .stagePackage(at: result, stagingRoot: root.appendingPathComponent("RecoveredResult"))
        try require(checked.manifest.status == "completed", "Journal did not repair missing completed receipt")
        _ = try await store.documentLibrary.approveIncomingDocuments(context, targetFolderID: target.id, userApproved: true)
        try require(store.managedDocuments.count == 1, "Receipt recovery imported a second attachment")
        _ = try durable(store)
    }
    static func ocrReviewMetadata() async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        // Owned image bytes avoid PDFKit's process/UI registration in a CLI sandbox.
        let png = try unwrap(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aP6kAAAAASUVORK5CYII="), "PNG fixture absent")
        let input = root.appendingPathComponent("Inputs/review.png")
        try GaoActionFileAccess.writePrivateData(png, to: input)
        _ = try await store.importDocuments(from: [input], into: target.id)
        let original = try unwrap(store.managedDocuments.first, "Review original absent")
        // This case tests the receiver review model. UTType's dynamic extension
        // lookup requires services absent in this CLI sandbox, so seed the exact
        // private source session with a validated fixed-UTI request instead of
        // claiming that provider discovery/request GUI was exercised here.
        let sourceURL = store.managedDocumentURL(original)
        let fingerprint = try GaoActionFileAccess.fingerprint(at: sourceURL)
        let item = GaoActionItem(id: "review-input", relativePath: "payload/review.png", uti: "public.png",
                                 byteCount: fingerprint.byteCount, sha256: fingerprint.sha256)
        let parameters: [String: GaoJSONValue] = ["outputs": .array([.string("text"), .string("json")])]
        let template = GaoActionManifest(sourceBundleID: ResearchExchangePaths.bundleID, targetBundleID: ResearchExternalAction.ocrFiles.providerBundleID,
                                         action: "ocr.files", items: [item], parameters: parameters)
        let packageURL = try GaoActionPackageWriter().write(manifest: template, files: [item.id: sourceURL],
                                                            outgoingRoot: ResearchExchangePaths.root.appendingPathComponent("Outgoing"))
        let written = try JSONDecoder().decode(GaoActionManifest.self, from: GaoActionFileAccess.readPrivateData(at: packageURL.appendingPathComponent("manifest.json")))
        let fixtureSession = ResearchExchangeSession(requestID: written.requestID, providerBundleID: written.targetBundleID, action: .ocrFiles,
            requestNonce: written.nonce, packageURL: packageURL.absoluteString, createdAt: Date(),
            sources: [.init(itemID: item.id, documentID: original.id, originalFileURL: sourceURL.standardizedFileURL.absoluteString,
                            sha256: fingerprint.sha256, byteCount: fingerprint.byteCount, identity: fingerprint.identity)],
            state: "prepared", resultIDs: [], importedEditedSHA256: nil)
        try GaoActionFileAccess.writePrivateData(JSONEncoder().encode(fixtureSession),
            to: ResearchExchangePaths.root.appendingPathComponent("Sessions/" + written.requestID + ".json"))
        let request = ResearchPreparedExchange(packageURL: packageURL, requestID: written.requestID, action: .ocrFiles, parameters: parameters)
        let binding = try unwrap(store.documentLibrary.exchangeClient.loadSession(request.requestID).sources.first, "Review source absent")
        let text = try source("review.txt", text: "recognized full text")
        let jsonURL = root.appendingPathComponent("Inputs/review.json")
        func json(_ sourceSHA: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["schemaVersion": 1,
                "sources": [["id": "review-source", "sha256": binding.sha256]],
                "pages": [["sourceID": "review-source", "originalSHA256": sourceSHA, "pageNumber": 1,
                           "status": "completed", "lines": [["readingOrder": 1, "text": "actual page text for review"]]],
                          ["sourceID": "review-source", "originalSHA256": sourceSHA, "pageNumber": 2,
                           "status": "failed", "lines": []]]])
        }
        try GaoActionFileAccess.writePrivateData(json(binding.sha256), to: jsonURL)
        let provenance: [String: GaoJSONValue] = ["engine": .string("fixture OCR"), "engineVersion": .string("1"),
            "sources": .array([.object(["sourceID": .string("review-source"), "sourceItemID": .string(binding.itemID),
                "sourceSHA256": .string(binding.sha256), "outputItemIDs": .array([.string("output-0"), .string("output-1")]),
                "pages": .array([.object(["pageNumber": .number(1), "status": .string("completed")]),
                                 .object(["pageNumber": .number(2), "status": .string("failed")])])])]),
            "outputs": .array([0, 1].map { .object(["resultItemID": .string("output-\($0)"), "sourceItemID": .string(binding.itemID),
                "sourceID": .string("review-source"), "sourceSHA256": .string(binding.sha256)]) })]
        let package = try providerResult(request: request, action: .ocrFiles, files: [text, jsonURL], status: "partial", provenance: provenance)
        let review = try store.documentLibrary.receiveExchangeResultForReview(at: package)
        try require(review.result.package.manifest.status == "partial" && review.canApply && review.requiresExplicitReview, "Partial review lost approval gate")
        try require(review.result.ocrOutputs.allSatisfy { $0.sourceDocumentID == original.id && $0.sourceSHA256 == binding.sha256 && !$0.warnings.isEmpty }, "Review lost original mapping or missing metadata warnings")
        try require(review.ocrReviewPages.count == 2 && review.ocrReviewPages.values.allSatisfy {
            $0.first(where: { $0.pageNumber == 1 })?.text == "actual page text for review" && $0.first(where: { $0.pageNumber == 2 })?.status == "failed"
        }, "Review hid actual page text or failure state")
        try require(store.managedDocuments.count == 1, "Review silently imported OCR derivatives")
        try GaoActionFileAccess.writePrivateData(json(String(repeating: "f", count: 64)), to: jsonURL)
        let badPackage = try providerResult(request: request, action: .ocrFiles, files: [text, jsonURL], status: "partial", provenance: provenance)
        let invalidReview = try store.documentLibrary.receiveExchangeResultForReview(at: badPackage)
        try require(!invalidReview.canApply && !invalidReview.ocrReviewErrors.isEmpty, "Invalid JSON page provenance remained approvable")
        _ = try durable(store)
    }
    static func targetGone() async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        let file = try source("gone.txt", text: "target removed before commit")
        store.documentLibrary.importFailureInjector = { point in
            if point == .beforeDatabaseCommit {
                store.documentFolders.removeAll(where: { $0.id == target.id })
                try store.saveThrowing()
            }
        }
        try await rejects("Deleted target was recreated by stale import envelope") { _ = try await store.importDocuments(from: [file], into: target.id) }
        try require(!store.documentFolders.contains(where: { $0.id == target.id }) && store.managedDocuments.isEmpty, "Deleted target or orphan record was committed")
        _ = try durable(store)
    }
    static func versionCAS() async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        let original = try await importOriginal(store, folder: target)
        let originalURL = store.managedDocumentURL(original)
        let originalSHA = try GaoActionFileAccess.fingerprint(at: originalURL).sha256
        _ = try store.documentLibrary.exchangeClient.prepareExternalEdit(documentID: original.id, originalURL: originalURL, originalVersion: original.updatedAt)
        let edited = try source("conflicted.txt", text: "must not commit stale edit")
        store.documentLibrary.importJournal = nil
        store.documentLibrary.importFailureInjector = { point in
            if point == .beforeDatabaseCommit, let index = store.managedDocuments.firstIndex(where: { $0.id == original.id }) {
                store.managedDocuments[index].updatedAt = original.updatedAt.addingTimeInterval(10)
                store.managedDocuments[index].tags = ["concurrent update"]
                try store.saveThrowing()
            }
        }
        try await rejects("Stale revision silently replaced concurrent record") { try await store.importEditedDocumentCopy(for: original, from: edited, asNewVersion: true) }
        let current = try unwrap(store.managedDocuments.first(where: { $0.id == original.id }), "CAS conflict removed original record")
        try require(current.storedName == original.storedName && current.tags == ["concurrent update"], "CAS rollback discarded concurrent state")
        try require(try GaoActionFileAccess.fingerprint(at: originalURL).sha256 == originalSHA, "CAS conflict changed original bytes")
        _ = try durable(store)
    }
    static func recovery(_ name: String) async throws {
        let (store, repository) = try makeStore(); let target = try folder(store)
        let file = try source("recovery.txt", text: "recover durable product index needle")
        if name == "database-recovery" { repository.failNextSave = true }
        else {
            let point: ResearchImportJournal.FaultPoint = name == "attachment-recovery" ? .beforeAttachmentCommit(0) : .beforeIndex
            store.documentLibrary.importFailureInjector = { if $0 == point { throw ResearchImportJournal.SimulatedCrash() } }
        }
        try await rejects("Injected product failure did not interrupt import") { _ = try await store.importDocuments(from: [file], into: target.id) }
        store.documentLibrary.importFailureInjector = nil; store.documentLibrary.importJournal = nil
        // Reload the actual persisted library into a fresh product store, rather
        // than treating the interrupted in-memory adapter as a restart.
        let restarted = PaperStore(repository: FaultingDiskRepository())
        try require(!restarted.libraryLoadFailed, "Restart could not load the real disk library")
        let journal = try restarted.documentLibrary.transactionJournal()
        let results = await journal.recoverPending()
        try require(!results.isEmpty && results.allSatisfy({ $0.errorCode == nil }), "Product journal recovery did not complete")
        try require(restarted.managedDocuments.count == 1, "Product recovery lost or duplicated document")
        try require(restarted.managedDocuments[0].contentText?.contains("product index needle") == true, "Recovery did not persist real extracted index")
        let saved = try durable(restarted)
        try require(saved.managedDocuments[0].contentIndexedAt != nil, "Recovered index timestamp was not durable")
        let initialText = restarted.managedDocuments[0].contentText
        try await restarted.documentLibrary.indexImportedDocuments(documentIDs: [restarted.managedDocuments[0].id])
        try require(restarted.managedDocuments[0].contentText == initialText, "Repeated product indexing changed complete text")
        let again = await journal.recoverPending()
        try require(again.allSatisfy({ $0.errorCode == nil }) && restarted.managedDocuments.count == 1, "Completed recovery replayed side effects")
        try require(restarted.managedDocuments[0].contentText == initialText, "Repeated recovery increased indexed text")
    }
    static func providerResult(request: ResearchPreparedExchange, action: ResearchExternalAction,
                               files: [URL] = [], references: [GaoActionReference] = [],
                               status: String = "completed", provenance: [String: GaoJSONValue]) throws -> URL {
        let items = files.enumerated().map { index, url in
            GaoActionItem(id: "output-\(index)", relativePath: "payload/output-\(index).\(url.pathExtension)",
                          uti: ["txt": "public.utf8-plain-text", "json": "public.json", "pdf": "com.adobe.pdf"][url.pathExtension] ?? "public.data",
                          byteCount: 0, sha256: String(repeating: "0", count: 64))
        }
        let manifest = GaoActionManifest(kind: "result", sourceBundleID: action.providerBundleID,
                                         targetBundleID: ResearchExchangePaths.bundleID, action: action.rawValue,
                                         items: items, references: references, inReplyTo: request.requestID,
                                         status: status, provenance: provenance)
        return try GaoActionPackageWriter().write(manifest: manifest,
            files: Dictionary(uniqueKeysWithValues: zip(items.map(\.id), files)),
            outgoingRoot: root.appendingPathComponent("ProviderOutgoing"))
    }
    static func selectionResult() async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        let client = store.documentLibrary.exchangeClient
        let request = try client.prepareFileSelection(allowedUTIs: ["public.utf8-plain-text"], multiple: true, targetFolderID: target.id)
        let selected = try source("selected.txt", text: "provider selected scientific document")
        let reference = try GaoActionReference.capture(at: selected, kind: "file")
        let package = try providerResult(request: request, action: .chooseFiles, references: [reference], provenance: ["workflowState": .string("selected")])
        let review = try store.documentLibrary.receiveExchangeResultForReview(at: package)
        try require(store.managedDocuments.isEmpty, "Receiving a result performed an unapproved import")
        try await rejects("Provider result bypassed required approval") {
            _ = try await store.documentLibrary.applyExchangeResult(review, userApproved: false)
        }
        try require(store.managedDocuments.isEmpty, "Rejected approval mutated library records")
        store.documentLibrary.importFailureInjector = { if $0 == .beforeIndex { throw ResearchImportJournal.SimulatedCrash() } }
        try await rejects("Selection interruption did not stop before business receipt") {
            _ = try await store.documentLibrary.applyExchangeResult(review, userApproved: true)
        }
        let interruptedSession = try client.loadSession(request.requestID)
        try require(interruptedSession.appliedResults?[review.id] == nil, "Interrupted selection falsely recorded business completion")
        store.documentLibrary.importFailureInjector = nil; store.documentLibrary.importJournal = nil
        let outcome = try await store.documentLibrary.applyExchangeResult(review, userApproved: true)
        try require(outcome.importedCount == 1 && store.managedDocuments.count == 1, "Approved selection did not commit through product journal")
        try require(try GaoActionFileAccess.fingerprint(at: selected).sha256 == reference.sha256, "Selection import changed original")
        let session = try client.loadSession(request.requestID)
        let resultID = review.result.package.manifest.requestID
        try require(session.appliedResults?[resultID]?.importedDocumentIDs == outcome.documentIDs, "Selection business receipt was not durable")
        let repeated = try store.documentLibrary.receiveExchangeResultForReview(at: package)
        let replay = try await store.documentLibrary.applyExchangeResult(repeated, userApproved: true)
        try require(replay.replayed && replay.documentIDs == outcome.documentIDs && store.managedDocuments.count == 1, "Applied provider result repeated side effects")
        let refreshedPackage = try providerResult(request: request, action: .chooseFiles, references: [reference], provenance: ["workflowState": .string("selected")])
        let refreshed = try store.documentLibrary.receiveExchangeResultForReview(at: refreshedPackage)
        try require(refreshed.id != review.id, "Refreshed provider result must have a new envelope ID")
        let refreshedOutcome = try await store.documentLibrary.applyExchangeResult(refreshed, userApproved: true)
        try require(refreshedOutcome.replayed && refreshedOutcome.documentIDs == outcome.documentIDs && store.managedDocuments.count == 1,
                    "Refreshed chooser envelope duplicated the same business import")
        let receipts = try client.loadSession(request.requestID).appliedResults
        try require(receipts?[review.id] != nil && receipts?[refreshed.id] != nil && receipts?[review.id]?.receiptID == receipts?[refreshed.id]?.receiptID,
                    "Each refreshed envelope needs its own receipt linked to the same stable business job")
        _ = try durable(store)
    }
    static func selectionTargetGone() async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        let client = store.documentLibrary.exchangeClient
        let request = try client.prepareFileSelection(targetFolderID: target.id)
        let selected = try source("selection-gone.txt", text: "cannot silently retarget selection")
        let reference = try GaoActionReference.capture(at: selected, kind: "file")
        let package = try providerResult(request: request, action: .chooseFiles, references: [reference], provenance: ["workflowState": .string("selected")])
        store.documentFolders.removeAll(where: { $0.id == target.id }); try store.saveThrowing()
        let other = try folder(store)
        let review = try store.documentLibrary.receiveExchangeResultForReview(at: package)
        try await rejects("Deleted provider target silently chose another folder") {
            _ = try await store.documentLibrary.applyExchangeResult(review, userApproved: true)
        }
        try require(store.managedDocuments.isEmpty, "Invalid target imported a provider result")
        let received = try client.loadSession(request.requestID)
        try require(received.appliedResults?[review.result.package.manifest.requestID] == nil, "Invalid target falsely marked result applied")
        let outcome = try await store.documentLibrary.applyExchangeResult(review, userApproved: true, targetFolderID: other.id)
        try require(outcome.importedCount == 1 && store.managedDocuments.first?.folderID == other.id, "Explicit target review did not route correctly")
        _ = try durable(store)
    }
    static func selectionUnboundReference() async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        let client = store.documentLibrary.exchangeClient
        let request = try client.prepareFileSelection(targetFolderID: target.id)
        let selected = try source("explicit-selection.txt", text: "first explicitly selected contents")
        let reference = GaoActionReference(kind: "file", fileURL: selected.absoluteString,
                                           displayName: selected.lastPathComponent, declaredIdentity: .init())
        let firstPackage = try providerResult(request: request, action: .chooseFiles, references: [reference], provenance: ["workflowState": .string("selected")])
        let firstReview = try store.documentLibrary.receiveExchangeResultForReview(at: firstPackage)
        let originalSelectedSHA = try GaoActionFileAccess.fingerprint(at: selected).sha256
        store.documentLibrary.importFailureInjector = { if $0 == .beforeIndex { throw ResearchImportJournal.SimulatedCrash() } }
        try await rejects("Unbound selection must stop before receipt at the injected interruption") {
            _ = try await store.documentLibrary.applyExchangeResult(firstReview, userApproved: true, reselectedReferences: [reference.id: selected])
        }
        let pending = try client.loadSession(request.requestID)
        try require(pending.resultIntents?[firstReview.id] != nil && pending.appliedResults?[firstReview.id] == nil,
                    "Pending intent must be durable without claiming business completion")
        try GaoActionFileAccess.writePrivateData(Data("second explicitly selected contents".utf8), to: selected)
        store.documentLibrary.importFailureInjector = nil; store.documentLibrary.importJournal = nil
        let first = try await store.documentLibrary.applyExchangeResult(firstReview, userApproved: true, reselectedReferences: [reference.id: selected])
        let firstID = try unwrap(first.documentIDs.first, "Unbound first selection did not import")
        let firstRecord = try unwrap(store.managedDocuments.first(where: { $0.id == firstID }), "Missing first selection record")
        let firstSHA = try GaoActionFileAccess.fingerprint(at: store.managedDocumentURL(firstRecord)).sha256
        try require(firstSHA == originalSelectedSHA, "Same-envelope recovery rebound to changed referenced bytes instead of its frozen stage")
        let changedSHA = try GaoActionFileAccess.fingerprint(at: selected).sha256
        try require(changedSHA != firstSHA, "Selection fixture contents did not change")
        let secondPackage = try providerResult(request: request, action: .chooseFiles, references: [reference], provenance: ["workflowState": .string("selected")])
        let secondReview = try store.documentLibrary.receiveExchangeResultForReview(at: secondPackage)
        store.documentLibrary.importFailureInjector = { if $0 == .afterStaging { throw ResearchImportJournal.SimulatedCrash() } }
        store.documentLibrary.importJournal = nil
        try await rejects("Missing-journal fixture must first stop after owned staging") {
            _ = try await store.documentLibrary.applyExchangeResult(secondReview, userApproved: true, reselectedReferences: [reference.id: selected])
        }
        let secondIntent = try unwrap(client.loadSession(request.requestID).resultIntents?[secondReview.id], "Second pending intent missing")
        // Isolated simulation of the write-ahead intent/journal gap. No record
        // for this operation has been committed; retained staging is untouched.
        for directory in ["ImportJobs", "ProcessedRequests"] {
            let metadata = ResearchExchangePaths.root.appendingPathComponent("Metadata/" + directory + "/" + secondIntent.jobID.lowercased() + ".json")
            try FileManager.default.removeItem(at: metadata)
        }
        try GaoActionFileAccess.writePrivateData(Data("third contents after the intent was bound".utf8), to: selected)
        store.documentLibrary.importFailureInjector = nil; store.documentLibrary.importJournal = nil
        do {
            _ = try await store.documentLibrary.applyExchangeResult(secondReview, userApproved: true, reselectedReferences: [reference.id: selected])
            throw Failure(description: "Missing journal rebound the same envelope to a different actual intent")
        } catch ResearchDocumentImportError.resultIntentConflict { }
        let conflicted = try client.loadSession(request.requestID)
        try require(conflicted.resultIntents?[secondReview.id] == secondIntent && conflicted.appliedResults?[secondReview.id] == nil && store.managedDocuments.count == 1,
                    "Intent conflict changed its association, applied receipt or records")
        try GaoActionFileAccess.writePrivateData(Data("second explicitly selected contents".utf8), to: selected)
        let second = try await store.documentLibrary.applyExchangeResult(secondReview, userApproved: true, reselectedReferences: [reference.id: selected])
        try require(second.importedCount == 1 && second.documentIDs != first.documentIDs && store.managedDocuments.count == 2,
                    "New envelope ignored actual reselected bytes and replayed an earlier unbound reference")
        let secondRecord = try unwrap(store.managedDocuments.first(where: { second.documentIDs.contains($0.id) }), "Missing actual reselected contents")
        try require(try GaoActionFileAccess.fingerprint(at: store.managedDocumentURL(secondRecord)).sha256 == changedSHA,
                    "Selection semantic binding did not import the verified current bytes")
        try require(try GaoActionFileAccess.fingerprint(at: store.managedDocumentURL(firstRecord)).sha256 == firstSHA,
                    "Reselecting changed bytes modified the previous managed copy")
        let replayPackage = try providerResult(request: request, action: .chooseFiles, references: [reference], provenance: ["workflowState": .string("selected")])
        let replayReview = try store.documentLibrary.receiveExchangeResultForReview(at: replayPackage)
        let replay = try await store.documentLibrary.applyExchangeResult(replayReview, userApproved: true, reselectedReferences: [reference.id: selected])
        try require(replay.replayed && replay.documentIDs == second.documentIDs && store.managedDocuments.count == 2,
                    "The same independently verified reference bytes did not reuse the correct semantic job")
        let receipts = try client.loadSession(request.requestID).appliedResults
        try require(receipts?[firstReview.id]?.receiptID != receipts?[secondReview.id]?.receiptID &&
                    receipts?[secondReview.id]?.receiptID == receipts?[replayReview.id]?.receiptID,
                    "Selection business receipts did not distinguish actual verified byte bindings")
        _ = try durable(store)
    }
    static func fixturePDF(_ texts: [String]) throws -> Data {
        // Small deterministic PDF writer for owned fixtures; no rendering or UI.
        var objects = ["<< /Type /Catalog /Pages 2 0 R >>", ""]
        let pageObjects = texts.indices.map { 3 + $0 * 2 }
        objects[1] = "<< /Type /Pages /Kids [" + pageObjects.map { "\($0) 0 R" }.joined(separator: " ") + "] /Count \(texts.count) >>"
        let font = 3 + texts.count * 2
        for (index, text) in texts.enumerated() {
            let content = "BT /F1 12 Tf 20 170 Td (" + text + ") Tj ET"
            objects.append("<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 \(font) 0 R >> >> /Contents \(4 + index * 2) 0 R >>")
            objects.append("<< /Length \(content.utf8.count) >>\nstream\n" + content + "\nendstream")
        }
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        var pdf = "%PDF-1.4\n", offsets = [0]
        for (index, object) in objects.enumerated() {
            offsets.append(pdf.utf8.count); pdf += "\(index + 1) 0 obj\n\(object)\nendobj\n"
        }
        let xref = pdf.utf8.count
        pdf += "xref\n0 \(objects.count + 1)\n0000000000 65535 f \n"
        for offset in offsets.dropFirst() { pdf += String(format: "%010d 00000 n \n", offset) }
        pdf += "trailer\n<< /Size \(objects.count + 1) /Root 1 0 R >>\nstartxref\n\(xref)\n%%EOF\n"
        let data = Data(pdf.utf8)
        try require(PDFDocument(data: data)?.pageCount == texts.count, "Owned PDF fixture page count invalid")
        return data
    }
    static func ocrManagedResult(includeJSON: Bool = false, legacyJob: Bool = false) async throws {
        let (store, _) = try makeStore(); let target = try folder(store)
        // A self-created valid tiny image; this test never captures the screen or uses personal files.
        let image = try unwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                        colorSpaceName: .deviceRGB, bytesPerRow: 8, bitsPerPixel: 32), "Cannot create fixture image")
        if let pixels = image.bitmapData { memset(pixels, 255, 16) }
        let png = try unwrap(image.representation(using: .png, properties: [:]), "Cannot encode fixture image")
        let input = root.appendingPathComponent(includeJSON ? "Inputs/scanned.pdf" : "Inputs/scanned.png")
        try GaoActionFileAccess.writePrivateData(includeJSON ? fixturePDF(["original page one", "original page two"]) : png, to: input)
        _ = try await store.importDocuments(from: [input], into: target.id)
        let original = try unwrap(store.managedDocuments.first, "Original image import missing")
        let originalURL = store.managedDocumentURL(original)
        let originalSHA = try GaoActionFileAccess.fingerprint(at: originalURL).sha256
        let client = store.documentLibrary.exchangeClient
        let request = try client.prepareOCR(userSelectedFiles: [.init(url: originalURL, documentID: original.id)], languages: ["zh-Hans"], outputs: includeJSON ? ["text", "json", "searchablePDF"] : ["text"])
        let session = try client.loadSession(request.requestID)
        let binding = try unwrap(session.sources.first, "OCR source binding absent")
        let text = try source("recognized.txt", text: "OCR scientific derivative searchable-needle\n")
        let sourceRecord: [String: GaoJSONValue] = [
            "sourceID": .string("fixture-provider-source"), "sourceItemID": .string(binding.itemID),
            "sourceSHA256": .string(binding.sha256), "outputItemIDs": .array((includeJSON ? ["output-0", "output-1", "output-2"] : ["output-0"]).map(GaoJSONValue.string)),
            "pages": .array([.object(["pageNumber": .number(1), "status": .string("completed"), "elapsedSeconds": .number(0.1), "lineCount": .number(1), "failureReason": .null]),
                             .object(["pageNumber": .number(2), "status": .string("failed"), "elapsedSeconds": .number(0.1), "lineCount": .number(0), "failureReason": .string("fixture-page-failure")])])]
        let mapping: [String: GaoJSONValue] = ["sourceID": .string("fixture-provider-source"),
            "sourceItemID": .string(binding.itemID), "sourceSHA256": .string(binding.sha256),
            "resultItemID": .string("output-0"), "format": .string("text")]
        var outputFiles = [text], mappings = [GaoJSONValue.object(mapping)]
        if includeJSON {
            let json: [String: Any] = ["schemaVersion": 1,
                "sources": [["id": "fixture-provider-source", "sha256": binding.sha256]],
                "pages": [
                    ["sourceID": "fixture-provider-source", "originalSHA256": binding.sha256, "pageNumber": 1,
                     "status": "completed", "lines": [["readingOrder": 2, "text": "second recognized line"], ["readingOrder": 1, "text": "first recognized line"]]],
                    ["sourceID": "fixture-provider-source", "originalSHA256": binding.sha256, "pageNumber": 2,
                     "status": "failed", "lines": []]]]
            let jsonURL = root.appendingPathComponent("Inputs/recognized.json")
            try GaoActionFileAccess.writePrivateData(JSONSerialization.data(withJSONObject: json), to: jsonURL)
            let pdfURL = root.appendingPathComponent("Inputs/searchable.pdf")
            try GaoActionFileAccess.writePrivateData(fixturePDF(["first recognized line", ""]), to: pdfURL)
            outputFiles += [jsonURL, pdfURL]
            for (index, format) in [(1, "json"), (2, "searchablePDF")] {
                var next = mapping; next["resultItemID"] = .string("output-\(index)"); next["format"] = .string(format)
                mappings.append(.object(next))
            }
        }
        let provenance: [String: GaoJSONValue] = ["engine": .string("Apple Vision VNRecognizeTextRequest"),
            "engineRevision": .number(3), "sources": .array([.object(sourceRecord)]), "outputs": .array(mappings),
            "networkUsed": .bool(false), "exportFailures": .array([])]
        let package = try providerResult(request: request, action: .ocrFiles, files: outputFiles, status: "partial", provenance: provenance)
        let review = try store.documentLibrary.receiveExchangeResultForReview(at: package)
        try require(!review.ocrReviewPages.isEmpty && review.ocrReviewPages.values.allSatisfy { $0.contains(where: { $0.pageNumber == 2 && $0.status == "failed" }) },
                    "Review model hid failed page status")
        if includeJSON {
            try require(review.ocrReviewPages.values.allSatisfy { $0.first(where: { $0.pageNumber == 1 })?.text == "first recognized line\nsecond recognized line" },
                        "Review model hid available JSON page text")
        }
        try require(store.managedDocuments.count == 1, "Receiving OCR result silently changed the library")
        try require(review.result.ocrOutputs.count == outputFiles.count && review.result.ocrOutputs[0].pages.count == 2, "Real screenshot provider OCR mapping was not preserved")
        let outcome = try await store.documentLibrary.applyExchangeResult(review, userApproved: true)
        try require(outcome.importedCount == outputFiles.count && store.managedDocuments.count == outputFiles.count + 1, "OCR outputs did not all become managed derivatives")
        let derived = try unwrap(store.managedDocuments.first(where: { $0.id != original.id && $0.fileExtension == "txt" }), "OCR managed text derivative missing")
        try require(derived.contentText?.contains("searchable-needle") == true, "Managed OCR text was not extracted/indexed")
        let relation = try unwrap(store.documentRevision(for: derived.id), "OCR derivative relation missing")
        try require(relation.originalDocumentID == original.id && relation.originalSHA256 == originalSHA, "OCR derivative linked to wrong original")
        let savedProvenance = try unwrap(store.documentProvenance(for: derived.id), "OCR source provenance missing")
        try require(savedProvenance.pages.count == 2 && savedProvenance.pages.contains(where: { $0.status == "failed" }), "OCR partial page state was lost")
        try require(savedProvenance.ocrEngine == "Apple Vision VNRecognizeTextRequest", "OCR engine declaration lost")
        try require(savedProvenance.ocrLanguages.isEmpty, "Missing provider language was invented from requested options")
        try require(savedProvenance.ocrVersion == "revision 3", "Provider engine revision was not preserved")
        if includeJSON {
            for document in store.managedDocuments where document.id != original.id {
                let metadata = try unwrap(store.documentProvenance(for: document.id), "Derivative provenance missing")
                try require(metadata.pages.first(where: { $0.pageNumber == 1 })?.text == "first recognized line\nsecond recognized line", "JSON page text/reading order was not associated with original page")
                try require(metadata.pages.first(where: { $0.pageNumber == 2 })?.status == "failed", "Failed original page was not retained")
            }
            let pdfDocument = try unwrap(store.managedDocuments.first(where: { $0.id != original.id && $0.fileExtension == "pdf" }), "Searchable PDF derivative missing")
            try require(PDFDocument(url: store.managedDocumentURL(pdfDocument))?.pageCount == 2, "Searchable PDF lost original page mapping")
        }
        try require(!derived.tags.contains("已OCR"), "Partial OCR was mislabeled completed")
        try require(try GaoActionFileAccess.fingerprint(at: originalURL).sha256 == originalSHA, "OCR changed original image")
        let durableSession = try client.loadSession(request.requestID)
        try require(durableSession.appliedResults?[review.result.package.manifest.requestID]?.importedDocumentIDs == outcome.documentIDs, "OCR business receipt missing")
        if legacyJob {
            // Reconstruct only this isolated fixture's V4.03 storage naming:
            // before semantic jobs, the result envelope UUID was the job UUID.
            // Payload, immutable plans and provenance stay byte-for-byte intact.
            let receipt = try unwrap(durableSession.appliedResults?[review.id], "Missing fixture receipt")
            let oldID = try unwrap(UUID(uuidString: receipt.receiptID), "Invalid fixture business ID")
            let legacyID = try unwrap(UUID(uuidString: review.id), "Invalid fixture envelope ID")
            try require(oldID != legacyID, "Fixture must first create a semantic job")
            for directory in ["ImportJobs", "ProcessedRequests"] {
                let parent = ResearchExchangePaths.root.appendingPathComponent("Metadata/" + directory)
                let from = parent.appendingPathComponent(oldID.uuidString.lowercased() + ".json")
                let to = parent.appendingPathComponent(legacyID.uuidString.lowercased() + ".json")
                var record = try JSONSerialization.jsonObject(with: GaoActionFileAccess.readPrivateData(at: from, maximumBytes: 64 * 1_048_576)) as! [String: Any]
                record["requestID"] = legacyID.uuidString
                try GaoActionFileAccess.writePrivateData(JSONSerialization.data(withJSONObject: record), to: to)
                try FileManager.default.removeItem(at: from)
            }
            let sessionURL = ResearchExchangePaths.root.appendingPathComponent("Sessions/" + request.requestID + ".json")
            var value = try JSONSerialization.jsonObject(with: GaoActionFileAccess.readPrivateData(at: sessionURL)) as! [String: Any]
            var receipts = value["appliedResults"] as! [String: [String: Any]]
            // Losing only a business receipt must still resume the exact old
            // envelope UUID from its frozen, already completed journal.
            receipts.removeValue(forKey: review.id)
            value["appliedResults"] = receipts
            value.removeValue(forKey: "resultIntents")
            try GaoActionFileAccess.writePrivateData(JSONSerialization.data(withJSONObject: value), to: sessionURL)
        }
        let initialText = Dictionary(uniqueKeysWithValues: store.managedDocuments.map { ($0.id, $0.contentText) })
        try await store.documentLibrary.indexImportedDocuments(documentIDs: outcome.documentIDs)
        try await store.documentLibrary.indexImportedDocuments(documentIDs: outcome.documentIDs)
        let indexedAgain = Dictionary(uniqueKeysWithValues: store.managedDocuments.map { ($0.id, $0.contentText) })
        try require(initialText == indexedAgain, "Repeated OCR index/recovery compounded full text")
        let repeated = try store.documentLibrary.receiveExchangeResultForReview(at: package)
        let replay = try await store.documentLibrary.applyExchangeResult(repeated, userApproved: true)
        try require(replay.replayed && replay.documentIDs == outcome.documentIDs && store.managedDocuments.count == outputFiles.count + 1, "Repeated OCR result created duplicate derived attachments")
        if legacyJob {
            let restoredReceipt = try unwrap(client.loadSession(request.requestID).appliedResults?[review.id], "Exact legacy recovery did not repair its receipt")
            try require(restoredReceipt.receiptID == UUID(uuidString: review.id)?.uuidString, "Legacy exact-envelope recovery changed its frozen job")
        }
        // GaoJieTu sendResult refreshes requestID/TTL/nonce while preserving the
        // original inReplyTo, output IDs, bytes and provenance. This is a new
        // transport receipt, not a second approved business operation.
        let refreshedPackage = try providerResult(request: request, action: .ocrFiles, files: outputFiles, status: "partial", provenance: provenance)
        let refreshed = try store.documentLibrary.receiveExchangeResultForReview(at: refreshedPackage)
        try require(refreshed.id != review.id && !refreshed.result.duplicate, "Producer-style resend must use a new envelope")
        if legacyJob {
            let journal = try store.documentLibrary.transactionJournal()
            let originalJobs = Set(try journal.recentJobs(limit: Int.max).map(\.requestID))
            do {
                _ = try await store.documentLibrary.applyExchangeResult(refreshed, userApproved: true)
                throw Failure(description: "New envelope reused an old job without full legacy intent evidence")
            } catch ResearchDocumentImportError.legacyResultReviewRequired { }
            // failureReason was never retained in the old Page sidecar. Even
            // matching persisted page status/text cannot prove equal intent.
            var changedSource = sourceRecord
            changedSource["pages"] = .array([.object(["pageNumber": .number(1), "status": .string("completed"), "elapsedSeconds": .number(0.1), "lineCount": .number(1), "failureReason": .null]),
                                             .object(["pageNumber": .number(2), "status": .string("failed"), "elapsedSeconds": .number(0.1), "lineCount": .number(0), "failureReason": .string("changed-unpersisted-evidence")])])
            var changedProvenance = provenance; changedProvenance["sources"] = .array([.object(changedSource)])
            let changedPackage = try providerResult(request: request, action: .ocrFiles, files: outputFiles, status: "partial", provenance: changedProvenance)
            let changed = try store.documentLibrary.receiveExchangeResultForReview(at: changedPackage)
            do {
                _ = try await store.documentLibrary.applyExchangeResult(changed, userApproved: true)
                throw Failure(description: "Changed legacy page evidence was silently treated as the old business intent")
            } catch ResearchDocumentImportError.legacyResultReviewRequired { }
            let receipts = try client.loadSession(request.requestID).appliedResults
            try require(receipts?[review.id] != nil && receipts?[refreshed.id] == nil && receipts?[changed.id] == nil,
                        "Legacy conflict must remain received-only, without fabricated applied receipts")
            try require(Set(try journal.recentJobs(limit: Int.max).map(\.requestID)) == originalJobs && store.managedDocuments.count == outputFiles.count + 1,
                        "Legacy conflict created jobs or duplicate derivatives")
            try require(store.documentLibrary.pendingExchangeResultReview?.id == changed.id,
                        "Legacy conflict disappeared from explicit review")
        } else {
            let refreshedOutcome = try await store.documentLibrary.applyExchangeResult(refreshed, userApproved: true)
            try require(refreshedOutcome.replayed && refreshedOutcome.documentIDs == outcome.documentIDs && store.managedDocuments.count == outputFiles.count + 1,
                        "Refreshed OCR envelope duplicated managed derivatives")
            let receipts = try client.loadSession(request.requestID).appliedResults
            try require(receipts?[review.id] != nil && receipts?[refreshed.id] != nil && receipts?[review.id]?.receiptID == receipts?[refreshed.id]?.receiptID,
                        "OCR refreshed envelopes must have independent receipts for one stable business job")
        }
        _ = try durable(store)
    }
    static func main() async {
        setbuf(stdout, nil)
        do {
            guard let path = ProcessInfo.processInfo.environment["GAO_PRODUCT_TEST_ROOT"], path.hasPrefix("/private/tmp/"),
                  ProcessInfo.processInfo.environment["GAOQINIANSAN_INTEGRATION_TEST"] == "1",
                  ProcessInfo.processInfo.environment["GAO_RESEARCH_DATA_DIR"] == path + "/Data",
                  let name = CommandLine.arguments.dropFirst().first else { throw Failure(description: "Use scripts/test_product.sh for safe fixture isolation") }
            root = URL(fileURLWithPath: path, isDirectory: true)
            try require(Bundle.main.bundleURL.pathExtension == "bundle" &&
                        Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String == "BNDL",
                        "Product fixture must be a plain bundle, never a LaunchServices application host")
            try require(ResearchExchangePaths.bundleID == "com.academic-achievement.manager", "Test bundle does not expose production research routing identity")
            switch name {
            case "fresh-import": try await freshImport()
            case "new-attachment": try await newAttachment()
            case "new-version": try await newVersion()
            case "repeated-request": try await repeatedRequest()
            case "incoming-handoff": try await incomingHandoff()
            case "incoming-receipt-recovery": try await incomingReceiptRecovery()
            case "incoming-index-recovery": try await incomingReceiptRecovery(indexInterrupted: true)
            case "ocr-review-metadata": try await ocrReviewMetadata()
            case "target-gone": try await targetGone()
            case "version-cas": try await versionCAS()
            case "selection-result": try await selectionResult()
            case "selection-target-gone": try await selectionTargetGone()
            case "selection-unbound-reference": try await selectionUnboundReference()
            case "ocr-managed-result": try await ocrManagedResult()
            case "ocr-json-managed-result": try await ocrManagedResult(includeJSON: true)
            case "ocr-legacy-envelope-retry": try await ocrManagedResult(includeJSON: true, legacyJob: true)
            case "attachment-recovery", "database-recovery", "index-recovery": try await recovery(name)
            default: throw Failure(description: "Unknown targeted product test")
            }
            print("PASS Product \(name)")
        } catch {
            fputs("FAIL Product: \(error)\n", stderr)
            exit(EXIT_FAILURE)
        }
    }
}
