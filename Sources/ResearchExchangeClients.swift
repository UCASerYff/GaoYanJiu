import AppKit
import Foundation
import UniformTypeIdentifiers
import CryptoKit
import Darwin

// Outbound GaoAction adapters. All mutable state and all copies belong to this
// application's Exchange directory; provider claims never grant file access.
enum ResearchExternalAction: String, Codable, CaseIterable {
    case chooseFiles = "files.choose"
    case ocrFiles = "ocr.files"
    case openDocument = "documents.open"

    var providerBundleID: String {
        switch self {
        case .chooseFiles: return "com.gaoseries.GaoZhengLi"
        case .ocrFiles: return "com.gaoseries.GaoJieTu"
        case .openDocument: return "com.gaoseries.GaoWenJian"
        }
    }
}

struct ResearchProviderAvailability {
    var isAvailable: Bool
    var reason: String
    var applicationURL: URL?
}

struct ResearchExchangeSourceFile {
    var url: URL
    var documentID: String?
    init(url: URL, documentID: String? = nil) {
        self.url = url; self.documentID = documentID
    }
}

struct ResearchExchangeSourceBinding: Codable, Equatable {
    var itemID: String
    var documentID: String?
    var originalFileURL: String
    var sha256: String
    var byteCount: Int64
    var identity: GaoActionDeclaredIdentity
    var documentVersion: Date?
}

struct ResearchExchangeSession: Codable {
    var requestID: String
    var providerBundleID: String
    var action: ResearchExternalAction
    var requestNonce: String
    var packageURL: String
    var createdAt: Date
    var sources: [ResearchExchangeSourceBinding]
    var state: String
    var resultIDs: [String]
    var importedEditedSHA256: String?
    var resultManifestSHA256: [String: String]? = nil
    // Local routing intent, never an instruction sent to the provider. Missing
    // fields in sessions from older releases require an explicit folder choice.
    var targetFolderID: String? = nil
    var sourceScope: GaoActionReference? = nil
    var appliedResults: [String: ResearchResultApplicationReceipt]? = nil
    var resultStatuses: [String: String]? = nil
    var selectionIntentVersion: Int? = nil
    // A pending intent binds a verified envelope to one durable job. It is not
    // an applied receipt and never implies that records have been committed.
    var resultIntents: [String: ResearchResultIntentBinding]? = nil
}

struct ResearchResultIntentBinding: Codable, Equatable {
    var manifestSHA256: String
    var jobID: String
    // Full semantic basis digest, not a payload-only duplicate heuristic.
    // Missing in older sessions; never infer it from partial journal fields.
    var semanticFingerprintV2: String? = nil
}

struct ResearchResultApplicationReceipt: Codable, Equatable {
    var resultID: String
    var manifestSHA256: String
    var importedDocumentIDs: [String]
    var receiptID: String
    var appliedAt: Date
}

struct ResearchPreparedExchange {
    var packageURL: URL
    var requestID: String
    var action: ResearchExternalAction
    var parameters: [String: GaoJSONValue]
}

struct ResearchOCRPage {
    var pageNumber: Int
    var status: String
    var confidence: Double?
    var regions: [[String: GaoJSONValue]]
    var text: String? = nil
    var coordinateSpace: String? = nil
}

struct ResearchOCROutput {
    var itemID: String
    var sourceItemID: String
    var sourceSHA256: String
    var sourceDocumentID: String?
    var engine: String?
    var engineVersion: String?
    var languages: [String]
    var pages: [ResearchOCRPage]
    var metadataComplete: Bool
    var warnings: [String]
    // These values describe the receiver's verified copy, never a sender path.
    var localCopy: URL
    var uti: String
    var byteCount: Int64
    var sha256: String
    var engineRevision: Int? = nil
}

struct ResearchVerifiedSelection {
    var referenceID: String
    var localCopy: URL
    var sha256: String
    var byteCount: Int64
    var originalReference: GaoActionReference
}

struct ResearchValidatedExternalResult {
    var package: GaoValidatedActionPackage
    var session: ResearchExchangeSession
    var ocrOutputs: [ResearchOCROutput]
    var selectedReferences: [GaoActionReference]
    var workflowState: String
    var duplicate: Bool
    var businessApplied: Bool = false
    // A matching bundle ID and nonce are declarations, not authentication.
    let sourceIsAuthenticated = false
}

enum ResearchEditedCopyMode: String, Codable { case newVersion, newAttachment }

struct ResearchEditedCopyImport {
    var requestID: String
    var originalDocumentID: String
    var originalSHA256: String
    var originalVersion: Date
    var localCopy: URL
    var editedSHA256: String
    var byteCount: Int64
    var mode: ResearchEditedCopyMode
}

enum ResearchExchangeClientError: LocalizedError, Equatable {
    case invalidCapability, providerUnavailable(String), invalidParameters
    case invalidSelection, requiresLocalSelection, sourceChanged
    case invalidSession, resultMismatch, invalidOCRMapping, invalidOCRCompletion
    case invalidEditResult, requestExpired, tooManyItems, alreadyImported, requiresTargetReview

    var errorDescription: String? {
        switch self {
        case .invalidCapability: return "提供方能力表缺失、版本不匹配或参数 schema 不兼容。可导出交接包。"
        case .providerUnavailable(let reason): return reason
        case .invalidParameters: return "交接参数不受支持；请减少选项或更新提供方。"
        case .invalidSelection: return "仅支持本次明确选择的普通文件，无法处理目录、链接或不可读文件。"
        case .requiresLocalSelection: return "外部引用未授予访问权限或身份信息不完整，请在本应用重新选择该文件。"
        case .sourceChanged: return "文件身份、内容摘要或原版本已经改变，请重新核对原件。"
        case .invalidSession: return "找不到有效的本地交接记录；不会导入或覆盖原件。"
        case .resultMismatch: return "结果与待处理请求的目标、动作、来源声明或输入摘要不匹配。"
        case .invalidOCRMapping: return "OCR 结果无法明确关联原件，或页码、坐标信息无效。请核对原件。"
        case .invalidOCRCompletion: return "OCR 含失败、取消或低置信度页，不能标记为全部完成。"
        case .invalidEditResult: return "外部编辑结果只能说明文档已打开。请重新选择保存的编辑副本后导入。"
        case .requestExpired: return "交接包已过期，请重新发起；原附件保留。"
        case .tooManyItems: return "每批最多 256 个文件、总量最多 2 GiB；请分批或另选文件。"
        case .alreadyImported: return "该编辑副本已导入，请勿重复提交。"
        case .requiresTargetReview: return "原目标资料文件夹未记录或已失效，请明确选择本次导入位置。"
        }
    }
}

final class ResearchExchangeClient {
    let exchangeRoot: URL
    let researchBundleID: String
    private let providerLookup: (String) -> URL?
    private let clock: () -> Date
    private let fileManager = FileManager.default
    private let maximumBytes: Int64 = 2 * 1024 * 1024 * 1024
    // PaperStore may create multiple lightweight client instances. Serialize
    // their local read/modify/write cycles so approval receipts cannot be lost.
    private static let sessionMutationLock = NSRecursiveLock()

    init(exchangeRoot: URL, researchBundleID: String,
         providerLookup: @escaping (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) },
         clock: @escaping () -> Date = Date.init) {
        self.exchangeRoot = exchangeRoot.standardizedFileURL
        self.researchBundleID = researchBundleID
        self.providerLookup = providerLookup
        self.clock = clock
    }

    func availability(for action: ResearchExternalAction,
                      parameters: [String: GaoJSONValue] = [:]) -> ResearchProviderAvailability {
        guard let application = providerLookup(action.providerBundleID) else {
            return .init(isAvailable: false, reason: "提供方尚未安装，可导出私有交接包并在 Finder 显示。", applicationURL: nil)
        }
        do {
            try validateParameters(parameters, action: action)
            try validateProvider(application, action: action, parameters: parameters)
            return .init(isAvailable: true, reason: "能力表兼容；发送后仍需在提供方确认。", applicationURL: application)
        } catch {
            return .init(isAvailable: false, reason: "提供方能力表不兼容，可导出私有交接包；不会自动下载。", applicationURL: application)
        }
    }

    func prepareFileSelection(allowedUTIs: [String] = [], multiple: Bool = true,
                              targetFolderID: String? = nil, sourceScope: GaoActionReference? = nil) throws -> ResearchPreparedExchange {
        if let targetFolderID, targetFolderID.isEmpty || targetFolderID.utf8.count > 256 { throw ResearchExchangeClientError.invalidSelection }
        if let sourceScope {
            guard sourceScope.kind == "directory" else { throw ResearchExchangeClientError.invalidSelection }
        }
        // Different extensions may resolve to the same UTI (jpg/jpeg,
        // tif/tiff, yaml/yml, md/markdown). The provider requires unique values.
        let normalizedUTIs = Array(Set(allowedUTIs)).sorted()
        guard normalizedUTIs.count <= 64, allowedUTIs.allSatisfy(Self.validSelectionUTI) else {
            throw ResearchExchangeClientError.invalidParameters
        }
        var parameters: [String: GaoJSONValue] = ["multiple": .bool(multiple)]
        if !normalizedUTIs.isEmpty { parameters["allowedUTIs"] = .array(normalizedUTIs.map(GaoJSONValue.string)) }
        return try prepare(action: .chooseFiles, files: [], parameters: parameters, documentVersion: nil,
                           targetFolderID: targetFolderID, sourceScope: sourceScope)
    }

    func prepareOCR(userSelectedFiles: [ResearchExchangeSourceFile], languages: [String] = [],
                    outputs: [String] = []) throws -> ResearchPreparedExchange {
        guard !userSelectedFiles.isEmpty else { throw ResearchExchangeClientError.invalidSelection }
        for file in userSelectedFiles {
            guard let type = UTType(filenameExtension: file.url.pathExtension),
                  type.conforms(to: .pdf) || type.conforms(to: .image) else {
                throw ResearchExchangeClientError.invalidSelection
            }
        }
        var parameters: [String: GaoJSONValue] = [:]
        if !languages.isEmpty { parameters["languages"] = .array(languages.map(GaoJSONValue.string)) }
        if !outputs.isEmpty { parameters["outputs"] = .array(outputs.map(GaoJSONValue.string)) }
        return try prepare(action: .ocrFiles, files: userSelectedFiles, parameters: parameters, documentVersion: nil)
    }

    func prepareExternalEdit(documentID: String, originalURL: URL,
                             originalVersion: Date) throws -> ResearchPreparedExchange {
        guard !documentID.isEmpty else { throw ResearchExchangeClientError.invalidSelection }
        return try prepare(action: .openDocument,
                           files: [.init(url: originalURL, documentID: documentID)], parameters: [:],
                           documentVersion: originalVersion)
    }

    @MainActor
    func openInProvider(_ prepared: ResearchPreparedExchange) async throws {
        let session = try loadSession(prepared.requestID)
        let manifest = try loadManifest(prepared.packageURL)
        guard manifest.requestID == session.requestID, manifest.nonce == session.requestNonce,
              manifest.targetBundleID == session.providerBundleID, manifest.action == session.action.rawValue,
              session.action == prepared.action,
              manifest.parameters == prepared.parameters,
              session.packageURL == prepared.packageURL.absoluteString else { throw ResearchExchangeClientError.invalidSession }
        guard let expiry = Self.isoDate(manifest.expiresAt), expiry >= clock() else { throw ResearchExchangeClientError.requestExpired }
        let provider = availability(for: prepared.action, parameters: prepared.parameters)
        guard provider.isAvailable, let application = provider.applicationURL else {
            throw ResearchExchangeClientError.providerUnavailable(provider.reason)
        }
        // Explicit application URL prevents a .gaoaction default-handler hijack.
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            NSWorkspace.shared.open([prepared.packageURL], withApplicationAt: application,
                                    configuration: NSWorkspace.OpenConfiguration()) { _, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: ()) }
            }
        }
        try markSessionOpened(prepared.requestID)
    }

    @MainActor
    func revealFallback(_ prepared: ResearchPreparedExchange) {
        NSWorkspace.shared.activateFileViewerSelecting([prepared.packageURL])
    }

    /// Destination must come from the user's Save panel. Retains private modes.
    func exportFallback(_ prepared: ResearchPreparedExchange, to destination: URL) throws {
        guard destination.isFileURL, destination.pathExtension.lowercased() == "gaoaction",
              !fileManager.fileExists(atPath: destination.path) else { throw ResearchExchangeClientError.invalidSelection }
        let session = try loadSession(prepared.requestID)
        guard session.packageURL == prepared.packageURL.absoluteString else { throw ResearchExchangeClientError.invalidSession }
        try fileManager.copyItem(at: prepared.packageURL, to: destination)
        try privateDirectory(destination)
        if let entries = fileManager.enumerator(at: destination, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let entry as URL in entries {
                let values = try entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw ResearchExchangeClientError.invalidSelection }
                try fileManager.setAttributes([.posixPermissions: values.isDirectory == true ? 0o700 : 0o600], ofItemAtPath: entry.path)
            }
        }
    }

    func receiveResult(at packageURL: URL) throws -> ResearchValidatedExternalResult {
        Self.sessionMutationLock.lock()
        defer { Self.sessionMutationLock.unlock() }
        try ensureExchange()
        let package = try GaoActionPackageValidator(expectedTargetBundleID: researchBundleID, now: clock())
            .stagePackage(at: packageURL, stagingRoot: exchangeRoot.appendingPathComponent("Incoming", isDirectory: true))
        let manifest = package.manifest
        guard manifest.kind == "result", let reply = manifest.inReplyTo else { throw ResearchExchangeClientError.resultMismatch }
        var session = try loadSession(reply)
        guard manifest.sourceBundleID == session.providerBundleID,
              manifest.targetBundleID == researchBundleID, manifest.action == session.action.rawValue,
              manifest.requestID != session.requestID else { throw ResearchExchangeClientError.resultMismatch }
        var ocr: [ResearchOCROutput] = []
        var references: [GaoActionReference] = []
        var workflow = manifest.status ?? "failed"
        switch session.action {
        case .chooseFiles:
            guard manifest.references.allSatisfy({ $0.kind == "file" }) else { throw ResearchExchangeClientError.invalidSelection }
            guard manifest.references.count + manifest.items.count <= 256 else { throw ResearchExchangeClientError.tooManyItems }
            references = manifest.references
        case .ocrFiles:
            try validateCurrentSources(session)
            ocr = try validateOCR(package, session: session)
            if ["completed", "partial"].contains(manifest.status ?? ""), ocr.contains(where: { !$0.metadataComplete }) { workflow = "needsReview" }
        case .openDocument:
            guard manifest.items.isEmpty, manifest.references.isEmpty else { throw ResearchExchangeClientError.invalidEditResult }
            let reported = manifest.provenance?["workflowState"]?.researchString
            let allowed: [String: Set<String>] = ["completed": ["opened"], "partial": ["partial", "opened"],
                                                  "pending": ["pending", "awaitingUser"], "cancelled": ["cancelled"],
                                                  "failed": ["failed"], "unsupported": ["unsupported"]]
            let status = manifest.status ?? "failed"
            guard manifest.provenance?["saved"]?.researchBool != true,
                  allowed[status]?.contains(reported ?? status) == true else { throw ResearchExchangeClientError.invalidEditResult }
            if let value = manifest.provenance?["openedItemIDs"] {
                guard let opened = value.researchStrings, Set(opened).count == opened.count,
                      Set(opened).isSubset(of: Set(session.sources.map(\.itemID))) else { throw ResearchExchangeClientError.resultMismatch }
            }
            workflow = reported ?? status
        }
        let duplicate = session.resultIDs.contains(manifest.requestID)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let manifestSHA = SHA256.hash(data: try encoder.encode(manifest)).map { String(format: "%02x", $0) }.joined()
        if let previous = session.resultManifestSHA256?[manifest.requestID], previous != manifestSHA {
            throw ResearchExchangeClientError.resultMismatch
        }
        if let intent = session.resultIntents?[manifest.requestID], intent.manifestSHA256 != manifestSHA {
            throw ResearchExchangeClientError.resultMismatch
        }
        if !duplicate || session.resultManifestSHA256?[manifest.requestID] == nil || session.resultStatuses?[manifest.requestID] == nil {
            if !duplicate { session.resultIDs.append(manifest.requestID) }
            if session.resultManifestSHA256 == nil { session.resultManifestSHA256 = [:] }
            session.resultManifestSHA256?[manifest.requestID] = manifestSHA
            if session.resultStatuses == nil { session.resultStatuses = [:] }
            session.resultStatuses?[manifest.requestID] = manifest.status
            session.state = workflow
            try saveSession(session)
        }
        let applied = session.appliedResults?[manifest.requestID]
        if let applied, applied.manifestSHA256 != manifestSHA { throw ResearchExchangeClientError.resultMismatch }
        return .init(package: package, session: session, ocrOutputs: ocr,
                     selectedReferences: references, workflowState: workflow, duplicate: duplicate,
                     businessApplied: applied != nil)
    }

    /// Providers may refresh a result's 120-second envelope with a new UUID.
    /// Its business intent is unchanged when input bindings, target, verified
    /// payload, status and provenance are unchanged. Identity/nonce claims are
    /// still not authentication. This digest never grants approval or access.
    func semanticResultFingerprint(_ result: ResearchValidatedExternalResult, targetScope: String,
                                   verifiedSelections: [ResearchVerifiedSelection] = []) throws -> String {
        try semanticFingerprint(manifest: result.package.manifest, session: result.session,
                                references: result.selectedReferences, targetScope: targetScope,
                                verifiedSelections: verifiedSelections, normalizeOCRTransportPaths: false)
    }

    /// V2 changes only OCR transport names. Type, extension, stable item IDs,
    /// all payload evidence and complete remaining provenance stay bound.
    /// File-selection filenames retain the original V1 semantics.
    func semanticResultFingerprintV2(_ result: ResearchValidatedExternalResult, targetScope: String,
                                     verifiedSelections: [ResearchVerifiedSelection] = []) throws -> String {
        try semanticFingerprint(manifest: result.package.manifest, session: result.session,
                                references: result.selectedReferences, targetScope: targetScope,
                                verifiedSelections: verifiedSelections, normalizeOCRTransportPaths: true)
    }

    private func semanticFingerprint(manifest original: GaoActionManifest, session: ResearchExchangeSession,
                                     references: [GaoActionReference], targetScope: String,
                                     verifiedSelections: [ResearchVerifiedSelection],
                                     normalizeOCRTransportPaths: Bool) throws -> String {
        var manifest = original
        guard manifest.kind == "result", manifest.inReplyTo == session.requestID,
              manifest.action == session.action.rawValue, manifest.sourceBundleID == session.providerBundleID,
              manifest.targetBundleID == researchBundleID else { throw ResearchExchangeClientError.resultMismatch }
        guard Set(verifiedSelections.map(\.referenceID)) == Set(references.map(\.id)),
              verifiedSelections.count == references.count else { throw ResearchExchangeClientError.invalidSelection }
        manifest.requestID = "00000000-0000-4000-8000-000000000000"
        manifest.createdAt = ""; manifest.expiresAt = ""; manifest.nonce = ""
        manifest.items.sort { $0.id < $1.id }; manifest.references.sort { $0.id < $1.id }
        if normalizeOCRTransportPaths && session.action == .ocrFiles {
            for index in manifest.items.indices {
                let ext = (manifest.items[index].relativePath as NSString).pathExtension.lowercased()
                manifest.items[index].relativePath = "payload/output-\(index)" + (ext.isEmpty ? "" : "." + ext)
            }
        }
        if var provenance = manifest.provenance {
            for key in ["outputs", "sources", "pages"] {
                guard let values = provenance[key]?.researchArray else { continue }
                provenance[key] = .array(values.map { value in
                    guard var object = value.researchObject else { return value }
                    if let outputs = object["outputItemIDs"]?.researchStrings {
                        object["outputItemIDs"] = .array(outputs.sorted().map(GaoJSONValue.string))
                    }
                    if let pages = object["pages"]?.researchArray {
                        object["pages"] = .array(pages.sorted { ($0.researchObject?["pageNumber"]?.researchNumber ?? 0) < ($1.researchObject?["pageNumber"]?.researchNumber ?? 0) })
                    }
                    return .object(object)
                }.sorted { left, right in
                    if key == "pages" { return (left.researchObject?["pageNumber"]?.researchNumber ?? 0) < (right.researchObject?["pageNumber"]?.researchNumber ?? 0) }
                    let a = left.researchObject ?? [:], b = right.researchObject ?? [:]
                    return (a["resultItemID"]?.researchString ?? a["itemID"]?.researchString ?? a["sourceItemID"]?.researchString ?? "")
                        < (b["resultItemID"]?.researchString ?? b["itemID"]?.researchString ?? b["sourceItemID"]?.researchString ?? "")
                })
            }
            manifest.provenance = provenance
        }
        struct Intent: Encodable {
            struct VerifiedReference: Encodable {
                var id: String
                var sha256: String
                var byteCount: Int64
                var fileExtension: String
            }
            var format = 1
            var manifest: GaoActionManifest
            var requestID: String
            var sources: [ResearchExchangeSourceBinding]
            var targetScope: String
            var verifiedReferences: [VerifiedReference]
        }
        let intent = Intent(manifest: manifest, requestID: session.requestID,
                            sources: session.sources.sorted { $0.itemID < $1.itemID }, targetScope: targetScope,
                            verifiedReferences: verifiedSelections.sorted { $0.referenceID < $1.referenceID }.map {
            .init(id: $0.referenceID, sha256: $0.sha256.lowercased(), byteCount: $0.byteCount,
                  fileExtension: $0.localCopy.pathExtension.lowercased())
        })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return SHA256.hash(data: try encoder.encode(intent)).map { String(format: "%02x", $0) }.joined()
    }

    /// Comparison evidence only: this never validates an expired envelope for
    /// execution, grants file access, applies a result or rewrites its TTL.
    /// The full historical manifest must match BOTH prior receiver bindings,
    /// and the untouched V1 basis must reproduce the existing journal UUID.
    func historicalOCRSemanticFingerprintV2(requestID: String, historicalManifest manifest: GaoActionManifest,
                                            targetScope: String) throws -> String {
        Self.sessionMutationLock.lock()
        defer { Self.sessionMutationLock.unlock() }
        let session = try loadSession(requestID)
        guard session.action == .ocrFiles, manifest.schemaVersion == 1, manifest.kind == "result",
              manifest.inReplyTo == requestID, manifest.requestID != requestID,
              manifest.action == session.action.rawValue, manifest.sourceBundleID == session.providerBundleID,
              manifest.targetBundleID == researchBundleID, manifest.references.isEmpty,
              session.resultIDs.contains(manifest.requestID),
              let status = manifest.status, ["completed", "partial"].contains(status),
              session.resultStatuses?[manifest.requestID] == status,
              let intent = session.resultIntents?[manifest.requestID],
              let jobID = UUID(uuidString: intent.jobID),
              let digest = session.resultManifestSHA256?[manifest.requestID] else {
            throw ResearchExchangeClientError.resultMismatch
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let fullDigest = SHA256.hash(data: try encoder.encode(manifest)).map { String(format: "%02x", $0) }.joined()
        guard digest == fullDigest, intent.manifestSHA256 == fullDigest else { throw ResearchExchangeClientError.resultMismatch }
        let legacy = try semanticFingerprint(manifest: manifest, session: session, references: [], targetScope: targetScope,
                                              verifiedSelections: [], normalizeOCRTransportPaths: false)
        var bytes = Array(SHA256.hash(data: Data(("exchange-result-v1:" + legacy).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        let reproduced = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                                     bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        guard reproduced == jobID else { throw ResearchExchangeClientError.resultMismatch }
        // Keep this client independent of the journal implementation, but do
        // require the owned, no-follow actual job file with that same UUID.
        struct JobIdentity: Decodable { var requestID: UUID }
        let jobURL = exchangeRoot.appendingPathComponent("Metadata/ImportJobs/" + jobID.uuidString.lowercased() + ".json")
        let jobData = try GaoActionFileAccess.readPrivateData(at: jobURL, maximumBytes: 128 * 1_048_576)
        guard try JSONDecoder().decode(JobIdentity.self, from: jobData).requestID == jobID else {
            throw ResearchExchangeClientError.resultMismatch
        }
        return try semanticFingerprint(manifest: manifest, session: session, references: [], targetScope: targetScope,
                                        verifiedSelections: [], normalizeOCRTransportPaths: true)
    }

    /// Receiving a result is not a business commit. Only call this after the
    /// import journal has durably committed all IDs covered by this receipt.
    @discardableResult
    func markResultApplied(requestID: String, resultID: String, importedDocumentIDs: [String],
                           receiptID: String) throws -> ResearchResultApplicationReceipt {
        Self.sessionMutationLock.lock()
        defer { Self.sessionMutationLock.unlock() }
        var session = try loadSession(requestID)
        guard session.action != .openDocument, session.resultIDs.contains(resultID), let digest = session.resultManifestSHA256?[resultID],
              ["completed", "partial"].contains(session.resultStatuses?[resultID] ?? ""),
              !receiptID.isEmpty, receiptID.utf8.count <= 256,
              !importedDocumentIDs.isEmpty, importedDocumentIDs.count <= 256,
              Set(importedDocumentIDs).count == importedDocumentIDs.count,
              importedDocumentIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else { throw ResearchExchangeClientError.invalidSession }
        if let intent = session.resultIntents?[resultID] {
            guard intent.manifestSHA256 == digest, intent.jobID == receiptID else { throw ResearchExchangeClientError.resultMismatch }
        }
        if let existing = session.appliedResults?[resultID] {
            guard existing.manifestSHA256 == digest, existing.receiptID == receiptID,
                  existing.importedDocumentIDs == importedDocumentIDs else { throw ResearchExchangeClientError.resultMismatch }
            return existing
        }
        let receipt = ResearchResultApplicationReceipt(resultID: resultID, manifestSHA256: digest,
                                                       importedDocumentIDs: importedDocumentIDs, receiptID: receiptID, appliedAt: clock())
        if session.appliedResults == nil { session.appliedResults = [:] }
        session.appliedResults?[resultID] = receipt
        // A later partial/failed result remains resumable; per-result receipts
        // decide idempotency rather than a global "completed" session state.
        try saveSession(session)
        return receipt
    }

    /// Persist before journal submission so a retry cannot rebind the same
    /// verified envelope after its referenced file changes. Not business done.
    func recordResultIntent(requestID: String, resultID: String, jobID: UUID, semanticFingerprintV2: String? = nil) throws {
        Self.sessionMutationLock.lock()
        defer { Self.sessionMutationLock.unlock() }
        var session = try loadSession(requestID)
        guard session.action != .openDocument, session.resultIDs.contains(resultID),
              let digest = session.resultManifestSHA256?[resultID],
              ["completed", "partial"].contains(session.resultStatuses?[resultID] ?? "") else { throw ResearchExchangeClientError.invalidSession }
        if let semanticFingerprintV2 {
            guard session.action == .ocrFiles,
                  semanticFingerprintV2.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw ResearchExchangeClientError.resultMismatch
            }
        }
        let binding = ResearchResultIntentBinding(manifestSHA256: digest, jobID: jobID.uuidString,
                                                  semanticFingerprintV2: semanticFingerprintV2)
        if let existing = session.resultIntents?[resultID] {
            guard existing.manifestSHA256 == binding.manifestSHA256, existing.jobID == binding.jobID,
                  existing.semanticFingerprintV2 == nil || semanticFingerprintV2 == nil
                    || existing.semanticFingerprintV2 == semanticFingerprintV2 else { throw ResearchExchangeClientError.resultMismatch }
            if existing.semanticFingerprintV2 != nil || semanticFingerprintV2 == nil { return }
        }
        if let receipt = session.appliedResults?[resultID] {
            guard receipt.manifestSHA256 == digest, receipt.receiptID == binding.jobID else { throw ResearchExchangeClientError.resultMismatch }
        }
        if session.resultIntents == nil { session.resultIntents = [:] }
        session.resultIntents?[resultID] = binding
        try saveSession(session)
    }

    func resolveFileSelectionTarget(requestID: String, existingFolderIDs: Set<String>,
                                     userConfirmedFolderID: String? = nil) throws -> String {
        Self.sessionMutationLock.lock()
        defer { Self.sessionMutationLock.unlock() }
        var session = try loadSession(requestID)
        guard session.action == .chooseFiles else { throw ResearchExchangeClientError.invalidSession }
        if let confirmed = userConfirmedFolderID {
            guard !confirmed.isEmpty, confirmed.utf8.count <= 256, existingFolderIDs.contains(confirmed) else { throw ResearchExchangeClientError.requiresTargetReview }
            session.targetFolderID = confirmed
            session.selectionIntentVersion = 1
            try saveSession(session)
            return confirmed
        }
        guard session.selectionIntentVersion == 1, let target = session.targetFolderID,
              existingFolderIDs.contains(target) else { throw ResearchExchangeClientError.requiresTargetReview }
        return target
    }

    /// References grant neither permission nor identity. Re-select with this app's
    /// Open panel when identity is incomplete or this process cannot read it.
    func verifySelectedReference(_ reference: GaoActionReference,
                                 userSelectedURL: URL? = nil, maximumBytes: Int64? = nil) throws -> ResearchVerifiedSelection {
        let allowedBytes = min(self.maximumBytes, maximumBytes ?? self.maximumBytes)
        guard allowedBytes >= 0 else { throw ResearchExchangeClientError.tooManyItems }
        guard reference.kind == "file", let declared = URL(string: reference.fileURL), declared.isFileURL,
              declared.host == nil || declared.host == "" || declared.host == "localhost" else {
            throw ResearchExchangeClientError.invalidSelection
        }
        let source = userSelectedURL ?? declared
        guard source.isFileURL else { throw ResearchExchangeClientError.invalidSelection }
        if let selected = userSelectedURL, selected.standardizedFileURL != declared.standardizedFileURL,
           reference.sha256 == nil { throw ResearchExchangeClientError.sourceChanged }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        let fingerprint: GaoActionFileFingerprint
        do { fingerprint = try GaoActionFileAccess.fingerprint(at: source) }
        catch { throw ResearchExchangeClientError.requiresLocalSelection }
        try compareDeclared(reference, actual: fingerprint)
        let identity = reference.declaredIdentity
        let identified = identity.device != nil && identity.inode != nil && identity.byteCount != nil && identity.modifiedAt != nil
        guard identified || reference.sha256 != nil || userSelectedURL != nil else { throw ResearchExchangeClientError.requiresLocalSelection }
        guard fingerprint.byteCount <= allowedBytes else { throw ResearchExchangeClientError.tooManyItems }
        try ensureExchange()
        let directory = exchangeRoot.appendingPathComponent("Selections/\(UUID().uuidString)", isDirectory: true)
        try privateDirectory(directory)
        let ext = source.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("selected\(ext.isEmpty ? "" : "." + ext)")
        let copied = try GaoActionFileAccess.copyRegularFile(at: source, to: destination, maximumBytes: allowedBytes)
        guard copied.sha256 == fingerprint.sha256, copied.byteCount == fingerprint.byteCount else { throw ResearchExchangeClientError.sourceChanged }
        return .init(referenceID: reference.id, localCopy: destination, sha256: copied.sha256,
                     byteCount: copied.byteCount, originalReference: reference)
    }

    /// Selection and mode are supplied after the user's explicit import choice.
    /// No live attachment is replaced here; the import journal owns commit/snapshot.
    func prepareEditedCopyImport(requestID: String, currentDocumentID: String,
                                 currentOriginalURL: URL, currentVersion: Date,
                                 userSelectedEditedCopy: URL, mode: ResearchEditedCopyMode) throws -> ResearchEditedCopyImport {
        let session = try loadSession(requestID)
        guard session.action == .openDocument, let original = session.sources.first,
              original.documentID == currentDocumentID,
              original.documentVersion.map({ floor($0.timeIntervalSince1970) }) == floor(currentVersion.timeIntervalSince1970),
              original.originalFileURL == currentOriginalURL.standardizedFileURL.absoluteString else {
            throw ResearchExchangeClientError.sourceChanged
        }
        let current = try GaoActionFileAccess.fingerprint(at: currentOriginalURL)
        guard current.sha256 == original.sha256, current.byteCount == original.byteCount else { throw ResearchExchangeClientError.sourceChanged }
        try compareDeclared(.init(kind: "file", fileURL: original.originalFileURL,
                                  displayName: "原附件", declaredIdentity: original.identity, sha256: original.sha256), actual: current)
        guard userSelectedEditedCopy.standardizedFileURL != currentOriginalURL.standardizedFileURL else { throw ResearchExchangeClientError.invalidSelection }
        let scoped = userSelectedEditedCopy.startAccessingSecurityScopedResource()
        defer { if scoped { userSelectedEditedCopy.stopAccessingSecurityScopedResource() } }
        let selected = try GaoActionFileAccess.fingerprint(at: userSelectedEditedCopy)
        guard mode == .newAttachment || selected.sha256 != original.sha256 else { throw ResearchExchangeClientError.sourceChanged }
        guard selected.sha256 != session.importedEditedSHA256 else { throw ResearchExchangeClientError.alreadyImported }
        let directory = exchangeRoot.appendingPathComponent("EditedCopies/\(UUID().uuidString)", isDirectory: true)
        try privateDirectory(directory)
        let ext = userSelectedEditedCopy.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("edited\(ext.isEmpty ? "" : "." + ext)")
        let copied = try GaoActionFileAccess.copyRegularFile(at: userSelectedEditedCopy, to: destination, maximumBytes: maximumBytes)
        guard copied.sha256 == selected.sha256 else { throw ResearchExchangeClientError.sourceChanged }
        return .init(requestID: requestID, originalDocumentID: currentDocumentID,
                     originalSHA256: original.sha256, originalVersion: currentVersion,
                     localCopy: destination, editedSHA256: copied.sha256, byteCount: copied.byteCount, mode: mode)
    }

    /// Call only after the journal has durably committed the imported copy.
    func markEditedCopyImported(_ imported: ResearchEditedCopyImport) throws {
        Self.sessionMutationLock.lock()
        defer { Self.sessionMutationLock.unlock() }
        var session = try loadSession(imported.requestID)
        guard session.action == .openDocument, session.sources.first?.documentID == imported.originalDocumentID,
              session.sources.first?.sha256 == imported.originalSHA256 else { throw ResearchExchangeClientError.invalidSession }
        session.importedEditedSHA256 = imported.editedSHA256
        session.state = "imported"
        try saveSession(session)
    }

    func loadSession(_ requestID: String) throws -> ResearchExchangeSession {
        guard UUID(uuidString: requestID) != nil else { throw ResearchExchangeClientError.invalidSession }
        let url = sessionURL(requestID)
        let data = try GaoActionFileAccess.readPrivateData(at: url)
        guard data.count <= 1_048_576 else { throw ResearchExchangeClientError.invalidSession }
        let session = try JSONDecoder().decode(ResearchExchangeSession.self, from: data)
        guard session.requestID == requestID, session.sources.count <= 256 else { throw ResearchExchangeClientError.invalidSession }
        return session
    }

    /// Read-only session list for explicit resume/import choices in this app.
    func recentSessions(limit: Int = 20) throws -> [ResearchExchangeSession] {
        guard limit > 0 else { return [] }
        let directory = exchangeRoot.appendingPathComponent("Sessions", isDirectory: true)
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ResearchExchangeClientError.invalidSession }
        let urls = try fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        guard urls.count <= 10_000 else { throw ResearchExchangeClientError.invalidSession }
        return try urls.map { try loadSession($0.deletingPathExtension().lastPathComponent) }
            .sorted { $0.createdAt > $1.createdAt }.prefix(min(limit, 100)).map { $0 }
    }

    private func prepare(action: ResearchExternalAction, files: [ResearchExchangeSourceFile],
                         parameters: [String: GaoJSONValue], documentVersion: Date?,
                         targetFolderID: String? = nil, sourceScope: GaoActionReference? = nil) throws -> ResearchPreparedExchange {
        try validateParameters(parameters, action: action)
        guard files.count <= 256 else { throw ResearchExchangeClientError.tooManyItems }
        try ensureExchange()
        let requestID = UUID().uuidString
        var items: [GaoActionItem] = []
        var bindings: [ResearchExchangeSourceBinding] = []
        var sourceFiles: [String: URL] = [:]
        var scopedSources: [URL] = []
        defer { for url in scopedSources { url.stopAccessingSecurityScopedResource() } }
        var total: Int64 = 0
        for file in files {
            if file.url.startAccessingSecurityScopedResource() { scopedSources.append(file.url) }
            let snapshot = try GaoActionFileAccess.fingerprint(at: file.url)
            guard snapshot.byteCount <= maximumBytes - total else { throw ResearchExchangeClientError.tooManyItems }
            total += snapshot.byteCount
            let itemID = UUID().uuidString
            let ext = file.url.pathExtension.lowercased()
            let uti = UTType(filenameExtension: ext)?.identifier ?? "public.data"
            items.append(.init(id: itemID, relativePath: "payload/\(itemID)\(ext.isEmpty ? "" : "." + ext)",
                               uti: uti, byteCount: snapshot.byteCount, sha256: snapshot.sha256))
            bindings.append(.init(itemID: itemID, documentID: file.documentID,
                                  originalFileURL: file.url.standardizedFileURL.absoluteString,
                                  sha256: snapshot.sha256, byteCount: snapshot.byteCount,
                                  identity: snapshot.identity, documentVersion: documentVersion))
            sourceFiles[itemID] = file.url
        }
        let manifest = GaoActionManifest(kind: "request", requestID: requestID,
                                         sourceBundleID: researchBundleID, targetBundleID: action.providerBundleID,
                                         action: action.rawValue, createdAt: Self.isoString(clock()),
                                         expiresAt: Self.isoString(clock().addingTimeInterval(120)), nonce: "",
                                         items: items, references: sourceScope.map { [$0] } ?? [], parameters: parameters)
        let package = try GaoActionPackageWriter().write(manifest: manifest, files: sourceFiles,
                                                      outgoingRoot: exchangeRoot.appendingPathComponent("Outgoing", isDirectory: true))
        let written = try loadManifest(package)
        for binding in bindings {
            guard written.items.contains(where: { $0.id == binding.itemID && $0.sha256 == binding.sha256 && $0.byteCount == binding.byteCount }) else {
                throw ResearchExchangeClientError.sourceChanged
            }
        }
        try saveSession(.init(requestID: requestID, providerBundleID: action.providerBundleID, action: action,
                              requestNonce: written.nonce, packageURL: package.absoluteString, createdAt: clock(),
                              sources: bindings, state: "prepared", resultIDs: [], importedEditedSHA256: nil,
                              targetFolderID: targetFolderID, sourceScope: sourceScope,
                              selectionIntentVersion: action == .chooseFiles ? 1 : nil))
        return .init(packageURL: package, requestID: requestID, action: action, parameters: parameters)
    }

    private func validateParameters(_ parameters: [String: GaoJSONValue], action: ResearchExternalAction) throws {
        let allowed: Set<String>
        switch action {
        case .chooseFiles:
            allowed = ["allowedUTIs", "multiple"]
            if let value = parameters["multiple"], value.researchBool == nil { throw ResearchExchangeClientError.invalidParameters }
            if let value = parameters["allowedUTIs"] {
                guard let values = value.researchStrings, values.count <= 64,
                      Set(values).count == values.count, values.allSatisfy(Self.validSelectionUTI) else {
                    throw ResearchExchangeClientError.invalidParameters
                }
            }
        case .ocrFiles:
            allowed = ["languages", "outputs"]
            if let value = parameters["languages"], !(value.researchStrings?.allSatisfy(Self.validLanguage) ?? false) { throw ResearchExchangeClientError.invalidParameters }
            if let value = parameters["outputs"], !(value.researchStrings?.allSatisfy({ ["text", "markdown", "json", "searchablePDF"].contains($0) }) ?? false) { throw ResearchExchangeClientError.invalidParameters }
        case .openDocument: allowed = []
        }
        guard Set(parameters.keys).isSubset(of: allowed) else { throw ResearchExchangeClientError.invalidParameters }
    }

    private static func validSelectionUTI(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 256
            && value.rangeOfCharacter(from: CharacterSet.whitespacesAndNewlines.union(.controlCharacters)) == nil
    }

    private func validateProvider(_ application: URL, action: ResearchExternalAction,
                                  parameters: [String: GaoJSONValue]) throws {
        guard application.isFileURL, application.pathExtension == "app", let bundle = Bundle(url: application),
              bundle.bundleIdentifier == action.providerBundleID,
              let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              !appVersion.isEmpty else { throw ResearchExchangeClientError.invalidCapability }
        let url = application.appendingPathComponent("Contents/Resources/GaoCapabilities.json")
        let value = try JSONDecoder().decode(GaoJSONValue.self, from: providerMetadata(at: url))
        guard let object = value.researchObject, object["schemaVersion"]?.researchNumber == 1,
              object["bundleID"]?.researchString == action.providerBundleID,
              object["appVersion"]?.researchString == appVersion else { throw ResearchExchangeClientError.invalidCapability }
        var capability: [String: GaoJSONValue]?
        if let actions = object["actions"]?.researchArray {
            let matches = actions.compactMap(\.researchObject).filter {
                ($0["action"]?.researchString ?? $0["name"]?.researchString) == action.rawValue
            }
            guard matches.count == 1 else { throw ResearchExchangeClientError.invalidCapability }
            capability = matches.first
        } else if let actions = object["actions"]?.researchObject {
            capability = actions[action.rawValue]?.researchObject
        }
        guard let capability,
              let schema = (capability["parameters"] ?? capability["parameterSchema"] ?? capability["parametersSchema"])?.researchObject,
              schema["type"]?.researchString == "object", schema["additionalProperties"]?.researchBool == false,
              let properties = schema["properties"]?.researchObject else { throw ResearchExchangeClientError.invalidCapability }
        let required = schema["required"]?.researchStrings ?? []
        guard Set(required).isSubset(of: Set(parameters.keys)), Set(parameters.keys).isSubset(of: Set(properties.keys)) else { throw ResearchExchangeClientError.invalidCapability }
        for (key, value) in parameters {
            guard let definition = properties[key]?.researchObject,
                  Self.matchesSchema(value, definition) else { throw ResearchExchangeClientError.invalidCapability }
        }
        if action == .chooseFiles {
            guard let modes = (capability["selectionModes"] ?? capability["resultModes"])?.researchStrings,
                  modes.contains("references") || modes.contains("copies") else { throw ResearchExchangeClientError.invalidCapability }
        }
    }

    private static func matchesSchema(_ value: GaoJSONValue, _ schema: [String: GaoJSONValue]) -> Bool {
        let known: Set<String> = ["type", "enum", "maxLength", "minLength", "maxItems", "minItems", "items", "minimum", "maximum", "description", "default", "title"]
        guard Set(schema.keys).isSubset(of: known) else { return false }
        if let choices = schema["enum"]?.researchArray, !choices.contains(value) { return false }
        switch schema["type"]?.researchString {
        case "boolean": return value.researchBool != nil
        case "string":
            guard let string = value.researchString else { return false }
            if let max = schema["maxLength"]?.researchNumber, Double(string.count) > max { return false }
            if let min = schema["minLength"]?.researchNumber, Double(string.count) < min { return false }
            return true
        case "array":
            guard let entries = value.researchArray, entries.count <= 256,
                  let itemSchema = schema["items"]?.researchObject else { return false }
            if let max = schema["maxItems"]?.researchNumber, Double(entries.count) > max { return false }
            if let min = schema["minItems"]?.researchNumber, Double(entries.count) < min { return false }
            return entries.allSatisfy { matchesSchema($0, itemSchema) }
        case "integer", "number":
            guard let number = value.researchNumber, number.isFinite else { return false }
            if schema["type"]?.researchString == "integer", number.rounded() != number { return false }
            if let min = schema["minimum"]?.researchNumber, number < min { return false }
            if let max = schema["maximum"]?.researchNumber, number > max { return false }
            return true
        default: return false
        }
    }

    private func validateOCR(_ package: GaoValidatedActionPackage, session: ResearchExchangeSession) throws -> [ResearchOCROutput] {
        let manifest = package.manifest
        guard manifest.references.isEmpty else { throw ResearchExchangeClientError.invalidOCRMapping }
        let provenance = manifest.provenance ?? [:]
        func records(_ key: String) throws -> [[String: GaoJSONValue]]? {
            guard let value = provenance[key] else { return nil }
            guard let array = value.researchArray else { throw ResearchExchangeClientError.invalidOCRMapping }
            let objects = array.compactMap(\.researchObject)
            guard objects.count == array.count else { throw ResearchExchangeClientError.invalidOCRMapping }
            return objects
        }
        let batch = try records("outputs")
        let sources = try records("sources")
        let itemIDs = Set(package.stagedItems.map { $0.item.id })
        var coveredSources = Set<String>()
        var hasIncompletePages = false
        var sourceRecords: [String: [String: GaoJSONValue]] = [:]
        // Check every source record, including failed inputs with no output file.
        // Otherwise a completed result could hide a failed second input.
        for source in sources ?? [] {
            guard let sourceID = source["sourceItemID"]?.researchString,
                  let checksum = source["sourceSHA256"]?.researchString,
                  let original = session.sources.first(where: { $0.itemID == sourceID }),
                  checksum.lowercased() == original.sha256, sourceRecords[sourceID] == nil else { throw ResearchExchangeClientError.invalidOCRMapping }
            if let value = source["outputItemIDs"] {
                guard let outputs = value.researchStrings, Set(outputs).count == outputs.count,
                      Set(outputs).isSubset(of: itemIDs) else { throw ResearchExchangeClientError.invalidOCRMapping }
            }
            let pages = try parseOCRPages(source["pages"])
            hasIncompletePages = hasIncompletePages || pages.contains(where: Self.incompleteOCRPage)
            sourceRecords[sourceID] = source
        }
        if let batch {
            var mappedIDs = Set<String>()
            for output in batch {
                guard let itemID = (output["resultItemID"] ?? output["itemID"])?.researchString,
                      itemIDs.contains(itemID), mappedIDs.insert(itemID).inserted else { throw ResearchExchangeClientError.invalidOCRMapping }
                if let old = output["itemID"]?.researchString, let current = output["resultItemID"]?.researchString,
                   old != current { throw ResearchExchangeClientError.invalidOCRMapping }
            }
            guard mappedIDs == itemIDs else { throw ResearchExchangeClientError.invalidOCRMapping }
            for (sourceID, source) in sourceRecords {
                for itemID in source["outputItemIDs"]?.researchStrings ?? [] {
                    guard let mapping = batch.first(where: { ($0["resultItemID"] ?? $0["itemID"])?.researchString == itemID }),
                          mapping["sourceItemID"]?.researchString == sourceID else { throw ResearchExchangeClientError.invalidOCRMapping }
                }
            }
        }
        var results: [ResearchOCROutput] = []
        let supportedUTIs: Set<String> = ["public.plain-text", "public.utf8-plain-text", "text/plain", "public.json", "application/json", "net.daringfireball.markdown", "text/markdown", "com.adobe.pdf", "application/pdf"]
        for output in package.stagedItems {
            guard supportedUTIs.contains(output.item.uti) else { throw ResearchExchangeClientError.invalidOCRMapping }
            let mapping: [String: GaoJSONValue]
            if let batch {
                let matches = batch.filter { ($0["resultItemID"] ?? $0["itemID"])?.researchString == output.item.id }
                guard matches.count == 1 else { throw ResearchExchangeClientError.invalidOCRMapping }
                mapping = matches[0]
            } else { mapping = provenance }
            guard let sourceID = mapping["sourceItemID"]?.researchString,
                  let sourceSHA = mapping["sourceSHA256"]?.researchString,
                  let original = session.sources.first(where: { $0.itemID == sourceID }),
                  sourceSHA.lowercased() == original.sha256 else { throw ResearchExchangeClientError.invalidOCRMapping }
            let source = sourceRecords[sourceID]
            if sources != nil, source == nil { throw ResearchExchangeClientError.invalidOCRMapping }
            if let source {
                if let sourceOutputs = source["outputItemIDs"]?.researchStrings,
                   !sourceOutputs.contains(output.item.id) { throw ResearchExchangeClientError.invalidOCRMapping }
                if let sourceID = source["sourceID"]?.researchString, let outputSourceID = mapping["sourceID"]?.researchString,
                   sourceID != outputSourceID { throw ResearchExchangeClientError.invalidOCRMapping }
            }
            coveredSources.insert(sourceID)
            // Per-output mapping, source metadata and top-level engine metadata
            // are all V1 production forms. Missing values stay missing.
            func metadata(_ key: String) -> GaoJSONValue? { mapping[key] ?? source?[key] ?? provenance[key] }
            let engine = metadata("engine")?.researchString ?? metadata("ocrEngine")?.researchString
            var revision: Int?
            if let declaredRevision = metadata("engineRevision") {
                guard let number = declaredRevision.researchNumber, number.isFinite, number >= 0,
                      number <= Double(Int32.max), number.rounded() == number else { throw ResearchExchangeClientError.invalidOCRMapping }
                revision = Int(number)
            }
            let version = metadata("engineVersion")?.researchString ?? metadata("ocrEngineVersion")?.researchString
                ?? revision.map { "revision \($0)" }
            var languages: [String] = []
            if let declaredLanguages = metadata("languages") {
                guard let values = declaredLanguages.researchStrings, values.allSatisfy(Self.validLanguage) else { throw ResearchExchangeClientError.invalidOCRMapping }
                languages = values
            }
            let pages = try parseOCRPages(mapping["pages"] ?? source?["pages"] ?? provenance["pages"])
            hasIncompletePages = hasIncompletePages || pages.contains(where: Self.incompleteOCRPage)
            var warnings: [String] = []
            if engine?.isEmpty != false || version?.isEmpty != false { warnings.append("OCR 引擎或版本未提供") }
            if languages.isEmpty { warnings.append("OCR 语言未提供，未将请求语种当作识别结果") }
            if pages.isEmpty { warnings.append("OCR 逐页状态未提供") }
            if pages.contains(where: { !$0.regions.isEmpty && $0.coordinateSpace == nil }) { warnings.append("OCR 坐标单位未提供，不能推定定位") }
            results.append(.init(itemID: output.item.id, sourceItemID: sourceID, sourceSHA256: original.sha256,
                                 sourceDocumentID: original.documentID, engine: engine, engineVersion: version,
                                 languages: languages, pages: pages, metadataComplete: warnings.isEmpty, warnings: warnings,
                                 localCopy: output.url, uti: output.item.uti, byteCount: output.item.byteCount,
                                 sha256: output.item.sha256, engineRevision: revision))
        }
        if manifest.status == "completed", hasIncompletePages || coveredSources.count != session.sources.count || results.isEmpty {
            throw ResearchExchangeClientError.invalidOCRCompletion
        }
        return results
    }

    private static func incompleteOCRPage(_ page: ResearchOCRPage) -> Bool {
        page.status != "completed" || page.confidence.map { $0 < 0.5 } == true
    }

    private func parseOCRPages(_ value: GaoJSONValue?) throws -> [ResearchOCRPage] {
        guard let value else { return [] }
        guard let entries = value.researchArray else { throw ResearchExchangeClientError.invalidOCRMapping }
        var pages: [ResearchOCRPage] = []
        for entry in entries {
            guard let page = entry.researchObject,
                  let number = (page["pageNumber"] ?? page["page"])?.researchNumber,
                  number >= 1, number <= 1_000_000, number.rounded() == number,
                  let status = page["status"]?.researchString,
                  ["completed", "failed", "lowConfidence", "cancelled", "pending"].contains(status),
                  !pages.contains(where: { $0.pageNumber == Int(number) }) else { throw ResearchExchangeClientError.invalidOCRMapping }
            var confidence: Double?
            if let value = page["confidence"], value != .null {
                guard let number = value.researchNumber, number.isFinite, (0...1).contains(number) else { throw ResearchExchangeClientError.invalidOCRMapping }
                confidence = number
            }
            var regions: [[String: GaoJSONValue]] = []
            if let value = page["regions"] ?? page["coordinates"] {
                guard let entries = value.researchArray else { throw ResearchExchangeClientError.invalidOCRMapping }
                for entry in entries {
                    guard let region = entry.researchObject,
                          let x = region["x"]?.researchNumber, let y = region["y"]?.researchNumber,
                          let width = region["width"]?.researchNumber, let height = region["height"]?.researchNumber,
                          [x, y, width, height].allSatisfy({ $0.isFinite && $0 >= 0 }),
                          width > 0, height > 0 else { throw ResearchExchangeClientError.invalidOCRMapping }
                    regions.append(region)
                }
            }
            if let text = page["text"], text.researchString == nil { throw ResearchExchangeClientError.invalidOCRMapping }
            let coordinateSpace = page["coordinateSpace"]?.researchString
            if let coordinateSpace, !["normalized", "points", "pixels"].contains(coordinateSpace) { throw ResearchExchangeClientError.invalidOCRMapping }
            if coordinateSpace == "normalized" {
                for region in regions {
                    guard let x = region["x"]?.researchNumber, let y = region["y"]?.researchNumber,
                          let width = region["width"]?.researchNumber, let height = region["height"]?.researchNumber,
                          x + width <= 1.000001, y + height <= 1.000001 else { throw ResearchExchangeClientError.invalidOCRMapping }
                }
            }
            pages.append(.init(pageNumber: Int(number), status: status, confidence: confidence, regions: regions,
                               text: page["text"]?.researchString, coordinateSpace: coordinateSpace))
        }
        return pages.sorted { $0.pageNumber < $1.pageNumber }
    }

    private func compareDeclared(_ reference: GaoActionReference, actual: GaoActionFileFingerprint) throws {
        let declared = reference.declaredIdentity
        let current = actual.identity
        if let value = reference.sha256, value != actual.sha256 { throw ResearchExchangeClientError.sourceChanged }
        if let value = declared.device, value != current.device { throw ResearchExchangeClientError.sourceChanged }
        if let value = declared.inode, value != current.inode { throw ResearchExchangeClientError.sourceChanged }
        if let value = declared.byteCount, value != actual.byteCount { throw ResearchExchangeClientError.sourceChanged }
        if let value = declared.volumeUUID, value != current.volumeUUID { throw ResearchExchangeClientError.sourceChanged }
        if let value = declared.modifiedAt, Self.isoDate(value) != current.modifiedAt.flatMap(Self.isoDate) { throw ResearchExchangeClientError.sourceChanged }
    }

    private func validateCurrentSources(_ session: ResearchExchangeSession) throws {
        for source in session.sources {
            guard let url = URL(string: source.originalFileURL), url.isFileURL else { throw ResearchExchangeClientError.invalidSession }
            let snapshot = try GaoActionFileAccess.fingerprint(at: url)
            guard snapshot.sha256 == source.sha256, snapshot.byteCount == source.byteCount else { throw ResearchExchangeClientError.sourceChanged }
        }
    }

    // Installed applications can be root-owned. Their read-only capability
    // metadata does not use the stricter current-UID rule for transferred files.
    private func providerMetadata(at url: URL) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ResearchExchangeClientError.invalidCapability }
        defer { Darwin.close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_nlink == 1, before.st_size >= 0, before.st_size <= 1_048_576 else { throw ResearchExchangeClientError.invalidCapability }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        let data = try handle.read(upToCount: 1_048_577) ?? Data()
        var after = stat()
        guard data.count == before.st_size, fstat(fd, &after) == 0,
              before.st_size == after.st_size,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
              before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec,
              before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else { throw ResearchExchangeClientError.invalidCapability }
        return data
    }

    private func ensureExchange() throws {
        try privateDirectory(exchangeRoot)
        try privateDirectory(exchangeRoot.appendingPathComponent("Sessions", isDirectory: true))
    }

    private func markSessionOpened(_ requestID: String) throws {
        Self.sessionMutationLock.lock()
        defer { Self.sessionMutationLock.unlock() }
        var session = try loadSession(requestID)
        if session.resultIDs.isEmpty { session.state = "opened" }
        // LaunchServices completion is not a save, import or OCR completion.
        try saveSession(session)
    }

    private func privateDirectory(_ url: URL) throws {
        try GaoActionFileAccess.ensurePrivateDirectory(at: url)
    }

    private func sessionURL(_ id: String) -> URL {
        exchangeRoot.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent("\(id).json")
    }

    private func saveSession(_ session: ResearchExchangeSession) throws {
        try ensureExchange()
        guard UUID(uuidString: session.requestID) != nil else { throw ResearchExchangeClientError.invalidSession }
        let url = sessionURL(session.requestID)
        try GaoActionFileAccess.writePrivateData(JSONEncoder().encode(session), to: url)
    }

    private func loadManifest(_ package: URL) throws -> GaoActionManifest {
        let url = package.appendingPathComponent("manifest.json")
        return try JSONDecoder().decode(GaoActionManifest.self, from: GaoActionFileAccess.readPrivateData(at: url))
    }

    private static func validLanguage(_ value: String) -> Bool {
        value.utf8.count <= 64 && value.range(of: "^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$", options: .regularExpression) != nil
    }

    private static func isoString(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    private static func isoDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private extension GaoJSONValue {
    var researchString: String? { if case .string(let value) = self { return value }; return nil }
    var researchNumber: Double? { if case .number(let value) = self { return value }; return nil }
    var researchBool: Bool? { if case .bool(let value) = self { return value }; return nil }
    var researchArray: [GaoJSONValue]? { if case .array(let value) = self { return value }; return nil }
    var researchObject: [String: GaoJSONValue]? { if case .object(let value) = self { return value }; return nil }
    var researchStrings: [String]? {
        guard let values = researchArray else { return nil }
        let strings = values.compactMap(\.researchString)
        return strings.count == values.count ? strings : nil
    }
}
