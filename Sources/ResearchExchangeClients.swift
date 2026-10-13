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
    case invalidEditResult, requestExpired, tooManyItems, alreadyImported

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

    func prepareFileSelection(allowedUTIs: [String] = [], multiple: Bool = true) throws -> ResearchPreparedExchange {
        var parameters: [String: GaoJSONValue] = ["multiple": .bool(multiple)]
        if !allowedUTIs.isEmpty { parameters["allowedUTIs"] = .array(allowedUTIs.map(GaoJSONValue.string)) }
        return try prepare(action: .chooseFiles, files: [], parameters: parameters, documentVersion: nil)
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
        var updated = try loadSession(prepared.requestID)
        updated.state = "opened" // LaunchServices completion is not a save or OCR completion.
        try saveSession(updated)
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
            references = manifest.references
        case .ocrFiles:
            try validateCurrentSources(session)
            ocr = try validateOCR(package, session: session)
            if ocr.contains(where: { !$0.metadataComplete }) { workflow = "needsReview" }
        case .openDocument:
            guard manifest.items.isEmpty, manifest.references.isEmpty else { throw ResearchExchangeClientError.invalidEditResult }
            let reported = manifest.provenance?["workflowState"]?.researchString
            guard ["opened", "cancelled", "failed", "unsupported", "awaitingUser"].contains(reported ?? ""),
                  manifest.status != "completed" || reported == "opened" else { throw ResearchExchangeClientError.invalidEditResult }
            workflow = reported ?? "failed"
        }
        let duplicate = session.resultIDs.contains(manifest.requestID)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let manifestSHA = SHA256.hash(data: try encoder.encode(manifest)).map { String(format: "%02x", $0) }.joined()
        if let previous = session.resultManifestSHA256?[manifest.requestID], previous != manifestSHA {
            throw ResearchExchangeClientError.resultMismatch
        }
        if !duplicate {
            session.resultIDs.append(manifest.requestID)
            if session.resultManifestSHA256 == nil { session.resultManifestSHA256 = [:] }
            session.resultManifestSHA256?[manifest.requestID] = manifestSHA
            session.state = workflow
            try saveSession(session)
        }
        return .init(package: package, session: session, ocrOutputs: ocr,
                     selectedReferences: references, workflowState: workflow, duplicate: duplicate)
    }

    /// References grant neither permission nor identity. Re-select with this app's
    /// Open panel when identity is incomplete or this process cannot read it.
    func verifySelectedReference(_ reference: GaoActionReference,
                                 userSelectedURL: URL? = nil) throws -> ResearchVerifiedSelection {
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
        guard fingerprint.byteCount <= maximumBytes else { throw ResearchExchangeClientError.tooManyItems }
        try ensureExchange()
        let directory = exchangeRoot.appendingPathComponent("Selections/\(UUID().uuidString)", isDirectory: true)
        try privateDirectory(directory)
        let ext = source.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("selected\(ext.isEmpty ? "" : "." + ext)")
        let copied = try GaoActionFileAccess.copyRegularFile(at: source, to: destination, maximumBytes: maximumBytes)
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
              original.documentVersion == currentVersion,
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
        guard selected.sha256 != original.sha256 else { throw ResearchExchangeClientError.sourceChanged }
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
        _ = try GaoActionFileAccess.fingerprint(at: url)
        let data = try Data(contentsOf: url)
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
                         parameters: [String: GaoJSONValue], documentVersion: Date?) throws -> ResearchPreparedExchange {
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
                                         items: items, references: [], parameters: parameters)
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
                              sources: bindings, state: "prepared", resultIDs: [], importedEditedSHA256: nil))
        return .init(packageURL: package, requestID: requestID, action: action, parameters: parameters)
    }

    private func validateParameters(_ parameters: [String: GaoJSONValue], action: ResearchExternalAction) throws {
        let allowed: Set<String>
        switch action {
        case .chooseFiles:
            allowed = ["allowedUTIs", "multiple"]
            if let value = parameters["multiple"], value.researchBool == nil { throw ResearchExchangeClientError.invalidParameters }
            if let value = parameters["allowedUTIs"], !(value.researchStrings?.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? false) { throw ResearchExchangeClientError.invalidParameters }
        case .ocrFiles:
            allowed = ["languages", "outputs"]
            if let value = parameters["languages"], !(value.researchStrings?.allSatisfy(Self.validLanguage) ?? false) { throw ResearchExchangeClientError.invalidParameters }
            if let value = parameters["outputs"], !(value.researchStrings?.allSatisfy({ ["text", "markdown", "json", "searchablePDF"].contains($0) }) ?? false) { throw ResearchExchangeClientError.invalidParameters }
        case .openDocument: allowed = []
        }
        guard Set(parameters.keys).isSubset(of: allowed) else { throw ResearchExchangeClientError.invalidParameters }
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
        let batch = provenance["outputs"]?.researchArray?.compactMap(\.researchObject)
        var results: [ResearchOCROutput] = []
        var coveredSources = Set<String>()
        var hasIncompletePages = false
        for output in package.stagedItems {
            let metadata: [String: GaoJSONValue]
            if let batch {
                let matches = batch.filter { $0["itemID"]?.researchString == output.item.id }
                guard matches.count == 1 else { throw ResearchExchangeClientError.invalidOCRMapping }
                metadata = matches[0]
            } else { metadata = provenance }
            guard let sourceID = metadata["sourceItemID"]?.researchString,
                  let sourceSHA = metadata["sourceSHA256"]?.researchString,
                  let original = session.sources.first(where: { $0.itemID == sourceID }),
                  sourceSHA == original.sha256 else { throw ResearchExchangeClientError.invalidOCRMapping }
            coveredSources.insert(sourceID)
            let engine = metadata["engine"]?.researchString ?? metadata["ocrEngine"]?.researchString
            let version = metadata["engineVersion"]?.researchString ?? metadata["ocrEngineVersion"]?.researchString
            let languages = metadata["languages"]?.researchStrings ?? []
            if !languages.allSatisfy(Self.validLanguage) { throw ResearchExchangeClientError.invalidOCRMapping }
            var pages: [ResearchOCRPage] = []
            if let entries = metadata["pages"]?.researchArray {
                for entry in entries {
                    guard let page = entry.researchObject,
                          let number = (page["pageNumber"] ?? page["page"])?.researchNumber,
                          number >= 1, number <= 1_000_000, number.rounded() == number,
                          let status = page["status"]?.researchString,
                          ["completed", "failed", "lowConfidence", "cancelled", "pending"].contains(status) else { throw ResearchExchangeClientError.invalidOCRMapping }
                    let confidence = page["confidence"]?.researchNumber
                    if let confidence, !confidence.isFinite || !(0...1).contains(confidence) { throw ResearchExchangeClientError.invalidOCRMapping }
                    var regions: [[String: GaoJSONValue]] = []
                    if let entries = (page["regions"] ?? page["coordinates"])?.researchArray {
                        for entry in entries {
                            guard let region = entry.researchObject,
                                  let x = region["x"]?.researchNumber, let y = region["y"]?.researchNumber,
                                  let width = region["width"]?.researchNumber, let height = region["height"]?.researchNumber,
                                  [x, y, width, height].allSatisfy({ $0.isFinite && $0 >= 0 }),
                                  width > 0, height > 0 else { throw ResearchExchangeClientError.invalidOCRMapping }
                            regions.append(region)
                        }
                    }
                    if status != "completed" || (confidence != nil && confidence! < 0.5) { hasIncompletePages = true }
                    guard !pages.contains(where: { $0.pageNumber == Int(number) }) else { throw ResearchExchangeClientError.invalidOCRMapping }
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
            }
            var warnings: [String] = []
            if engine?.isEmpty != false || version?.isEmpty != false { warnings.append("OCR 引擎或版本未提供") }
            if languages.isEmpty { warnings.append("OCR 语言未提供") }
            if pages.isEmpty { warnings.append("OCR 逐页状态未提供") }
            if pages.contains(where: { !$0.regions.isEmpty && $0.coordinateSpace == nil }) { warnings.append("OCR 坐标单位未提供，不能推定定位") }
            results.append(.init(itemID: output.item.id, sourceItemID: sourceID, sourceSHA256: sourceSHA,
                                 sourceDocumentID: original.documentID, engine: engine, engineVersion: version,
                                 languages: languages, pages: pages.sorted { $0.pageNumber < $1.pageNumber },
                                 metadataComplete: warnings.isEmpty, warnings: warnings))
        }
        if manifest.status == "completed", hasIncompletePages || coveredSources.count != session.sources.count {
            throw ResearchExchangeClientError.invalidOCRCompletion
        }
        return results
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

    private func privateDirectory(_ url: URL) throws {
        if fileManager.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw ResearchExchangeClientError.invalidSelection }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    private func sessionURL(_ id: String) -> URL {
        exchangeRoot.appendingPathComponent("Sessions", isDirectory: true).appendingPathComponent("\(id).json")
    }

    private func saveSession(_ session: ResearchExchangeSession) throws {
        try ensureExchange()
        guard UUID(uuidString: session.requestID) != nil else { throw ResearchExchangeClientError.invalidSession }
        let url = sessionURL(session.requestID)
        try JSONEncoder().encode(session).write(to: url, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func loadManifest(_ package: URL) throws -> GaoActionManifest {
        let url = package.appendingPathComponent("manifest.json")
        let fingerprint = try GaoActionFileAccess.fingerprint(at: url)
        guard fingerprint.byteCount <= 1_048_576 else { throw ResearchExchangeClientError.invalidSession }
        return try JSONDecoder().decode(GaoActionManifest.self, from: Data(contentsOf: url))
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
