import AppKit
import Foundation
import UniformTypeIdentifiers

// MARK: - DocumentLibraryStore：资料库文件夹与文档
//
// 拥有 documentFolders / managedDocuments 状态、导入（后台抽文本）、排序与
// 检索辅助。PaperStore 通过计算属性转发读写；落盘与错误提示通过 persist /
// errorHandler 单向回调上行。全文索引（DocumentSearch.swift）是其扩展。

@MainActor
final class DocumentLibraryStore: ObservableObject {
    @Published var folders: [DocumentFolder] = []
    @Published var documents: [ManagedDocument] = []
    @Published var isIndexing = false
    @Published var indexingMessage = ""

    var persist: () -> Void = {}
    var errorHandler: (String) -> Void = { _ in }

    static let supportedExtensions: Set<String> = [
        "doc", "docx", "xls", "xlsx", "csv", "tsv", "ppt", "pptx",
        "pdf", "md", "markdown", "txt", "rtf", "rtfd",
        "json", "xml", "yaml", "yml",
        "png", "jpg", "jpeg", "heic", "tif", "tiff",
        "zip", "7z", "epub",
    ]

    func folders(for kind: DocumentLibraryKind, search: String = "") -> [DocumentFolder] {
        let needle = Self.normalizedSearch(search)
        let base = Self.sortedFolders(folders, for: kind)
        let filtered: [DocumentFolder]
        if needle.isEmpty {
            filtered = base
        } else {
            filtered = base.filter { folder in
                if folder.name.lowercased().contains(needle) { return true }
                return documents.contains { document in
                    document.folderID == folder.id
                        && Self.searchableText(for: document).contains(needle)
                }
            }
        }
        return filtered
    }

    func documents(
        in folderID: String,
        search: String = "",
        tag: String? = nil,
        sort: ManagedDocumentSort = .uploadTime
    ) -> [ManagedDocument] {
        let needle = Self.normalizedSearch(search)
        var result = documents.filter { document in
            guard document.folderID == folderID else { return false }
            if let tag, !tag.isEmpty,
               !document.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) {
                return false
            }
            return needle.isEmpty || Self.searchableText(for: document).contains(needle)
        }
        switch sort {
        case .uploadTime:
            // 手动 sortOrder 优先；无手动序的按上传时间降序回退。
            result.sort(by: Self.manualThenUploadTimeOrder)
        case .tag:
            result.sort {
                let left = $0.tags.first?.lowercased() ?? "\u{10FFFF}"
                let right = $1.tags.first?.lowercased() ?? "\u{10FFFF}"
                if left != right { return left.localizedCompare(right) == .orderedAscending }
                if $0.uploadedAt != $1.uploadedAt { return $0.uploadedAt > $1.uploadedAt }
                return $0.displayName.localizedCompare($1.displayName) == .orderedAscending
            }
        }
        return result
    }

    func tags(in folderID: String) -> [String] {
        var values: [String: String] = [:]
        for tag in documents.filter({ $0.folderID == folderID }).flatMap(\.tags) {
            let key = tag.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if values[key] == nil { values[key] = tag }
        }
        return values.values.sorted { $0.localizedCompare($1) == .orderedAscending }
    }

    func documentCount(in folderID: String) -> Int {
        documents.filter { $0.folderID == folderID }.count
    }

    func documentCount(for kind: DocumentLibraryKind) -> Int {
        let folderIDs = Set(folders.filter { $0.libraryKind == kind }.map(\.id))
        return documents.filter { folderIDs.contains($0.folderID) }.count
    }

    func storageSize(for kind: DocumentLibraryKind) -> Int64 {
        let folderIDs = Set(folders.filter { $0.libraryKind == kind }.map(\.id))
        return documents.filter { folderIDs.contains($0.folderID) }
            .reduce(0) { $0 + max(0, $1.byteCount) }
    }

    @discardableResult
    func createDocumentFolder(kind: DocumentLibraryKind, name: String) -> String? {
        let cleanName = Self.cleanedDisplayText(name)
        guard !cleanName.isEmpty else {
            errorHandler(AppLocalization.text("文件夹名称不能为空。"))
            return nil
        }
        guard !folders.contains(where: {
            $0.libraryKind == kind && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
        }) else {
            errorHandler(AppLocalization.format("“%@”文件夹已经存在。", cleanName))
            return nil
        }
        let now = Date()
        let folder = DocumentFolder(
            id: UUID().uuidString,
            libraryKind: kind,
            name: cleanName,
            createdAt: now,
            updatedAt: now,
            sortOrder: nextFolderSortOrder(for: kind)
        )
        folders.append(folder)
        persist()
        return folder.id
    }

    func renameDocumentFolder(id: String, name: String) -> Bool {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return false }
        let cleanName = Self.cleanedDisplayText(name)
        guard !cleanName.isEmpty else {
            errorHandler(AppLocalization.text("文件夹名称不能为空。"))
            return false
        }
        let kind = folders[index].libraryKind
        guard !folders.contains(where: {
            $0.id != id && $0.libraryKind == kind && $0.name.caseInsensitiveCompare(cleanName) == .orderedSame
        }) else {
            errorHandler(AppLocalization.format("“%@”文件夹已经存在。", cleanName))
            return false
        }
        folders[index].name = cleanName
        folders[index].updatedAt = Date()
        persist()
        return true
    }

    func moveDocumentFolder(sourceID: String, before targetID: String, persist: Bool = true) {
        guard sourceID != targetID,
              let source = folders.first(where: { $0.id == sourceID }),
              let target = folders.first(where: { $0.id == targetID }),
              source.libraryKind == target.libraryKind
        else { return }

        var ordered = Self.sortedFolders(folders, for: source.libraryKind)
        guard let sourceIndex = ordered.firstIndex(where: { $0.id == sourceID }) else { return }
        let moving = ordered.remove(at: sourceIndex)
        guard let targetIndex = ordered.firstIndex(where: { $0.id == targetID }) else { return }
        ordered.insert(moving, at: targetIndex)
        Self.applyFolderOrdering(ordered, kind: source.libraryKind, to: &folders)
        // persist=false 时只改内存与排序归一化；拖动结束时由调用方统一落盘。
        if persist { self.persist() }
    }

    func normalizeFolderOrdering() {
        folders = Self.normalizedFolderOrdering(folders)
    }

    /// 文件夹内文件拖动排序：与 moveDocumentFolder 同套语义，按文件夹分桶维护 sortOrder。
    func moveManagedDocument(sourceID: String, before targetID: String, persist: Bool = true) {
        guard sourceID != targetID,
              let source = documents.first(where: { $0.id == sourceID }),
              let target = documents.first(where: { $0.id == targetID }),
              source.folderID == target.folderID
        else { return }

        var ordered = Self.sortedDocuments(documents, in: source.folderID)
        guard let sourceIndex = ordered.firstIndex(where: { $0.id == sourceID }) else { return }
        let moving = ordered.remove(at: sourceIndex)
        guard let targetIndex = ordered.firstIndex(where: { $0.id == targetID }) else { return }
        ordered.insert(moving, at: min(targetIndex, ordered.count))
        Self.applyDocumentOrdering(ordered, folderID: source.folderID, to: &documents)
        // persist=false 时只改内存与排序归一化；拖动结束时由调用方统一落盘。
        if persist { self.persist() }
    }

    func normalizeDocumentOrdering() {
        documents = Self.normalizedDocumentOrdering(documents)
    }

    func chooseDocuments(for folderID: String) {
        guard let folder = folders.first(where: { $0.id == folderID }) else { return }
        let panel = NSOpenPanel()
        panel.title = AppLocalization.format("向“%@”上传文件", folder.name)
        panel.prompt = AppLocalization.text("上传")
        panel.message = AppLocalization.text("支持 Word、Excel、PPT、PDF、Markdown、文本、图片及常见资料格式")
        panel.allowedContentTypes = Self.supportedExtensions.compactMap {
            UTType(filenameExtension: $0)
        }
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK else { return }

        Task {
            do {
                let count = try await importDocuments(from: panel.urls, into: folderID)
                if count == 0 { errorHandler(AppLocalization.text("没有可导入的受支持文件。")) }
            } catch {
                errorHandler(AppLocalization.format("文件上传失败：%@", error.localizedDescription))
            }
        }
    }

    /// 复制与正文抽取（PDFKit / 解压 / mdls 子进程）移到后台执行，避免阻塞主线程；
    /// 任一步失败时删除已复制文件，维持原有的回滚语义；完成后回 MainActor 更新并落盘。
    @discardableResult
    func importDocuments(from sourceURLs: [URL], into folderID: String) async throws -> Int {
        guard let folder = folders.first(where: { $0.id == folderID }) else { return 0 }
        let sources = sourceURLs.filter {
            Self.supportedExtensions.contains($0.pathExtension.lowercased())
        }
        guard !sources.isEmpty else { return 0 }

        let destinationDirectory = folderURL(for: folder)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let additions = try await Task.detached(priority: .userInitiated) { () -> [ManagedDocument] in
            var prepared: [ManagedDocument] = []
            var copiedURLs: [URL] = []
            do {
                for sourceURL in sources {
                    let accessed = sourceURL.startAccessingSecurityScopedResource()
                    defer { if accessed { sourceURL.stopAccessingSecurityScopedResource() } }
                    let ext = sourceURL.pathExtension.lowercased()
                    let storedName = "\(UUID().uuidString).\(ext)"
                    let destinationURL = destinationDirectory.appendingPathComponent(storedName)
                    try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
                    copiedURLs.append(destinationURL)
                    let values = try? destinationURL.resourceValues(forKeys: [.fileSizeKey])
                    let now = Date()
                    prepared.append(ManagedDocument(
                        id: UUID().uuidString,
                        folderID: folderID,
                        originalName: sourceURL.lastPathComponent,
                        displayName: sourceURL.lastPathComponent,
                        storedName: storedName,
                        fileExtension: ext,
                        tags: [],
                        byteCount: Int64(values?.fileSize ?? 0),
                        uploadedAt: now,
                        updatedAt: now,
                        contentText: DocumentTextExtractor.extractText(from: destinationURL),
                        contentIndexedAt: now
                    ))
                }
            } catch {
                for url in copiedURLs { try? FileManager.default.removeItem(at: url) }
                throw error
            }
            return prepared
        }.value

        // 新上传的文件排在该文件夹手动序的最前（与上传时间降序的默认观感一致）。
        var orderedAdditions = additions
        var nextOrder = (documents
            .filter { $0.folderID == folderID }
            .compactMap(\.sortOrder)
            .min() ?? 0) - 1
        for index in orderedAdditions.indices {
            orderedAdditions[index].sortOrder = nextOrder
            nextOrder -= 1
        }
        documents.append(contentsOf: orderedAdditions)
        Self.applyDocumentOrdering(Self.sortedDocuments(documents, in: folderID), folderID: folderID, to: &documents)
        if let index = folders.firstIndex(where: { $0.id == folderID }) {
            folders[index].updatedAt = Date()
        }
        persist()
        return additions.count
    }

    func updateDocument(id: String, displayName: String, tags: [String]) -> Bool {
        guard let index = documents.firstIndex(where: { $0.id == id }) else { return false }
        let cleanName = Self.cleanedDisplayText(displayName)
        guard !cleanName.isEmpty else {
            errorHandler(AppLocalization.text("文件名称不能为空。"))
            return false
        }
        documents[index].displayName = cleanName
        documents[index].tags = Self.normalizedTags(tags)
        documents[index].updatedAt = Date()
        if let folderIndex = folders.firstIndex(where: { $0.id == documents[index].folderID }) {
            folders[folderIndex].updatedAt = Date()
        }
        persist()
        return true
    }

    func openDocument(_ document: ManagedDocument) {
        let url = managedDocumentURL(document)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorHandler(AppLocalization.format("找不到文件“%@”。", document.displayName))
            return
        }
        NSWorkspace.shared.open(url)
    }

    func revealDocument(_ document: ManagedDocument) {
        let url = managedDocumentURL(document)
        guard FileManager.default.fileExists(atPath: url.path) else {
            errorHandler(AppLocalization.format("找不到文件“%@”。", document.displayName))
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func managedDocumentURL(_ document: ManagedDocument) -> URL {
        guard let folder = folders.first(where: { $0.id == document.folderID }) else {
            return LibraryPaths.managedDocuments.appendingPathComponent("missing", isDirectory: true)
        }
        return folderURL(for: folder)
            .appendingPathComponent(URL(fileURLWithPath: document.storedName).lastPathComponent)
    }

    func folderURL(for folder: DocumentFolder) -> URL {
        LibraryPaths.managedDocuments
            .appendingPathComponent(folder.libraryKind.rawValue, isDirectory: true)
            .appendingPathComponent(URL(fileURLWithPath: folder.id).lastPathComponent, isDirectory: true)
    }

    // MARK: 静态纯函数（排序归一化供迁移链复用）

    nonisolated static func normalizedSearch(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    nonisolated static func sortedFolders(_ folders: [DocumentFolder], for kind: DocumentLibraryKind) -> [DocumentFolder] {
        folders
            .filter { $0.libraryKind == kind }
            .sorted { left, right in
                switch (left.sortOrder, right.sortOrder) {
                case let (leftOrder?, rightOrder?):
                    if leftOrder != rightOrder { return leftOrder < rightOrder }
                    return left.createdAt < right.createdAt
                case (_?, nil):
                    return true
                case (nil, _?):
                    return false
                case (nil, nil):
                    if left.updatedAt != right.updatedAt { return left.updatedAt > right.updatedAt }
                    return left.name.localizedCompare(right.name) == .orderedAscending
                }
            }
    }

    nonisolated static func applyFolderOrdering(_ ordered: [DocumentFolder], kind: DocumentLibraryKind, to folders: inout [DocumentFolder]) {
        let orderByID = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        for index in folders.indices where folders[index].libraryKind == kind {
            folders[index].sortOrder = orderByID[folders[index].id]
        }
    }

    nonisolated static func normalizedFolderOrdering(_ folders: [DocumentFolder]) -> [DocumentFolder] {
        var result = folders
        for kind in DocumentLibraryKind.allCases {
            applyFolderOrdering(sortedFolders(result, for: kind), kind: kind, to: &result)
        }
        return result
    }

    /// 手动 sortOrder 优先、上传时间降序回退的比较器（.uploadTime 排序与归一化共用）。
    nonisolated static func manualThenUploadTimeOrder(_ left: ManagedDocument, _ right: ManagedDocument) -> Bool {
        switch (left.sortOrder, right.sortOrder) {
        case let (leftOrder?, rightOrder?):
            if leftOrder != rightOrder { return leftOrder < rightOrder }
            if left.uploadedAt != right.uploadedAt { return left.uploadedAt > right.uploadedAt }
            return left.displayName.localizedCompare(right.displayName) == .orderedAscending
        case (_?, nil):
            return true
        case (nil, _?):
            return false
        case (nil, nil):
            if left.uploadedAt != right.uploadedAt { return left.uploadedAt > right.uploadedAt }
            return left.displayName.localizedCompare(right.displayName) == .orderedAscending
        }
    }

    nonisolated static func sortedDocuments(_ documents: [ManagedDocument], in folderID: String) -> [ManagedDocument] {
        documents
            .filter { $0.folderID == folderID }
            .sorted(by: manualThenUploadTimeOrder)
    }

    nonisolated static func applyDocumentOrdering(_ ordered: [ManagedDocument], folderID: String, to documents: inout [ManagedDocument]) {
        let orderByID = Dictionary(uniqueKeysWithValues: ordered.enumerated().map { ($0.element.id, $0.offset) })
        for index in documents.indices where documents[index].folderID == folderID {
            documents[index].sortOrder = orderByID[documents[index].id]
        }
    }

    nonisolated static func normalizedDocumentOrdering(_ documents: [ManagedDocument]) -> [ManagedDocument] {
        var result = documents
        for folderID in Set(result.map(\.folderID)) {
            applyDocumentOrdering(sortedDocuments(result, in: folderID), folderID: folderID, to: &result)
        }
        return result
    }

    private func nextFolderSortOrder(for kind: DocumentLibraryKind) -> Int {
        (folders
            .filter { $0.libraryKind == kind }
            .compactMap(\.sortOrder)
            .max() ?? -1) + 1
    }

    nonisolated static func searchableText(for document: ManagedDocument) -> String {
        [document.displayName, document.originalName, document.fileExtension,
         document.tags.joined(separator: " "), document.contentText ?? ""]
            .joined(separator: " ")
            .lowercased()
    }

    nonisolated static func cleanedDisplayText(_ value: String) -> String {
        value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    nonisolated static func normalizedTags(_ tags: [String]) -> [String] {
        var result: [String] = []
        for tag in tags {
            let clean = cleanedDisplayText(tag)
            guard !clean.isEmpty,
                  !result.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { continue }
            result.append(clean)
        }
        return result
    }
}

// MARK: - PaperStore 转发扩展

@MainActor
extension PaperStore {
    static let supportedDocumentExtensions = DocumentLibraryStore.supportedExtensions

    /// 资料库文件夹/文档由 DocumentLibraryStore 持有；读写经此转发，语义与原 @Published 存储一致。
    var documentFolders: [DocumentFolder] {
        get { documentLibrary.folders }
        set { documentLibrary.folders = newValue }
    }

    var managedDocuments: [ManagedDocument] {
        get { documentLibrary.documents }
        set { documentLibrary.documents = newValue }
    }

    var isIndexingDocuments: Bool {
        documentLibrary.isIndexing
    }

    var indexingMessage: String {
        documentLibrary.indexingMessage
    }

    func folders(for kind: DocumentLibraryKind, search: String = "") -> [DocumentFolder] {
        documentLibrary.folders(for: kind, search: search)
    }

    func documents(
        in folderID: String,
        search: String = "",
        tag: String? = nil,
        sort: ManagedDocumentSort = .uploadTime
    ) -> [ManagedDocument] {
        documentLibrary.documents(in: folderID, search: search, tag: tag, sort: sort)
    }

    func tags(in folderID: String) -> [String] {
        documentLibrary.tags(in: folderID)
    }

    func documentCount(in folderID: String) -> Int {
        documentLibrary.documentCount(in: folderID)
    }

    func documentCount(for kind: DocumentLibraryKind) -> Int {
        documentLibrary.documentCount(for: kind)
    }

    func storageSize(for kind: DocumentLibraryKind) -> Int64 {
        documentLibrary.storageSize(for: kind)
    }

    @discardableResult
    func createDocumentFolder(kind: DocumentLibraryKind, name: String) -> String? {
        documentLibrary.createDocumentFolder(kind: kind, name: name)
    }

    func renameDocumentFolder(id: String, name: String) -> Bool {
        documentLibrary.renameDocumentFolder(id: id, name: name)
    }

    func moveDocumentFolder(sourceID: String, before targetID: String, persist: Bool = true) {
        documentLibrary.moveDocumentFolder(sourceID: sourceID, before: targetID, persist: persist)
    }

    func normalizeDocumentFolderOrdering() {
        documentLibrary.normalizeFolderOrdering()
    }

    func moveManagedDocument(sourceID: String, before targetID: String, persist: Bool = true) {
        documentLibrary.moveManagedDocument(sourceID: sourceID, before: targetID, persist: persist)
    }

    func normalizeManagedDocumentOrdering() {
        documentLibrary.normalizeDocumentOrdering()
    }

    func deleteDocumentFolder(id: String) {
        moveDocumentFolderToTrash(id: id)
    }

    func chooseDocuments(for folderID: String) {
        documentLibrary.chooseDocuments(for: folderID)
    }

    @discardableResult
    func importDocuments(from sourceURLs: [URL], into folderID: String) async throws -> Int {
        try await documentLibrary.importDocuments(from: sourceURLs, into: folderID)
    }

    func updateDocument(id: String, displayName: String, tags: [String]) -> Bool {
        documentLibrary.updateDocument(id: id, displayName: displayName, tags: tags)
    }

    func openDocument(_ document: ManagedDocument) {
        documentLibrary.openDocument(document)
    }

    func revealDocument(_ document: ManagedDocument) {
        documentLibrary.revealDocument(document)
    }

    func deleteDocument(_ document: ManagedDocument) {
        moveDocumentToTrash(document)
    }

    func managedDocumentURL(_ document: ManagedDocument) -> URL {
        documentLibrary.managedDocumentURL(document)
    }
}
