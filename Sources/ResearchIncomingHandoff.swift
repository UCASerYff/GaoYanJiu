import AppKit
import Foundation
import CryptoKit

/// Receiver-owned business state. A result envelope can expire or fail to open
/// at the sender without losing this receipt or repeating the library commit.
struct ResearchIncomingReceipt: Codable, Identifiable {
    var id: String { request.requestID }
    var format = 1
    var request: GaoActionManifest
    var requestManifestSHA256: String
    var targetFolderID: String?
    var state = "pending"
    var outcome: ResearchImportJournal.Outcome?
    var updatedAt = Date()
    var receiptID: String { "incoming:" + id }
    var isTerminal: Bool { state == "completed" || state == "cancelled" }
}

enum ResearchIncomingHandoffError: LocalizedError {
    case requestConflict, targetConflict, unsupportedRecordTarget, undecidedImport, invalidReceipt
    var errorDescription: String? {
        switch self {
        case .requestConflict: return "此请求编号已绑定另一份交接内容，已停止接收；请让发送方发起新请求。"
        case .targetConflict: return "此请求已绑定其他目标文件夹，不能更换目标后重放；请发起新请求。"
        case .unsupportedRecordTarget: return "发送方指定了业务记录。本版本仅支持本人选择资料文件夹，不支持记录绑定；请让发送方移除 targetRecordID 后重新发起。"
        case .undecidedImport: return "此请求已有尚待恢复的导入事务，暂不能取消或声称完成；请先恢复并核对导入状态。"
        case .invalidReceipt: return "交接回执缺失或无法核验，已保留原资料。"
        }
    }
}

@MainActor
struct ResearchIncomingHandoffStore {
    let root: URL
    private var receipts: URL { root.appendingPathComponent("IncomingReceipts", isDirectory: true) }
    private func url(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw ResearchIncomingHandoffError.invalidReceipt }
        return receipts.appendingPathComponent(uuid.uuidString.lowercased() + ".json")
    }
    func load(_ id: String) throws -> ResearchIncomingReceipt? {
        let path = try url(id)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let value = try JSONDecoder().decode(ResearchIncomingReceipt.self, from: GaoActionFileAccess.readPrivateData(at: path, maximumBytes: 2 * 1_048_576))
        guard value.format == 1, UUID(uuidString: value.id) == UUID(uuidString: id), value.request.kind == "request",
              value.request.action == "research.importDocuments",
              !value.request.items.isEmpty, value.request.items.count <= 256,
              Set(value.request.items.map(\.id)).count == value.request.items.count,
              value.requestManifestSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              ["pending", "completed", "cancelled"].contains(value.state),
              (value.state == "completed") == (value.outcome != nil) else { throw ResearchIncomingHandoffError.invalidReceipt }
        return value
    }
    func save(_ receipt: ResearchIncomingReceipt) throws {
        try GaoActionFileAccess.ensurePrivateDirectory(at: receipts)
        var value = receipt; value.updatedAt = Date()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try GaoActionFileAccess.writePrivateData(encoder.encode(value), to: url(value.id))
    }
    func register(_ package: GaoValidatedActionPackage) throws -> ResearchIncomingReceipt {
        guard package.manifest.kind == "request", package.manifest.action == "research.importDocuments",
              package.manifestSHA256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw ResearchIncomingHandoffError.invalidReceipt
        }
        if let previous = try load(package.manifest.requestID) {
            guard previous.requestManifestSHA256 == package.manifestSHA256,
                  previous.request == package.manifest else { throw ResearchIncomingHandoffError.requestConflict }
            return previous
        }
        let value = ResearchIncomingReceipt(request: package.manifest, requestManifestSHA256: package.manifestSHA256)
        try save(value)
        return value
    }
    func recent() throws -> [ResearchIncomingReceipt] {
        guard FileManager.default.fileExists(atPath: receipts.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: receipts, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map {
                guard let value = try load($0.deletingPathExtension().lastPathComponent.uppercased()) else {
                    throw ResearchIncomingHandoffError.invalidReceipt
                }
                return value
            }.sorted { $0.updatedAt > $1.updatedAt }
    }
    func prepareResult(_ receipt: ResearchIncomingReceipt) throws -> URL {
        // Never include managed paths, attachment data or other library records.
        let state = receipt.state == "completed" ? "imported" : receipt.state
        let sources = receipt.request.items.map { item in
            GaoJSONValue.object(["sourceItemID": .string(item.id), "sourceSHA256": .string(item.sha256), "status": .string(state)])
        }
        let provenance: [String: GaoJSONValue] = [
            "requestManifestSHA256": .string(receipt.requestManifestSHA256),
            "workflowState": .string(state), "sources": .array(sources),
            "saved": .bool(receipt.state == "completed"),
            "importedCount": .number(Double(receipt.outcome?.importedCount ?? 0)),
            "duplicateCount": .number(Double(receipt.outcome?.duplicateCount ?? 0)),
            "receiptID": .string(receipt.receiptID)
        ]
        let manifest = GaoActionManifest(kind: "result", sourceBundleID: receipt.request.targetBundleID,
                                         targetBundleID: receipt.request.sourceBundleID, action: receipt.request.action,
                                         inReplyTo: receipt.id, status: receipt.state, provenance: provenance)
        return try GaoActionPackageWriter().write(manifest: manifest, files: [:],
                                                  outgoingRoot: root.appendingPathComponent("IncomingResults", isDirectory: true))
    }
}

@MainActor
extension DocumentLibraryStore {
    var incomingHandoffs: ResearchIncomingHandoffStore { .init(root: ResearchExchangePaths.root) }

    /// A durable journal is authoritative when the app stopped after commit but
    /// before the receiver receipt was saved. Never infer success from records alone.
    func reconcileIncomingReceipt(_ original: ResearchIncomingReceipt, journal: ResearchImportJournal) throws -> ResearchIncomingReceipt {
        guard let id = UUID(uuidString: original.id), let job = try journal.job(requestID: id) else { return original }
        guard let target = original.targetFolderID, job.items.allSatisfy({ $0.scopeID == target }) else {
            throw ResearchIncomingHandoffError.targetConflict
        }
        let declared = Dictionary(uniqueKeysWithValues: original.request.items.map { ($0.id, $0) })
        guard job.items.count == declared.count, job.items.allSatisfy({ item in
            guard let source = declared[item.id] else { return false }
            return source.sha256.lowercased() == item.sha256.lowercased() && source.byteCount == item.byteCount
                && item.provenance.sourceBundleID == original.request.sourceBundleID
        }) else { throw ResearchIncomingHandoffError.requestConflict }
        guard original.state != "cancelled" else {
            if job.stage != .cancelled { throw ResearchIncomingHandoffError.invalidReceipt }
            return original
        }
        if job.stage == .completed, let outcome = job.outcome {
            var receipt = original; receipt.state = "completed"; receipt.outcome = outcome
            try incomingHandoffs.save(receipt)
            return receipt
        }
        return original
    }

    func recoverIncomingHandoffReceipts(journal: ResearchImportJournal) throws {
        for receipt in try incomingHandoffs.recent() where !receipt.isTerminal {
            _ = try reconcileIncomingReceipt(receipt, journal: journal)
        }
    }

    /// Explicit history-page recovery uses only previously approved durable
    /// journals, and serializes with every normal business import.
    func resumeIncomingHandoffs() async throws -> [ResearchIncomingReceipt] {
        guard libraryIsWritable() else { throw ResearchDocumentImportError.unavailableLibrary }
        guard !isImportingDocuments else { throw ResearchDocumentImportError.busy }
        isImportingDocuments = true
        defer { isImportingDocuments = false }
        await recoverDocumentImportsIfNeeded()
        return try incomingHandoffs.recent().map { try incomingReceiptForResult($0.id) }
    }

    func approveIncomingDocuments(_ context: PendingPackageReviewContext, targetFolderID: String,
                                  userApproved: Bool) async throws -> ResearchIncomingReceipt {
        guard userApproved else { throw ResearchDocumentImportError.approvalRequired }
        var receipt = try incomingHandoffs.register(context.validatedPackage)
        if let bound = receipt.targetFolderID, bound != targetFolderID { throw ResearchIncomingHandoffError.targetConflict }
        let journal = try transactionJournal()
        receipt = try reconcileIncomingReceipt(receipt, journal: journal)
        if receipt.isTerminal { return receipt }
        if case .string(let target)? = receipt.request.parameters["targetRecordID"], !target.isEmpty {
            throw ResearchIncomingHandoffError.unsupportedRecordTarget
        }
        guard let folder = folders.first(where: { $0.id == targetFolderID }) else { throw ResearchDocumentImportError.invalidTarget }
        // Write intent before the journal. Any failure stays pending and resumable.
        receipt.targetFolderID = targetFolderID
        try incomingHandoffs.save(receipt)
        let outcome = try await importStagedDocuments(context.validatedPackage, into: folder)
        receipt.state = "completed"; receipt.outcome = outcome
        try incomingReceiptCompletionFailureInjector?()
        try incomingHandoffs.save(receipt)
        return receipt
    }

    func cancelIncomingDocuments(_ context: PendingPackageReviewContext) throws -> ResearchIncomingReceipt {
        let receipt = try incomingHandoffs.register(context.validatedPackage)
        return try cancelIncomingReceipt(requestID: receipt.id)
    }

    func cancelIncomingReceipt(requestID: String) throws -> ResearchIncomingReceipt {
        guard !isImportingDocuments else { throw ResearchDocumentImportError.busy }
        guard var receipt = try incomingHandoffs.load(requestID) else { throw ResearchIncomingHandoffError.invalidReceipt }
        let journal = try transactionJournal()
        receipt = try reconcileIncomingReceipt(receipt, journal: journal)
        if receipt.isTerminal { return receipt }
        if let id = UUID(uuidString: receipt.id), let job = try journal.job(requestID: id), job.stage != .cancelled {
            throw ResearchIncomingHandoffError.undecidedImport
        }
        receipt.state = "cancelled"
        try incomingHandoffs.save(receipt)
        return receipt
    }

    func incomingReceiptForResult(_ id: String) throws -> ResearchIncomingReceipt {
        guard let receipt = try incomingHandoffs.load(id) else { throw ResearchIncomingHandoffError.invalidReceipt }
        return try reconcileIncomingReceipt(receipt, journal: transactionJournal())
    }

    func prepareIncomingResult(requestID: String) throws -> URL {
        try incomingHandoffs.prepareResult(incomingReceiptForResult(requestID))
    }

    func sendIncomingResult(requestID: String) async throws {
        let receipt = try incomingReceiptForResult(requestID)
        let url = try incomingHandoffs.prepareResult(receipt)
        let bundleID = receipt.request.sourceBundleID
        guard let application = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              Bundle(url: application)?.bundleIdentifier == bundleID else {
            throw ResearchExchangeClientError.providerUnavailable("原发送方尚未安装；回执已保留，可导出后手工发送。")
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: ()) }
            }
        }
        // Transport open success never changes the persisted business outcome.
    }
}
