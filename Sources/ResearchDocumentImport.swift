import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum ResearchDocumentImportError: LocalizedError {
    case unavailableLibrary, busy, invalidTarget, unsupportedFile, missingDocument, versionConflict
    var errorDescription: String? {
        switch self {
        case .unavailableLibrary: return "资料库未成功加载或无法提交，原资料未修改。"
        case .busy: return "已有资料导入正在进行，请等待完成或取消。"
        case .invalidTarget: return "目标资料文件夹或业务记录已不存在，请重新选择。"
        case .unsupportedFile: return "存在不受支持的文件，已停止本批导入，请分批或另选文件。"
        case .missingDocument: return "原研究附件缺失，不能把缺失当作新版本覆盖。"
        case .versionConflict: return "原研究附件或版本已改变，请重新核对后再导入。"
        }
    }
}

enum ResearchExchangePaths {
    static var root: URL { LibraryPaths.applicationSupport.appendingPathComponent("Exchange", isDirectory: true) }
    static var bundleID: String {
        let frameworkID = ResearchBundle.bundle.bundleIdentifier ?? ""
        if frameworkID.hasSuffix(".framework") { return String(frameworkID.dropLast(".framework".count)) }
        return Bundle.main.bundleIdentifier ?? frameworkID
    }
}

struct ResearchDocumentImportContext {
    var sourceBundleID: String?
    var declaration: String?
    var targetRecordID: String?
    var originalDocumentID: String?
    var originalSHA256: String?
    var revisionKind: String?
    var engine: String?
    var engineVersion: String?
    var languages: [String] = []
    var pages: [DocumentProvenance.Page] = []
    var references: [String] = []
}

private struct ResearchImportRecordEnvelope: Codable {
    var document: ManagedDocument
    var folder: DocumentFolder?
}

@MainActor
extension DocumentLibraryStore {
    func transactionJournal() throws -> ResearchImportJournal {
        if let importJournal { return importJournal }
        guard libraryIsWritable() else { throw ResearchDocumentImportError.unavailableLibrary }
        let adapter = ResearchImportJournal.Adapter(
            currentRecords: { [weak self] in
                guard let self, self.libraryIsWritable() else { throw ResearchDocumentImportError.unavailableLibrary }
                return try self.documents.map { document in
                    let url = self.managedDocumentURL(document)
                    let fingerprint = try GaoActionFileAccess.fingerprint(at: url)
                    let relative = String(url.path.dropFirst(LibraryPaths.managedDocuments.path.count + 1))
                    return .init(documentID: document.id, scopeID: document.folderID,
                                 sha256: fingerprint.sha256, destinationRelativePath: relative)
                }
            },
            commitRecords: { [weak self] items in
                guard let self, self.libraryIsWritable(), let persist = self.persistTransaction else {
                    throw ResearchDocumentImportError.unavailableLibrary
                }
                let beforeDocuments = self.documents, beforeFolders = self.folders
                do {
                    for item in items {
                        let record = try JSONDecoder().decode(ResearchImportRecordEnvelope.self, from: item.recordData)
                        guard record.document.id == item.documentID, record.document.folderID == item.scopeID else {
                            throw ResearchDocumentImportError.invalidTarget
                        }
                        if !self.folders.contains(where: { $0.id == item.scopeID }) {
                            guard let folder = record.folder, folder.id == item.scopeID else { throw ResearchDocumentImportError.invalidTarget }
                            self.folders.append(folder)
                        }
                        if !self.documents.contains(where: { $0.id == item.documentID }) { self.documents.append(record.document) }
                    }
                    try persist()
                } catch {
                    self.documents = beforeDocuments; self.folders = beforeFolders
                    throw error
                }
            },
            indexDocuments: { [weak self] ids in
                guard let self else { throw ResearchDocumentImportError.unavailableLibrary }
                try await self.indexImportedDocuments(documentIDs: ids)
            })
        let journal = try ResearchImportJournal(exchangeRoot: ResearchExchangePaths.root,
                                                attachmentsRoot: LibraryPaths.managedDocuments, adapter: adapter,
                                                progress: { [weak self] stage, done, total in
            self?.importProgress = "资料交接：\(stage.rawValue)，\(done)/\(total) 项"
        })
        importJournal = journal
        return journal
    }

    func recoverDocumentImportsIfNeeded() async {
        let metadata = ResearchExchangePaths.root.appendingPathComponent("Metadata/ImportJobs")
        guard FileManager.default.fileExists(atPath: metadata.path), libraryIsWritable() else { return }
        do {
            let journal = try transactionJournal()
            let results = await journal.recoverPending()
            if !results.isEmpty { importProgress = "已检查 \(results.count) 个未完成交接；失败资料已保留，可在资料交接中复核。" }
        } catch { errorHandler("资料交接恢复未完成：\(error.localizedDescription)") }
    }

    func cancelDocumentImport() {
        guard let id = activeImportRequestID, let journal = importJournal else { return }
        do { try journal.cancel(requestID: id); importProgress = "正在取消；原件保留。" }
        catch { errorHandler(error.localizedDescription) }
    }

    /// Existing upload/drop callers and external handoffs share this transaction path.
    func importLocalDocuments(from sourceURLs: [URL], into folderID: String) async throws -> Int {
        guard let folder = folders.first(where: { $0.id == folderID }) else { throw ResearchDocumentImportError.invalidTarget }
        guard !sourceURLs.isEmpty, sourceURLs.allSatisfy({ Self.supportedExtensions.contains($0.pathExtension.lowercased()) }) else {
            throw ResearchDocumentImportError.unsupportedFile
        }
        guard !isImportingDocuments else { throw ResearchDocumentImportError.busy }
        let accessed = sourceURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        let bundleID = ResearchExchangePaths.bundleID, outgoing = ResearchExchangePaths.root.appendingPathComponent("LocalImports")
        let staging = ResearchExchangePaths.root.appendingPathComponent("Incoming")
        let package = try await Task.detached(priority: .userInitiated) { () -> GaoValidatedActionPackage in
            let items = sourceURLs.enumerated().map { index, url -> GaoActionItem in
                let id = SHA256.hash(data: Data("\(index):\(url.standardizedFileURL.path)".utf8)).map { String(format: "%02x", $0) }.joined()
                return .init(id: id, relativePath: "payload/\(id)/\(url.lastPathComponent)",
                             uti: UTType(filenameExtension: url.pathExtension)?.identifier ?? "public.data", byteCount: 0, sha256: String(repeating: "0", count: 64))
            }
            let manifest = GaoActionManifest(sourceBundleID: bundleID, targetBundleID: bundleID,
                                             action: "research.importDocuments", items: items)
            let files = Dictionary(uniqueKeysWithValues: zip(items.map(\.id), sourceURLs))
            let url = try GaoActionPackageWriter().write(manifest: manifest, files: files, outgoingRoot: outgoing)
            return try GaoActionPackageValidator(expectedTargetBundleID: bundleID).stagePackage(at: url, stagingRoot: staging)
        }.value
        let outcome = try await importStagedDocuments(package, into: folder)
        // Only our successfully completed local copies are disposable.
        try? FileManager.default.removeItem(at: package.stagingDirectory)
        try? FileManager.default.removeItem(at: outgoing.appendingPathComponent(package.manifest.requestID + ".gaoaction"))
        return outcome.importedCount
    }

    func importStagedDocuments(_ package: GaoValidatedActionPackage, into folder: DocumentFolder,
                               contexts: [String: ResearchDocumentImportContext] = [:],
                               allowNewFolder: Bool = false) async throws -> ResearchImportJournal.Outcome {
        guard libraryIsWritable() else { throw ResearchDocumentImportError.unavailableLibrary }
        guard !isImportingDocuments else { throw ResearchDocumentImportError.busy }
        guard allowNewFolder || folders.contains(where: { $0.id == folder.id }) else { throw ResearchDocumentImportError.invalidTarget }
        guard let requestID = UUID(uuidString: package.manifest.requestID), !package.stagedItems.isEmpty else { throw GaoActionError.invalidManifest }
        guard package.stagedItems.allSatisfy({ Self.supportedExtensions.contains($0.url.pathExtension.lowercased()) }) else {
            throw ResearchDocumentImportError.unsupportedFile
        }
        isImportingDocuments = true; activeImportRequestID = requestID
        defer { isImportingDocuments = false; activeImportRequestID = nil }
        let now = Date(), journal = try transactionJournal()
        var inputs: [ResearchImportJournal.Input] = []
        for staged in package.stagedItems {
            let id = UUID().uuidString, ext = staged.url.pathExtension.lowercased()
            let stored = UUID().uuidString + "." + ext
            let context = contexts[staged.item.id] ?? .init(sourceBundleID: package.manifest.sourceBundleID,
                                                          declaration: "发送方声明；未经身份认证")
            let document = ManagedDocument(id: id, folderID: folder.id, originalName: staged.originalFilename,
                                           displayName: staged.originalFilename, storedName: stored, fileExtension: ext,
                                           tags: [], byteCount: staged.item.byteCount, uploadedAt: now, updatedAt: now)
            let provenance = DocumentProvenance(documentID: id, originalSHA256: context.originalSHA256 ?? staged.item.sha256,
                                               sourceBundleID: context.sourceBundleID, sourceDeclaration: context.declaration,
                                               ocrEngine: context.engine, ocrVersion: context.engineVersion, ocrLanguages: context.languages,
                                               pages: context.pages, externalReferences: context.references, targetRecordID: context.targetRecordID)
            let revision = context.originalDocumentID.map {
                AttachmentRevision(documentID: id, originalDocumentID: $0,
                                   originalSHA256: context.originalSHA256 ?? staged.item.sha256,
                                   derivedSHA256: staged.item.sha256, kind: context.revisionKind ?? "derived")
            }
            let record = ResearchImportRecordEnvelope(document: document, folder: allowNewFolder ? folder : nil)
            inputs.append(.init(id: staged.item.id, sourceURL: staged.url, documentID: id, scopeID: folder.id,
                                destinationRelativePath: "\(folder.libraryKind.rawValue)/\(URL(fileURLWithPath: folder.id).lastPathComponent)/\(stored)",
                                sha256: staged.item.sha256, byteCount: staged.item.byteCount,
                                recordData: try JSONEncoder().encode(record), provenance: provenance, revision: revision))
        }
        let outcome = try await journal.submit(requestID: requestID, items: inputs)
        importProgress = "已导入 \(outcome.importedCount) 项，\(outcome.duplicateCount) 项内容已存在；全文索引已检查。"
        return outcome
    }

    func indexImportedDocuments(documentIDs: [String]) async throws {
        guard libraryIsWritable(), let commit = persistTransaction else { throw ResearchDocumentImportError.unavailableLibrary }
        let ids = Set(documentIDs)
        let targets = documents.filter { ids.contains($0.id) }.map { ($0.id, managedDocumentURL($0)) }
        let results = await Task.detached(priority: .utility) {
            targets.map { ($0.0, DocumentTextExtractor.extractText(from: $0.1)) }
        }.value
        let before = documents
        for (id, text) in results {
            guard let index = documents.firstIndex(where: { $0.id == id }) else { throw ResearchDocumentImportError.missingDocument }
            documents[index].contentText = text; documents[index].contentIndexedAt = Date()
        }
        do { try commit() } catch { documents = before; throw error }
    }

    func provenance(for documentID: String) -> DocumentProvenance? {
        try? transactionJournal().provenance(documentID: documentID)
    }

    func revision(for documentID: String) -> AttachmentRevision? {
        try? transactionJournal().revision(documentID: documentID)
    }

    var exchangeClient: ResearchExchangeClient {
        ResearchExchangeClient(exchangeRoot: ResearchExchangePaths.root,
                               researchBundleID: ResearchExchangePaths.bundleID)
    }

    // MARK: - 跨 App 交接动作发起与结果落地

    /// 向「搞整理」发起文件选择请求
    func requestChooseFilesFromZhengLi(targetFolderID: String, onPrepared: @escaping (ResearchPreparedExchange, ResearchProviderAvailability) -> Void) throws {
        guard folders.contains(where: { $0.id == targetFolderID }) else { throw ResearchDocumentImportError.invalidTarget }
        let allowed = Array(Self.supportedExtensions)
        let prepared = try exchangeClient.prepareFileSelection(allowedUTIs: allowed, multiple: true)
        let provider = exchangeClient.availability(for: .chooseFiles, parameters: prepared.parameters)
        onPrepared(prepared, provider)
    }

    /// 向「搞截图」发起扫描 PDF / 图像的文字识别（OCR）
    func requestOCRViaJieTu(for document: ManagedDocument, onPrepared: @escaping (ResearchPreparedExchange, ResearchProviderAvailability) -> Void) throws {
        let url = managedDocumentURL(document)
        let sourceFile = ResearchExchangeSourceFile(url: url, documentID: document.id)
        let prepared = try exchangeClient.prepareOCR(userSelectedFiles: [sourceFile], languages: ["zh-Hans", "en"], outputs: ["text", "searchablePDF"])
        let provider = exchangeClient.availability(for: .ocrFiles, parameters: prepared.parameters)
        onPrepared(prepared, provider)
    }

    /// 向「搞文件」发起外部编辑
    func requestEditViaWenJian(for document: ManagedDocument, onPrepared: @escaping (ResearchPreparedExchange, ResearchProviderAvailability) -> Void) throws {
        let url = managedDocumentURL(document)
        let prepared = try exchangeClient.prepareExternalEdit(documentID: document.id, originalURL: url, originalVersion: document.updatedAt)
        let provider = exchangeClient.availability(for: .openDocument, parameters: prepared.parameters)
        onPrepared(prepared, provider)
    }

    /// 导入外部编辑后的副本，明确区分“替换为新版本”或“另存为新附件”
    func importEditedDocumentCopy(for document: ManagedDocument, from editedURL: URL, asNewVersion: Bool) async throws {
        guard let folder = folders.first(where: { $0.id == document.folderID }) else { throw ResearchDocumentImportError.invalidTarget }
        let client = exchangeClient
        let sessions = try client.recentSessions(limit: 50).filter { $0.action == .openDocument && $0.sources.first?.documentID == document.id }
        guard let session = sessions.first else {
            throw ResearchExchangeClientError.invalidSession
        }
        let originalURL = managedDocumentURL(document)
        let mode: ResearchEditedCopyMode = asNewVersion ? .newVersion : .newAttachment
        let prepared = try client.prepareEditedCopyImport(requestID: session.requestID, currentDocumentID: document.id,
                                                         currentOriginalURL: originalURL, currentVersion: document.updatedAt,
                                                         userSelectedEditedCopy: editedURL, mode: mode)
        let ext = editedURL.pathExtension.lowercased()
        let now = Date()
        if asNewVersion {
            // 替换为新版本：保留原件 SHA256 溯源，更新文件内容与全文索引
            let journal = try transactionJournal()
            let stored = UUID().uuidString + "." + ext
            var updated = document
            updated.storedName = stored
            updated.fileExtension = ext
            updated.byteCount = prepared.byteCount
            updated.updatedAt = now
            let provenance = DocumentProvenance(documentID: document.id, originalSHA256: prepared.originalSHA256,
                                               sourceBundleID: session.providerBundleID, sourceDeclaration: "搞文件编辑返回；用户核验导入新版本",
                                               importedAt: now)
            let revision = AttachmentRevision(documentID: document.id, originalDocumentID: document.id,
                                              originalSHA256: prepared.originalSHA256, derivedSHA256: prepared.editedSHA256,
                                              kind: "editedVersion", createdAt: now)
            let record = ResearchImportRecordEnvelope(document: updated, folder: folder)
            let input = ResearchImportJournal.Input(id: UUID().uuidString, sourceURL: prepared.localCopy, documentID: document.id,
                                                   scopeID: folder.id,
                                                   destinationRelativePath: "\(folder.libraryKind.rawValue)/\(URL(fileURLWithPath: folder.id).lastPathComponent)/\(stored)",
                                                   sha256: prepared.editedSHA256, byteCount: prepared.byteCount,
                                                   recordData: try JSONEncoder().encode(record), provenance: provenance, revision: revision)
            _ = try await journal.submit(requestID: UUID(), items: [input])
            try client.markEditedCopyImported(prepared)
            if let index = documents.firstIndex(where: { $0.id == document.id }) {
                documents[index] = updated
            }
            try await indexImportedDocuments(documentIDs: [document.id])
        } else {
            // 另存为新附件：保留原文档不动，新增一份受管衍生文档
            let newDocID = UUID().uuidString
            let stored = UUID().uuidString + "." + ext
            let displayName = document.displayName + " (编辑版)"
            let newDoc = ManagedDocument(id: newDocID, folderID: folder.id, originalName: editedURL.lastPathComponent,
                                         displayName: displayName, storedName: stored, fileExtension: ext,
                                         tags: document.tags + ["编辑版"], byteCount: prepared.byteCount,
                                         uploadedAt: now, updatedAt: now)
            let provenance = DocumentProvenance(documentID: newDocID, originalSHA256: prepared.originalSHA256,
                                               sourceBundleID: session.providerBundleID, sourceDeclaration: "搞文件编辑衍生件",
                                               importedAt: now)
            let revision = AttachmentRevision(documentID: newDocID, originalDocumentID: document.id,
                                              originalSHA256: prepared.originalSHA256, derivedSHA256: prepared.editedSHA256,
                                              kind: "derivedAttachment", createdAt: now)
            let record = ResearchImportRecordEnvelope(document: newDoc, folder: folder)
            let input = ResearchImportJournal.Input(id: UUID().uuidString, sourceURL: prepared.localCopy, documentID: newDocID,
                                                   scopeID: folder.id,
                                                   destinationRelativePath: "\(folder.libraryKind.rawValue)/\(URL(fileURLWithPath: folder.id).lastPathComponent)/\(stored)",
                                                   sha256: prepared.editedSHA256, byteCount: prepared.byteCount,
                                                   recordData: try JSONEncoder().encode(record), provenance: provenance, revision: revision)
            _ = try await transactionJournal().submit(requestID: UUID(), items: [input])
            try client.markEditedCopyImported(prepared)
            documents.append(newDoc)
            try await indexImportedDocuments(documentIDs: [newDocID])
        }
    }

    /// 应用来自「搞截图」的 OCR 识别结果：关联至原件作为衍生件并更新全文索引与页码定位
    func applyOCRResult(_ output: ResearchOCROutput, to document: ManagedDocument) async throws {
        guard let folder = folders.first(where: { $0.id == document.folderID }) else { throw ResearchDocumentImportError.invalidTarget }
        let now = Date()
        let pages = output.pages.map { p in
            DocumentProvenance.Page(pageNumber: p.pageNumber, text: p.text, bounds: nil, confidence: p.confidence, status: p.status)
        }
        let fullText = output.pages.compactMap(\.text).joined(separator: "\n\n")
        let provenance = DocumentProvenance(documentID: document.id, originalSHA256: output.sourceSHA256,
                                           sourceBundleID: "com.gaoseries.GaoJieTu", sourceDeclaration: "搞截图 OCR 识别产物",
                                           importedAt: now, ocrEngine: output.engine, ocrVersion: output.engineVersion,
                                           ocrLanguages: output.languages, pages: pages, targetRecordID: document.id)
        let journal = try transactionJournal()
        // 保存 DocumentProvenance 元数据
        try journal.recordProvenanceDirectly(provenance)
        // 更新文档全文索引正文
        if let index = documents.firstIndex(where: { $0.id == document.id }) {
            let combined = [documents[index].contentText ?? "", fullText].filter { !$0.isEmpty }.joined(separator: "\n\n")
            documents[index].contentText = combined
            documents[index].contentIndexedAt = now
            if !documents[index].tags.contains("已OCR") {
                documents[index].tags.append("已OCR")
            }
            if let commit = persistTransaction { try commit() }
        }
    }
}


