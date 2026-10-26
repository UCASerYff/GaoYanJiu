import AppKit
import CryptoKit
import Foundation
import UniformTypeIdentifiers

enum ResearchDocumentImportError: LocalizedError {
    case unavailableLibrary, busy, invalidTarget, unsupportedFile, missingDocument, versionConflict, approvalRequired, resultNotApplicable, legacyResultReviewRequired, resultIntentConflict
    var errorDescription: String? {
        switch self {
        case .unavailableLibrary: return "资料库未成功加载或无法提交，原资料未修改。"
        case .busy: return "已有资料导入正在进行，请等待完成或取消。"
        case .invalidTarget: return "目标资料文件夹或业务记录已不存在，请重新选择。"
        case .unsupportedFile: return "存在不受支持的文件，已停止本批导入，请分批或另选文件。"
        case .missingDocument: return "原研究附件缺失，不能把缺失当作新版本覆盖。"
        case .versionConflict: return "原研究附件或版本已改变，请重新核对后再导入。"
        case .approvalRequired: return "请先明确核对并批准本次交接。"
        case .resultNotApplicable: return "此结果尚未完成或没有可导入附件；原资料未修改。"
        case .legacyResultReviewRequired: return "旧版交接未保留完整原始意图，不能自动确认本次重发。请核对已导入附件，或从原条目明确发起新请求；原资料未修改。"
        case .resultIntentConflict: return "本次交接已绑定经过核验的选择，当前内容或目标已改变。请恢复原选择，或明确发起新请求；原资料未修改。"
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

struct ResearchImportRecordEnvelope: Codable {
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
                let records = try self.readDurableDocuments?() ?? self.documents
                return try records.map { document in
                    let url = self.managedDocumentURL(document)
                    let fingerprint = try GaoActionFileAccess.fingerprint(at: url)
                    let relative = String(url.path.dropFirst(LibraryPaths.managedDocuments.path.count + 1))
                    return .init(documentID: document.id, scopeID: document.folderID,
                                 sha256: fingerprint.sha256, destinationRelativePath: relative,
                                 version: Self.importRecordVersion(document.updatedAt))
                }
            },
            commitRecords: { [weak self] items in
                guard let self, self.libraryIsWritable(), let persist = self.persistTransaction else {
                    throw ResearchDocumentImportError.unavailableLibrary
                }
                let beforeDocuments = self.documents, beforeFolders = self.folders
                let durableDocuments = try self.readDurableDocuments?() ?? self.documents
                let isNewOCRDerivativeBatch = items.allSatisfy { item in
                    guard item.effectiveOperation == .revision, let revision = item.revision else { return false }
                    return revision.kind == "ocrDerived" && revision.documentID == item.documentID
                        && revision.originalDocumentID != item.documentID
                }
                do {
                    var normalizedDurableDocuments: [ManagedDocument] = []
                    if isNewOCRDerivativeBatch {
                        let memoryIDs = Set(beforeDocuments.map(\.id)), durableIDs = Set(durableDocuments.map(\.id))
                        guard memoryIDs.count == beforeDocuments.count, durableIDs.count == durableDocuments.count,
                              memoryIDs == durableIDs else { throw ResearchDocumentImportError.versionConflict }
                        // Loading assigns UI order in memory without rewriting the library.
                        // Validate every old record before carrying the fresh durable values
                        // forward; unknown memory edits must never be silently discarded.
                        normalizedDurableDocuments = Self.normalizedDocumentOrdering(durableDocuments)
                        for memory in beforeDocuments {
                            guard let durable = durableDocuments.first(where: { $0.id == memory.id }),
                                  let normalized = normalizedDurableDocuments.first(where: { $0.id == memory.id }) else {
                                throw ResearchDocumentImportError.versionConflict
                            }
                            let canonical = try Self.canonicalDocument(memory)
                            guard try canonical == Self.canonicalDocument(durable)
                                    || canonical == Self.canonicalDocument(normalized) else {
                                throw ResearchDocumentImportError.versionConflict
                            }
                        }
                    }
                    for item in items {
                        let record = try Self.decodeImportRecord(item.recordData)
                        guard record.document.id == item.documentID, record.document.folderID == item.scopeID else {
                            throw ResearchDocumentImportError.invalidTarget
                        }
                        if !self.folders.contains(where: { $0.id == item.scopeID }) {
                            guard let folder = record.folder, folder.id == item.scopeID else { throw ResearchDocumentImportError.invalidTarget }
                            self.folders.append(folder)
                        }
                        let indices = self.documents.indices.filter { self.documents[$0].id == item.documentID }
                        guard indices.count <= 1 else { throw ResearchDocumentImportError.versionConflict }
                        switch item.effectiveOperation {
                        case .insert, .revision:
                            guard indices.isEmpty else { throw ResearchDocumentImportError.versionConflict }
                            if item.effectiveOperation == .revision, let data = item.originalRecordData {
                                let original = try Self.decodeImportRecord(data).document
                                guard let memory = self.documents.first(where: { $0.id == original.id }),
                                      let durable = durableDocuments.first(where: { $0.id == original.id }),
                                      try Self.canonicalDocument(memory) == Self.canonicalDocument(original) else {
                                    throw ResearchDocumentImportError.versionConflict
                                }
                                if isNewOCRDerivativeBatch, let order = original.sortOrder {
                                    // Moving a sibling can change this source's relative
                                    // position without changing its own stored order value.
                                    guard normalizedDurableDocuments.first(where: { $0.id == original.id })?.sortOrder == order else {
                                        throw ResearchDocumentImportError.versionConflict
                                    }
                                }
                                if try Self.canonicalDocument(durable) != Self.canonicalDocument(original) {
                                    // Only a new OCR derivative may use the exact load-only
                                    // nil-to-order view. Existing explicit order, all other
                                    // metadata and update/replacement CAS remain strict.
                                    guard isNewOCRDerivativeBatch, durable.sortOrder == nil, original.sortOrder != nil,
                                          item.expectedOriginal?.documentID == original.id,
                                          item.revision?.originalDocumentID == original.id,
                                          let normalized = normalizedDurableDocuments.first(where: { $0.id == original.id }),
                                          try Self.canonicalDocument(normalized) == Self.canonicalDocument(original) else {
                                        throw ResearchDocumentImportError.versionConflict
                                    }
                                }
                            }
                            self.documents.append(record.document)
                        case .update:
                            guard let index = indices.first, let originalData = item.originalRecordData else {
                                throw ResearchDocumentImportError.versionConflict
                            }
                            let original = try Self.decodeImportRecord(originalData)
                            guard try Self.canonicalDocument(self.documents[index]) == Self.canonicalDocument(original.document) else {
                                throw ResearchDocumentImportError.versionConflict
                            }
                            guard let durable = durableDocuments.first(where: { $0.id == original.document.id }),
                                  try Self.canonicalDocument(durable) == Self.canonicalDocument(original.document) else { throw ResearchDocumentImportError.versionConflict }
                            self.documents[index] = record.document
                        }
                    }
                    if isNewOCRDerivativeBatch {
                        let createdIDs = Set(items.map(\.documentID))
                        guard createdIDs.count == items.count,
                              self.documents.count == beforeDocuments.count + items.count else {
                            throw ResearchDocumentImportError.versionConflict
                        }
                        for original in beforeDocuments {
                            guard let current = self.documents.first(where: { $0.id == original.id }),
                                  try Self.canonicalDocument(current) == Self.canonicalDocument(original) else {
                                throw ResearchDocumentImportError.versionConflict
                            }
                        }
                        let created = self.documents.filter { createdIDs.contains($0.id) }
                        guard created.count == items.count else { throw ResearchDocumentImportError.versionConflict }
                        // PaperStore saves the whole collection. Preserve every old raw
                        // record and its order instead of persisting load-only UI values.
                        self.documents = durableDocuments + created
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
                                                failureInjector: importFailureInjector,
                                                progress: { [weak self] stage, done, total in
            self?.importProgress = "资料交接：\(stage.rawValue)，\(done)/\(total) 项"
        })
        importJournal = journal
        return journal
    }

    static func importRecordVersion(_ date: Date) -> String {
        // library.json uses ISO8601 to whole seconds. Compare its durable precision.
        GaoActionISO8601.string(Date(timeIntervalSince1970: floor(date.timeIntervalSince1970)))
    }

    static func canonicalDocument(_ document: ManagedDocument) throws -> ManagedDocument {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ManagedDocument.self, from: encoder.encode(document))
    }

    static func encodeImportRecord(_ record: ResearchImportRecordEnvelope) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(record)
    }

    static func decodeImportRecord(_ data: Data) throws -> ResearchImportRecordEnvelope {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        if let record = try? decoder.decode(ResearchImportRecordEnvelope.self, from: data) { return record }
        return try JSONDecoder().decode(ResearchImportRecordEnvelope.self, from: data)
    }

    func recoverDocumentImportsIfNeeded() async {
        let metadata = ResearchExchangePaths.root.appendingPathComponent("Metadata/ImportJobs")
        guard FileManager.default.fileExists(atPath: metadata.path), libraryIsWritable() else { return }
        do {
            let journal = try transactionJournal()
            let results = await journal.recoverPending()
            try recoverIncomingHandoffReceipts(journal: journal)
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
                                recordData: try Self.encodeImportRecord(record), provenance: provenance, revision: revision))
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
        let journal = try transactionJournal()
        let planned = try journal.recentJobs(limit: Int.max).filter { $0.stage == .indexing }.flatMap(\.items)
        do {
        for (id, text) in results {
            guard let index = documents.firstIndex(where: { $0.id == id }) else { throw ResearchDocumentImportError.missingDocument }
            let metadata = try planned.first(where: { $0.documentID == id })?.provenance ?? journal.provenance(documentID: id)
            let pageText = metadata?.pages.compactMap(\.text).joined(separator: "\n\n") ?? ""
            let existing = documents[index].contentText ?? ""
            documents[index].contentText = DocumentTextExtractor.indexedText(extracted: text, ocrText: pageText)
                ?? (existing.isEmpty ? nil : existing)
            documents[index].contentIndexedAt = Date()
        }
        try commit()
        } catch { documents = before; throw error }
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
        let allowed = Self.supportedExtensions.compactMap { UTType(filenameExtension: $0)?.identifier }
        let prepared = try exchangeClient.prepareFileSelection(allowedUTIs: allowed, multiple: true, targetFolderID: targetFolderID)
        let provider = exchangeClient.availability(for: .chooseFiles, parameters: prepared.parameters)
        onPrepared(prepared, provider)
    }

    /// 向「搞截图」发起扫描 PDF / 图像的文字识别（OCR）
    func requestOCRViaJieTu(for document: ManagedDocument, onPrepared: @escaping (ResearchPreparedExchange, ResearchProviderAvailability) -> Void) throws {
        let url = managedDocumentURL(document)
        let sourceFile = ResearchExchangeSourceFile(url: url, documentID: document.id)
        let prepared = try exchangeClient.prepareOCR(userSelectedFiles: [sourceFile], languages: ["zh-Hans", "en-US"], outputs: ["text", "json", "searchablePDF"])
        let provider = exchangeClient.availability(for: .ocrFiles, parameters: prepared.parameters)
        onPrepared(prepared, provider)
    }

    /// 向「搞文件」发起外部编辑
    func requestEditViaWenJian(for document: ManagedDocument, onPrepared: @escaping (ResearchPreparedExchange, ResearchProviderAvailability) -> Void) throws {
        let url = managedDocumentURL(document)
        let prepared = try exchangeClient.prepareExternalEdit(documentID: document.id, originalURL: url, originalVersion: Date(timeIntervalSince1970: floor(document.updatedAt.timeIntervalSince1970)))
        let provider = exchangeClient.availability(for: .openDocument, parameters: prepared.parameters)
        onPrepared(prepared, provider)
    }

    /// Explicit editing import; the journal is the only attachment/record writer.
    func importEditedDocumentCopy(for document: ManagedDocument, from editedURL: URL, asNewVersion: Bool) async throws {
        guard libraryIsWritable(), !isImportingDocuments else { throw ResearchDocumentImportError.busy }
        guard Self.supportedExtensions.contains(editedURL.pathExtension.lowercased()) else { throw ResearchDocumentImportError.unsupportedFile }
        let accessed = editedURL.startAccessingSecurityScopedResource()
        defer { if accessed { editedURL.stopAccessingSecurityScopedResource() } }
        let client = exchangeClient
        let sessions = try client.recentSessions(limit: 100).filter { $0.action == .openDocument && $0.sources.first?.documentID == document.id }
        guard let session = sessions.first else { throw ResearchExchangeClientError.invalidSession }
        let selected = try GaoActionFileAccess.fingerprint(at: editedURL)
        let mode: ResearchEditedCopyMode = asNewVersion ? .newVersion : .newAttachment
        let jobID = Self.stableImportID("edit:\(session.requestID):\(selected.sha256):\(mode.rawValue)")
        let journal = try transactionJournal()
        isImportingDocuments = true; activeImportRequestID = jobID
        defer { isImportingDocuments = false; activeImportRequestID = nil }
        if let previous = try journal.job(requestID: jobID) {
            let inputs = previous.items.map { Self.restoredInput($0, source: editedURL) }
            _ = try await journal.submit(requestID: jobID, items: inputs)
            guard let original = previous.items.first?.expectedOriginal,
                  let version = original.version.flatMap(GaoActionISO8601.date) else { throw ResearchDocumentImportError.versionConflict }
            let committed = ResearchEditedCopyImport(requestID: session.requestID, originalDocumentID: original.documentID,
                                                     originalSHA256: original.sha256, originalVersion: version,
                                                     localCopy: editedURL, editedSHA256: selected.sha256, byteCount: selected.byteCount, mode: mode)
            try client.markEditedCopyImported(committed)
            return
        }
        guard let current = documents.first(where: { $0.id == document.id }),
              try Self.canonicalDocument(current) == Self.canonicalDocument(document),
              let folder = folders.first(where: { $0.id == current.folderID }) else { throw ResearchDocumentImportError.versionConflict }
        let prepared = try client.prepareEditedCopyImport(requestID: session.requestID, currentDocumentID: current.id,
                                                          currentOriginalURL: managedDocumentURL(current), currentVersion: current.updatedAt,
                                                          userSelectedEditedCopy: editedURL, mode: mode)
        let expected = try expectedState(for: current, checksum: prepared.originalSHA256)
        let now = Date(), ext = editedURL.pathExtension.lowercased()
        let newID = asNewVersion ? current.id : Self.stableImportID("attachment:\(jobID)").uuidString
        let stored = jobID.uuidString + "." + ext
        var updated = current
        updated.id = newID; updated.storedName = stored; updated.fileExtension = ext
        updated.byteCount = prepared.byteCount; updated.updatedAt = now
        updated.contentText = nil; updated.contentIndexedAt = nil
        if !asNewVersion {
            updated.originalName = editedURL.lastPathComponent
            updated.displayName = current.displayName + "（编辑附件）"
            updated.uploadedAt = now
        }
        let provenance = DocumentProvenance(documentID: newID, originalSHA256: prepared.originalSHA256,
                                           sourceBundleID: session.providerBundleID,
                                           sourceDeclaration: "用户重新选择保存的编辑副本；来源声明未经认证", importedAt: now,
                                           targetRecordID: current.id)
        let relation = AttachmentRevision(documentID: newID, originalDocumentID: current.id,
                                          originalSHA256: prepared.originalSHA256, derivedSHA256: prepared.editedSHA256,
                                          kind: asNewVersion ? "editedVersion" : "derivedAttachment", createdAt: now)
        let input = ResearchImportJournal.Input(id: jobID.uuidString, sourceURL: prepared.localCopy, documentID: newID, scopeID: folder.id,
                                                destinationRelativePath: destinationPath(folder: folder, stored: stored),
                                                sha256: prepared.editedSHA256, byteCount: prepared.byteCount,
                                                recordData: try Self.encodeImportRecord(.init(document: updated, folder: nil)),
                                                provenance: provenance, revision: relation,
                                                operation: asNewVersion ? .update : .revision, expectedOriginal: expected,
                                                recordVersion: Self.importRecordVersion(updated.updatedAt),
                                                originalRecordData: try Self.encodeImportRecord(.init(document: current, folder: nil)))
        try await preserveLibrarySnapshot(jobID: jobID, originals: [current])
        _ = try await journal.submit(requestID: jobID, items: [input])
        try client.markEditedCopyImported(prepared)
    }

    /// Shared production entry for the review sheet and isolated product tests.
    /// Receipt recovery runs before new copying; a received-only duplicate is
    /// still eligible for approval, while a committed receipt is a no-op.
    func applyExchangeResult(_ review: PendingExchangeResultReview, userApproved: Bool,
                             targetFolderID: String? = nil,
                             reselectedReferences: [String: URL] = [:]) async throws -> ResearchImportJournal.Outcome {
        guard userApproved else { throw ResearchDocumentImportError.approvalRequired }
        let result = review.result, manifest = result.package.manifest
        guard ["completed", "partial"].contains(manifest.status ?? ""), result.session.action != .openDocument else {
            throw ResearchDocumentImportError.resultNotApplicable
        }
        guard libraryIsWritable(), !isImportingDocuments, let envelopeID = UUID(uuidString: manifest.requestID) else { throw ResearchDocumentImportError.busy }
        let client = exchangeClient, session = try client.loadSession(result.session.requestID)
        let boundID: UUID?
        if let intent = session.resultIntents?[manifest.requestID] {
            guard intent.manifestSHA256 == session.resultManifestSHA256?[manifest.requestID],
                  let id = UUID(uuidString: intent.jobID) else { throw ResearchDocumentImportError.resultIntentConflict }
            boundID = id
        } else { boundID = nil }
        if let receipt = session.appliedResults?[manifest.requestID] {
            if session.action == .ocrFiles {
                let journal = try transactionJournal()
                guard let id = UUID(uuidString: receipt.receiptID),
                      let completed = try journal.job(requestID: id), completed.stage == .completed,
                      completed.outcome?.documentIDs == receipt.importedDocumentIDs else {
                    throw ResearchDocumentImportError.versionConflict
                }
                try validateCompletedOCRReplay(completed, result: result, journal: journal)
            }
            return .init(documentIDs: receipt.importedDocumentIDs, importedCount: 0,
                         duplicateCount: receipt.importedDocumentIDs.count, replayed: true)
        }
        let accessed = reselectedReferences.values.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessed.forEach { $0.stopAccessingSecurityScopedResource() } }
        isImportingDocuments = true
        defer { isImportingDocuments = false; activeImportRequestID = nil }
        let journal = try transactionJournal()
        var chosenFolder: DocumentFolder?
        if session.action == .chooseFiles {
            let id = try client.resolveFileSelectionTarget(requestID: session.requestID,
                                                           existingFolderIDs: Set(folders.map(\.id)), userConfirmedFolderID: targetFolderID)
            guard let folder = folders.first(where: { $0.id == id }) else { throw ResearchDocumentImportError.invalidTarget }
            chosenFolder = folder
        }
        let targetScope = try resultTargetScope(result, chosenFolder: chosenFolder)
        var ocrFingerprintV2 = session.action == .ocrFiles
            ? try client.semanticResultFingerprintV2(result, targetScope: targetScope) : nil
        // Before V4.04 jobs used the envelope UUID. Their journal does not
        // retain the full result manifest, so a new envelope cannot prove the
        // same intent from partial saved page metadata. Exact UUID recovery
        // remains valid; otherwise stop before copying or creating a new job.
        let jobID: UUID
        var verifiedSelections: [ResearchVerifiedSelection] = []
        if let boundID, try journal.job(requestID: boundID) != nil {
            if let currentFingerprintV2 = ocrFingerprintV2 {
                if let stored = session.resultIntents?[manifest.requestID]?.semanticFingerprintV2 {
                    guard stored == currentFingerprintV2 else { throw ResearchDocumentImportError.resultIntentConflict }
                } else if boundID == envelopeID {
                    // Pre-semantic journals used the exact envelope UUID.
                    // The received full manifest is already bound by both
                    // session digests. Restore only that exact immutable plan;
                    // do not promote it into evidence for a different wrapper.
                    ocrFingerprintV2 = nil
                } else {
                    // An exact legacy envelope can establish its own V2 binding
                    // only from the complete manifest and the original V1 job.
                    guard try client.historicalOCRSemanticFingerprintV2(requestID: session.requestID,
                        historicalManifest: manifest, targetScope: targetScope) == currentFingerprintV2 else {
                        throw ResearchDocumentImportError.legacyResultReviewRequired
                    }
                }
            }
            jobID = boundID
        }
        else if try journal.job(requestID: envelopeID) != nil {
            guard boundID == nil || boundID == envelopeID else { throw ResearchDocumentImportError.resultIntentConflict }
            jobID = envelopeID
        }
        else {
            if try hasLegacyEnvelopeJob(result, journal: journal) { throw ResearchDocumentImportError.legacyResultReviewRequired }
            if session.action == .chooseFiles {
                let references = result.selectedReferences
                guard result.package.stagedItems.count + references.count <= 256 else { throw ResearchExchangeClientError.tooManyItems }
                let initialBytes = result.package.stagedItems.reduce(Int64(0)) { $0 + $1.item.byteCount }
                verifiedSelections = try await Task.detached(priority: .userInitiated) {
                    var totalBytes = initialBytes
                    return try references.map { reference in
                        let selected = try client.verifySelectedReference(reference, userSelectedURL: reselectedReferences[reference.id],
                                                                          maximumBytes: 2_147_483_648 - totalBytes)
                        totalBytes += selected.byteCount
                        return selected
                    }
                }.value
            }
            let fingerprint = try ocrFingerprintV2 ?? client.semanticResultFingerprint(result, targetScope: targetScope,
                                                                                       verifiedSelections: verifiedSelections)
            let semanticID = Self.stableImportID("exchange-result-v1:" + fingerprint)
            if let ocrFingerprintV2 {
                let matching = session.resultIDs.compactMap { session.resultIntents?[$0] }
                    .filter { $0.semanticFingerprintV2 == ocrFingerprintV2 }
                let jobIDs = Set(matching.map(\.jobID))
                guard jobIDs.count <= 1 else { throw ResearchDocumentImportError.resultIntentConflict }
                if let storedID = jobIDs.first {
                    guard let restoredID = UUID(uuidString: storedID),
                          try journal.job(requestID: restoredID) != nil,
                          boundID == nil || boundID == restoredID else {
                        throw ResearchDocumentImportError.resultIntentConflict
                    }
                    jobID = restoredID
                } else {
                    // A hash-only legacy intent cannot prove that a refreshed
                    // package is a different business result. Require complete
                    // historical evidence before creating another OCR batch.
                    guard !(session.resultIntents?.values.contains { $0.semanticFingerprintV2 == nil } ?? false) else {
                        throw ResearchDocumentImportError.legacyResultReviewRequired
                    }
                    guard boundID == nil || boundID == semanticID else { throw ResearchDocumentImportError.resultIntentConflict }
                    jobID = semanticID
                }
            } else {
                guard boundID == nil || boundID == semanticID else { throw ResearchDocumentImportError.resultIntentConflict }
                jobID = semanticID
            }
        }
        activeImportRequestID = jobID
        let outcome: ResearchImportJournal.Outcome
        if let existing = try journal.job(requestID: jobID) {
            if let chosenFolder, !existing.items.allSatisfy({ $0.scopeID == chosenFolder.id }) { throw ResearchDocumentImportError.invalidTarget }
            if session.action == .ocrFiles, existing.stage == .completed {
                try validateCompletedOCRReplay(existing, result: result, journal: journal)
            }
            // Durable staging/plan is authoritative after interruption. A valid
            // completed job can repair a missing business receipt without replay.
            var incoming = Dictionary(uniqueKeysWithValues: result.package.stagedItems.map { ($0.item.id, $0.url) })
            for selected in verifiedSelections { incoming["reference:" + selected.referenceID] = selected.localCopy }
            let retainedRoot = ResearchExchangePaths.root.appendingPathComponent("ImportStaging/" + jobID.uuidString.lowercased())
            for item in existing.items where incoming[item.id] == nil {
                let retained = retainedRoot.appendingPathComponent(item.stagedRelativePath)
                if FileManager.default.fileExists(atPath: retained.path) { incoming[item.id] = retained }
                else if let reference = result.selectedReferences.first(where: { "reference:" + $0.id == item.id }) {
                    let selected = try client.verifySelectedReference(reference, userSelectedURL: reselectedReferences[reference.id], maximumBytes: item.byteCount)
                    guard selected.sha256 == item.sha256 else { throw ResearchDocumentImportError.versionConflict }
                    incoming[item.id] = selected.localCopy
                }
            }
            let inputs = existing.items.map { Self.restoredInput($0, source: incoming[$0.id] ?? result.package.stagingDirectory.appendingPathComponent("missing")) }
            try client.recordResultIntent(requestID: session.requestID, resultID: manifest.requestID, jobID: jobID,
                                          semanticFingerprintV2: ocrFingerprintV2)
            let resumed = try await journal.submit(requestID: jobID, items: inputs)
            outcome = resumed.replayed
                ? .init(documentIDs: resumed.documentIDs, importedCount: 0,
                        duplicateCount: resumed.documentIDs.count, replayed: true)
                : resumed
        } else {
            var inputs: [ResearchImportJournal.Input] = []
            switch session.action {
            case .chooseFiles:
                guard let folder = chosenFolder else { throw ResearchDocumentImportError.invalidTarget }
                var staged = result.package.stagedItems
                for copy in verifiedSelections {
                    let filename = URL(fileURLWithPath: copy.originalReference.displayName).lastPathComponent
                    let item = GaoActionItem(id: "reference:" + copy.referenceID,
                                             relativePath: "payload/" + copy.referenceID + "/" + filename,
                                             uti: UTType(filenameExtension: copy.localCopy.pathExtension)?.identifier ?? "public.data",
                                             byteCount: copy.byteCount, sha256: copy.sha256)
                    staged.append(.init(item: item, url: copy.localCopy))
                }
                guard !staged.isEmpty else { throw ResearchDocumentImportError.resultNotApplicable }
                for item in staged {
                    let id = Self.stableImportID("choose:\(jobID):\(item.item.id)").uuidString
                    let ext = item.url.pathExtension.lowercased()
                    guard Self.supportedExtensions.contains(ext) else { throw ResearchDocumentImportError.unsupportedFile }
                    let stored = id + "." + ext, now = Date()
                    let document = ManagedDocument(id: id, folderID: folder.id, originalName: item.originalFilename,
                                                   displayName: item.originalFilename, storedName: stored, fileExtension: ext,
                                                   tags: [], byteCount: item.item.byteCount, uploadedAt: now, updatedAt: now)
                    let provenance = DocumentProvenance(documentID: id, originalSHA256: item.item.sha256,
                                                       sourceBundleID: manifest.sourceBundleID, sourceDeclaration: "用户所选文件；来源声明未经认证")
                    inputs.append(.init(id: item.item.id, sourceURL: item.url, documentID: id, scopeID: folder.id,
                                        destinationRelativePath: destinationPath(folder: folder, stored: stored),
                                        sha256: item.item.sha256, byteCount: item.item.byteCount,
                                        recordData: try Self.encodeImportRecord(.init(document: document, folder: nil)), provenance: provenance))
                }
            case .ocrFiles:
                guard !result.ocrOutputs.isEmpty else { throw ResearchDocumentImportError.resultNotApplicable }
                for output in result.ocrOutputs {
                    guard let originalID = output.sourceDocumentID, let original = documents.first(where: { $0.id == originalID }),
                          let folder = folders.first(where: { $0.id == original.folderID }) else { throw ResearchDocumentImportError.missingDocument }
                    let expected = try expectedState(for: original, checksum: output.sourceSHA256)
                    let pages = try ocrPages(for: output, allOutputs: result.ocrOutputs)
                    let id = Self.stableImportID("ocr:\(jobID):\(output.itemID)").uuidString
                    let ext = output.localCopy.pathExtension.lowercased()
                    guard Self.supportedExtensions.contains(ext) else { throw ResearchDocumentImportError.unsupportedFile }
                    let stored = id + "." + ext, now = Date()
                    let text = pages.compactMap(\.text).joined(separator: "\n\n")
                    let document = ManagedDocument(id: id, folderID: folder.id,
                                                   originalName: "OCR-" + original.originalName + "." + ext,
                                                   displayName: original.displayName + "（OCR \(ext)）", storedName: stored, fileExtension: ext,
                                                   tags: ["OCR衍生件"], byteCount: output.byteCount, uploadedAt: now, updatedAt: now,
                                                   contentText: text.isEmpty ? nil : text)
                    let provenance = DocumentProvenance(documentID: id, originalSHA256: output.sourceSHA256,
                                                       sourceBundleID: manifest.sourceBundleID, sourceDeclaration: "已审核 OCR 衍生附件；原件保留；来源声明未经认证",
                                                       ocrEngine: output.engine, ocrVersion: output.engineVersion, ocrLanguages: output.languages,
                                                       pages: pages, targetRecordID: original.id)
                    let revision = AttachmentRevision(documentID: id, originalDocumentID: original.id,
                                                       originalSHA256: output.sourceSHA256, derivedSHA256: output.sha256, kind: "ocrDerived")
                    inputs.append(.init(id: output.itemID, sourceURL: output.localCopy, documentID: id, scopeID: folder.id,
                                        destinationRelativePath: destinationPath(folder: folder, stored: stored), sha256: output.sha256,
                                        byteCount: output.byteCount, recordData: try Self.encodeImportRecord(.init(document: document, folder: nil)),
                                        provenance: provenance, revision: revision, operation: .revision, expectedOriginal: expected,
                                        recordVersion: Self.importRecordVersion(document.updatedAt),
                                        originalRecordData: try Self.encodeImportRecord(.init(document: original, folder: nil))))
                }
            case .openDocument: throw ResearchDocumentImportError.resultNotApplicable
            }
            let originalIDs = Set(inputs.compactMap { $0.expectedOriginal?.documentID })
            try await preserveLibrarySnapshot(jobID: jobID, originals: documents.filter { originalIDs.contains($0.id) })
            try client.recordResultIntent(requestID: session.requestID, resultID: manifest.requestID, jobID: jobID,
                                          semanticFingerprintV2: ocrFingerprintV2)
            outcome = try await journal.submit(requestID: jobID, items: inputs)
        }
        _ = try client.markResultApplied(requestID: session.requestID, resultID: manifest.requestID,
                                        importedDocumentIDs: outcome.documentIDs, receiptID: jobID.uuidString)
        pendingExchangeResultReview = nil
        exchangeFeedbackMessage = "交接已导入 \(outcome.importedCount) 项；原件与恢复快照保留。"
        return outcome
    }

    /// A historical receipt describes a past commit. A fresh wrapper may reuse
    /// that commit only while its actual derived records and files still exist
    /// unchanged; it must never silently restore a user's deleted/edited copy.
    private func validateCompletedOCRReplay(_ job: ImportJob, result: ResearchValidatedExternalResult,
                                            journal: ResearchImportJournal) throws {
        guard job.recordsCommitted, let savedOutcome = job.outcome,
              Set(savedOutcome.documentIDs) == Set(job.items.map(\.documentID)),
              Set(job.items.map(\.id)) == Set(result.ocrOutputs.map(\.itemID)) else {
            throw ResearchDocumentImportError.versionConflict
        }
        let durable = try readDurableDocuments?() ?? documents
        for item in job.items {
            guard let output = result.ocrOutputs.first(where: { $0.itemID == item.id }),
                  output.sha256.lowercased() == item.sha256.lowercased(), output.byteCount == item.byteCount,
                  let originalID = output.sourceDocumentID,
                  item.revision?.originalDocumentID == originalID,
                  let original = durable.first(where: { $0.id == originalID }), original.folderID == item.scopeID,
                  let current = durable.first(where: { $0.id == item.documentID }),
                  current.folderID == item.scopeID, current.contentIndexedAt != nil else {
                throw ResearchDocumentImportError.versionConflict
            }
            var planned = try Self.decodeImportRecord(item.recordData).document
            var actual = current
            // Display order may change after normal saves or user sorting.
            // Compare copies only; retain current order and verify indexed
            // text separately. All other metadata and file identity stay strict.
            planned.contentText = nil; planned.contentIndexedAt = nil
            actual.contentText = nil; actual.contentIndexedAt = nil
            planned.sortOrder = nil; actual.sortOrder = nil
            guard try Self.canonicalDocument(actual) == Self.canonicalDocument(planned),
                  current.fileExtension.lowercased() == output.localCopy.pathExtension.lowercased(),
                  try journal.provenance(documentID: item.documentID) == item.provenance,
                  try journal.revision(documentID: item.documentID) == item.revision else {
                throw ResearchDocumentImportError.versionConflict
            }
            let url = managedDocumentURL(current)
            let relative = String(url.path.dropFirst(LibraryPaths.managedDocuments.path.count + 1))
            let bytes = try GaoActionFileAccess.fingerprint(at: url)
            guard relative == item.destinationRelativePath, bytes.sha256.lowercased() == item.sha256.lowercased(),
                  bytes.byteCount == item.byteCount else { throw ResearchDocumentImportError.versionConflict }
            let extracted = DocumentTextExtractor.extractText(from: url)
            let pageText = item.provenance.pages.compactMap(\.text).joined(separator: "\n\n")
            let frozenText = try Self.decodeImportRecord(item.recordData).document.contentText ?? ""
            let indexed = DocumentTextExtractor.indexedText(extracted: extracted, ocrText: pageText)
                ?? (frozenText.isEmpty ? nil : frozenText)
            guard current.contentText == indexed else { throw ResearchDocumentImportError.versionConflict }
        }
    }

    private func expectedState(for document: ManagedDocument, checksum: String) throws -> ResearchImportJournal.RecordState {
        let url = managedDocumentURL(document)
        let actual = try GaoActionFileAccess.fingerprint(at: url)
        guard actual.sha256 == checksum else { throw ResearchDocumentImportError.versionConflict }
        return .init(documentID: document.id, scopeID: document.folderID, sha256: actual.sha256,
                     destinationRelativePath: String(url.path.dropFirst(LibraryPaths.managedDocuments.path.count + 1)),
                     version: Self.importRecordVersion(document.updatedAt))
    }

    private func resultTargetScope(_ result: ResearchValidatedExternalResult, chosenFolder: DocumentFolder?) throws -> String {
        if result.session.action == .chooseFiles {
            guard let chosenFolder else { throw ResearchDocumentImportError.invalidTarget }
            return "folder:" + chosenFolder.id
        }
        var scope: [[String: String]] = []
        for output in result.ocrOutputs {
            guard let sourceID = output.sourceDocumentID, let source = documents.first(where: { $0.id == sourceID }),
                  folders.contains(where: { $0.id == source.folderID }) else { throw ResearchDocumentImportError.missingDocument }
            scope.append(["itemID": output.itemID, "documentID": source.id, "folderID": source.folderID])
        }
        let data = try JSONSerialization.data(withJSONObject: scope.sorted { $0["itemID"]! < $1["itemID"]! }, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    private func hasLegacyEnvelopeJob(_ result: ResearchValidatedExternalResult,
                                      journal: ResearchImportJournal) throws -> Bool {
        let session = try exchangeClient.loadSession(result.session.requestID)
        for resultID in session.resultIDs where resultID != result.package.manifest.requestID {
            guard let candidate = UUID(uuidString: resultID) else { throw ResearchExchangeClientError.invalidSession }
            if try journal.job(requestID: candidate) != nil { return true }
        }
        return false
    }

    private func destinationPath(folder: DocumentFolder, stored: String) -> String {
        "\(folder.libraryKind.rawValue)/\(URL(fileURLWithPath: folder.id).lastPathComponent)/\(stored)"
    }

    private func preserveLibrarySnapshot(jobID: UUID, originals: [ManagedDocument]) async throws {
        let directory = ResearchExchangePaths.root.appendingPathComponent("Snapshots/" + jobID.uuidString)
        let snapshot = directory.appendingPathComponent("library-before.json")
        if FileManager.default.fileExists(atPath: snapshot.path) {
            _ = try GaoActionFileAccess.readPrivateData(at: snapshot, maximumBytes: 128 * 1_048_576)
        } else {
            guard let read = readDurableLibraryData else { throw ResearchDocumentImportError.unavailableLibrary }
            let data = try read()
            // Decode before preserving; unreadable/too-new libraries never become blank snapshots.
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            let library = try decoder.decode(PersistedLibrary.self, from: data)
            guard library.version <= LibrarySchema.currentVersion else { throw ResearchDocumentImportError.unavailableLibrary }
            try GaoActionFileAccess.writePrivateData(data, to: snapshot)
            guard try GaoActionFileAccess.readPrivateData(at: snapshot, maximumBytes: 128 * 1_048_576) == data else { throw GaoActionError.checksumMismatch }
        }
        let copies = try originals.map { document in
            (managedDocumentURL(document), directory.appendingPathComponent(Self.stableImportID("original:" + document.id).uuidString + ".data"),
             try Self.encodeImportRecord(.init(document: document, folder: nil)))
        }
        try await Task.detached(priority: .utility) {
            for (source, destination, record) in copies {
                let expected = try GaoActionFileAccess.fingerprint(at: source)
                if FileManager.default.fileExists(atPath: destination.path) {
                    let previous = try GaoActionFileAccess.fingerprint(at: destination)
                    guard previous.sha256 == expected.sha256 else { throw GaoActionError.checksumMismatch }
                } else {
                    let copied = try GaoActionFileAccess.copyRegularFile(at: source, to: destination)
                    guard copied.sha256 == expected.sha256 else { throw GaoActionError.sourceChanged }
                }
                let recordURL = destination.deletingPathExtension().appendingPathExtension("record.json")
                if FileManager.default.fileExists(atPath: recordURL.path) {
                    guard try GaoActionFileAccess.readPrivateData(at: recordURL, maximumBytes: 16 * 1_048_576) == record else { throw GaoActionError.sourceChanged }
                } else { try GaoActionFileAccess.writePrivateData(record, to: recordURL) }
            }
        }.value
    }

    private static func stableImportID(_ value: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(value.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func restoredInput(_ item: ResearchImportJournal.CommittedItem, source: URL) -> ResearchImportJournal.Input {
        .init(id: item.id, sourceURL: source, documentID: item.documentID, scopeID: item.scopeID,
              destinationRelativePath: item.destinationRelativePath, sha256: item.sha256, byteCount: item.byteCount,
              recordData: item.recordData, provenance: item.provenance, revision: item.revision,
              operation: item.operation, expectedOriginal: item.expectedOriginal,
              recordVersion: item.recordVersion, originalRecordData: item.originalRecordData)
    }

    func ocrPagesForReview(for output: ResearchOCROutput, allOutputs: [ResearchOCROutput]) throws -> [DocumentProvenance.Page] {
        try ocrPages(for: output, allOutputs: allOutputs)
    }

    private func ocrPages(for output: ResearchOCROutput, allOutputs: [ResearchOCROutput]) throws -> [DocumentProvenance.Page] {
        var pages = output.pages.map { page in
            DocumentProvenance.Page(pageNumber: page.pageNumber, text: page.text,
                                    bounds: page.regions.first.flatMap { region in
                guard page.coordinateSpace == "normalized", case .number(let x)? = region["x"], case .number(let y)? = region["y"],
                      case .number(let width)? = region["width"], case .number(let height)? = region["height"] else { return nil }
                return [x, y, width, height]
            }, confidence: page.confidence, status: page.status)
        }
        // JSON output contains the producer's real per-page text. Preserve it
        // only after matching original SHA and source ID, never by filename.
        for json in allOutputs where json.sourceItemID == output.sourceItemID && ["public.json", "application/json"].contains(json.uti) {
            let data = try GaoActionFileAccess.readPrivateData(at: json.localCopy, maximumBytes: 16 * 1_048_576)
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["schemaVersion"] as? Int == 1, let sources = object["sources"] as? [[String: Any]],
                  let jsonPages = object["pages"] as? [[String: Any]] else { throw ResearchExchangeClientError.invalidOCRMapping }
            let matches = sources.filter { ($0["sha256"] as? String)?.lowercased() == output.sourceSHA256 }
            guard matches.count == 1, let sourceID = matches[0]["id"] as? String else { throw ResearchExchangeClientError.invalidOCRMapping }
            for page in jsonPages where page["sourceID"] as? String == sourceID {
                guard let number = page["pageNumber"] as? Int, number > 0,
                      (page["originalSHA256"] as? String)?.lowercased() == output.sourceSHA256,
                      let status = page["status"] as? String, ["completed", "failed", "cancelled"].contains(status),
                      let lines = page["lines"] as? [[String: Any]] else { throw ResearchExchangeClientError.invalidOCRMapping }
                let ordered = lines.sorted { ($0["readingOrder"] as? Int ?? 0) < ($1["readingOrder"] as? Int ?? 0) }
                let texts = try ordered.map { line -> String in
                    guard let text = line["text"] as? String else { throw ResearchExchangeClientError.invalidOCRMapping }
                    return text
                }
                if let index = pages.firstIndex(where: { $0.pageNumber == number }) {
                    guard pages[index].status == status else { throw ResearchExchangeClientError.invalidOCRMapping }
                    pages[index].text = texts.joined(separator: "\n")
                } else { pages.append(.init(pageNumber: number, text: texts.joined(separator: "\n"), status: status)) }
            }
        }
        return pages.sorted { $0.pageNumber < $1.pageNumber }
    }
}
