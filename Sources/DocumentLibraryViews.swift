import SwiftUI
import UniformTypeIdentifiers

struct DocumentFolderEditor: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss

    private let kind: DocumentLibraryKind
    private let folderID: String?
    @State private var name: String

    init(kind: DocumentLibraryKind, folder: DocumentFolder?) {
        self.kind = kind
        folderID = folder?.id
        _name = State(initialValue: folder?.name ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(AppLocalization.text(folderID == nil ? "新建文件夹" : "重命名文件夹"))
                    .font(.title2.weight(.semibold))
                Text(AppLocalization.format("用于整理%@中的一组相关文件", kind.title))
                    .foregroundStyle(.secondary)
            }
            TextField(AppLocalization.text("文件夹名称"), text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(save)
            HStack {
                Spacer()
                Button(AppLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.text(folderID == nil ? "创建" : "保存"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func save() {
        if let folderID {
            if store.renameDocumentFolder(id: folderID, name: name) { dismiss() }
        } else if store.createDocumentFolder(kind: kind, name: name) != nil {
            dismiss()
        }
    }
}

struct ManagedDocumentEditor: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss

    private let documentID: String
    @State private var displayName: String
    @State private var tagsText: String

    init(document: ManagedDocument) {
        documentID = document.id
        _displayName = State(initialValue: document.displayName)
        _tagsText = State(initialValue: document.tags.joined(separator: "，"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(AppLocalization.text("编辑文件信息"))
                    .font(.title2.weight(.semibold))
                Text(AppLocalization.text("修改显示名称不会改变文件格式或文件内容"))
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text(AppLocalization.text("文件名称")).font(.headline)
                TextField(AppLocalization.text("文件名称"), text: $displayName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text(AppLocalization.text("自定义标签")).font(.headline)
                TextField(AppLocalization.text("例如：原始数据，已清洗，汇报版"), text: $tagsText)
                    .textFieldStyle(.roundedBorder)
                Text(AppLocalization.text("多个标签可用逗号、分号或换行分隔"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(AppLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.text("保存"), action: save)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 560)
    }

    private func save() {
        let separators = CharacterSet(charactersIn: ",，;；\n")
        let tags = tagsText.components(separatedBy: separators)
        if store.updateDocument(id: documentID, displayName: displayName, tags: tags) {
            dismiss()
        }
    }
}

struct DocumentLibraryDashboard: View {
    @EnvironmentObject private var store: PaperStore

    let kind: DocumentLibraryKind
    let search: String
    let createFolderAction: () -> Void
    let editFolderAction: (DocumentFolder) -> Void
    let editDocumentAction: (ManagedDocument) -> Void

    @State private var selectedFolderID: String?
    @State private var sort: ManagedDocumentSort = .uploadTime
    @State private var selectedTag: String?
    @State private var deleteRequest: DeleteRequest?
    @State private var draggedFolderID: String?
    @State private var draggedDocumentID: String?
    @State private var previewDocument: ManagedDocument?
    // V4.6 batch-T：文件拖动排序已接入后端 ManagedDocument.sortOrder
    // （store.documents(in:sort:.uploadTime) 手动序优先，moveManagedDocument 归一化并落盘）。

    /// 手动排序仅在默认上传时间排序且无搜索/标签筛选时生效（与拖动时的显示顺序一致）。
    private var isManualDocumentOrderEnabled: Bool {
        sort == .uploadTime
            && search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedTag == nil
    }

    private var selectedFolder: DocumentFolder? {
        guard let selectedFolderID else { return nil }
        return store.documentFolders.first { $0.id == selectedFolderID && $0.libraryKind == kind }
    }

    var body: some View {
        Group {
            if let folder = selectedFolder {
                folderContents(folder)
            } else {
                folderGrid
            }
        }
        .alert(item: $deleteRequest) { request in
            Alert(
                title: Text(AppLocalization.text(request.isFolder ? "删除文件夹？" : "删除文件？")),
                message: Text(request.isFolder
                    ? AppLocalization.format("“%@”及其中的文件会移入回收站，可在30天内恢复。", request.name)
                    : AppLocalization.format("“%@”会移入回收站，可在30天内恢复。", request.name)),
                primaryButton: .destructive(Text(AppLocalization.text("删除"))) {
                    if request.isFolder {
                        if selectedFolderID == request.id { selectedFolderID = nil }
                        store.deleteDocumentFolder(id: request.id)
                    } else if let document = store.managedDocuments.first(where: { $0.id == request.id }) {
                        store.deleteDocument(document)
                    }
                },
                secondaryButton: .cancel(Text(AppLocalization.text("取消")))
            )
        }
        .sheet(item: $previewDocument) { document in
            QuickLookPreviewSheet(
                url: store.managedDocumentURL(document),
                title: document.displayName
            )
        }
    }

    private var folderGrid: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if kind == .importantLiterature {
                    HStack(alignment: .top, spacing: 11) {
                        Image(systemName: "info.circle.fill")
                            .foregroundStyle(AppTheme.blue)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(AppLocalization.text("轻量文献管理"))
                                .font(.headline)
                            Text(AppLocalization.text("本软件是轻量工具，请勿存放大量文献，仅保存对当前研究真正重要的参考文献。"))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(15)
                    .background(AppTheme.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.blue.opacity(0.15)))
                }

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(AppLocalization.text("文件夹"))
                            .font(.title3.weight(.semibold))
                        Text(kind.folderPrompt)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(action: createFolderAction) {
                        Label(AppLocalization.text("新建文件夹"), systemImage: "folder.badge.plus")
                    }
                    .buttonStyle(.borderedProminent)
                }

                let folders = store.folders(for: kind, search: search)
                if folders.isEmpty {
                    emptyFolderState(isSearching: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 220, maximum: 260), spacing: 14)],
                        alignment: .leading,
                        spacing: 14
                    ) {
                        ForEach(folders) { folder in
                            folderCard(folder)
                        }
                    }
                }
            }
            .frame(maxWidth: 1100, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.bottom, 28)
        }
    }

    private func folderCard(_ folder: DocumentFolder) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                selectedFolderID = folder.id
                selectedTag = nil
                sort = .uploadTime
            } label: {
                HStack(spacing: 14) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 25, weight: .medium))
                        .foregroundStyle(AppTheme.blue)
                        .frame(width: 48, height: 48)
                        .background(AppTheme.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(folder.name)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(AppLocalization.format("%d 个文件", store.documentCount(in: folder.id)))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Text(Formatters.dateTime.string(from: folder.updatedAt))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 26)
                    Image(systemName: "chevron.right")
                        .font(.caption.bold())
                        .foregroundStyle(.tertiary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, minHeight: 104, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
            }
            .buttonStyle(.plain)

            Menu {
                Button(AppLocalization.text("重命名"), systemImage: "pencil") { editFolderAction(folder) }
                Divider()
                Button(AppLocalization.text("删除文件夹"), systemImage: "trash", role: .destructive) {
                    deleteRequest = DeleteRequest(id: folder.id, name: folder.name, isFolder: true)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .frame(width: 28, height: 24)
            }
            .menuStyle(.borderlessButton)
            .padding(8)
        }
        .contextMenu {
            Button(AppLocalization.text("重命名"), systemImage: "pencil") { editFolderAction(folder) }
            Divider()
            Button(AppLocalization.text("删除文件夹"), systemImage: "trash", role: .destructive) {
                deleteRequest = DeleteRequest(id: folder.id, name: folder.name, isFolder: true)
            }
        }
        .onDrag {
            draggedFolderID = folder.id
            return NSItemProvider(object: folder.id as NSString)
        }
        .onDrop(
            of: [UTType.plainText],
            delegate: ReorderDropDelegate.documentFolder(
                targetID: folder.id,
                draggedID: $draggedFolderID,
                store: store
            )
        )
        .listHoverHighlight()
        .help(AppLocalization.text("拖动文件夹可调整网格顺序"))
    }

    private func folderContents(_ folder: DocumentFolder) -> some View {
        let documents = store.documents(in: folder.id, search: search, tag: selectedTag, sort: sort)
        let availableTags = store.tags(in: folder.id)

        return VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    selectedFolderID = nil
                    selectedTag = nil
                } label: {
                    Label(AppLocalization.text("返回文件夹"), systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)

                Divider().frame(height: 24)

                Image(systemName: "folder.fill")
                    .foregroundStyle(AppTheme.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(folder.name).font(.headline)
                    Text(AppLocalization.format("%d 个文件", store.documentCount(in: folder.id)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()

                Picker(AppLocalization.text("排序"), selection: $sort) {
                    ForEach(ManagedDocumentSort.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 145)

                Menu {
                    Button(AppLocalization.text("全部标签")) { selectedTag = nil }
                    if !availableTags.isEmpty { Divider() }
                    ForEach(availableTags, id: \.self) { tag in
                        Button(tag) { selectedTag = tag }
                    }
                } label: {
                    Label(selectedTag ?? AppLocalization.text("全部标签"), systemImage: "tag")
                }
                .disabled(availableTags.isEmpty)

                Menu {
                    Button(AppLocalization.text("重命名文件夹"), systemImage: "pencil") { editFolderAction(folder) }
                    Button(AppLocalization.text("删除文件夹"), systemImage: "trash", role: .destructive) {
                        deleteRequest = DeleteRequest(id: folder.id, name: folder.name, isFolder: true)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)

                Button {
                    store.chooseDocuments(for: folder.id)
                } label: {
                    Label(AppLocalization.text("上传文件"), systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 14)

            if let selectedTag {
                HStack {
                    Label(AppLocalization.format("正在筛选：%@", selectedTag), systemImage: "line.3.horizontal.decrease.circle.fill")
                        .font(.callout)
                        .foregroundStyle(AppTheme.blue)
                    Button(AppLocalization.text("清除")) { self.selectedTag = nil }
                        .buttonStyle(.link)
                    Spacer()
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 10)
            }

            if documents.isEmpty {
                emptyDocumentState(
                    isSearching: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selectedTag != nil,
                    uploadAction: { store.chooseDocuments(for: folder.id) }
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(documents) { document in
                            documentRow(document)
                        }
                    }
                    .frame(maxWidth: 1100)
                    .padding(.horizontal, 24)
                    .padding(.bottom, 28)
                }
            }
        }
        // V4.6 batch-Q2：支持从访达拖文件进入当前文件夹，走 store.importDocuments 既有路径。
        // （任务书提及的 dropDestination 为 macOS 14+ API，目标 macOS 13，故用 onDrop。）
        .onDrop(
            of: [UTType.fileURL],
            delegate: FinderFileDropDelegate(store: store, folderID: folder.id)
        )
    }

    private func documentRow(_ document: ManagedDocument) -> some View {
        HStack(spacing: 14) {
            Button { previewDocument = document } label: {
                HStack(spacing: 14) {
                    Image(systemName: fileSymbol(for: document.fileExtension))
                        .font(.body.weight(.semibold))
                        .foregroundStyle(AppTheme.teal)
                        .frame(width: 40, height: 40)
                        .background(AppTheme.teal.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(document.displayName)
                            .font(.headline)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        HStack(spacing: 8) {
                            Text(document.fileExtension.uppercased())
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(ByteCountFormatter.string(fromByteCount: document.byteCount, countStyle: .file))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(AppLocalization.format("上传于 %@", Formatters.dateTime.string(from: document.uploadedAt)))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !document.tags.isEmpty {
                            HStack(spacing: 5) {
                                ForEach(document.tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption2.weight(.medium))
                                        .foregroundStyle(AppTheme.indigo)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(AppTheme.blue.opacity(0.08), in: Capsule())
                                }
                            }
                        }
                    }
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Menu {
                documentMenuContent(document)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .frame(width: 32, height: 32)
            }
            .menuStyle(.borderlessButton)
        }
        .padding(15)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
        .contextMenu { documentMenuContent(document) }
        .onDrag {
            draggedDocumentID = document.id
            return NSItemProvider(object: document.id as NSString)
        }
        .onDrop(
            of: [UTType.plainText],
            delegate: ReorderDropDelegate.managedDocument(
                targetID: document.id,
                draggedID: $draggedDocumentID,
                store: store,
                isEnabled: isManualDocumentOrderEnabled
            )
        )
        .listHoverHighlight()
        .help(AppLocalization.text("上下拖动调整顺序"))
    }

    @ViewBuilder
    private func documentMenuContent(_ document: ManagedDocument) -> some View {
        Button(AppLocalization.text("快速预览"), systemImage: "eye") { previewDocument = document }
        Button(AppLocalization.text("用默认应用打开"), systemImage: "arrow.up.forward.app") { store.openDocument(document) }
        Button(AppLocalization.text("在访达中显示"), systemImage: "folder") { store.revealDocument(document) }
        Button(AppLocalization.text("重命名与标签"), systemImage: "pencil") { editDocumentAction(document) }
        Divider()
        Button(AppLocalization.text("删除文件"), systemImage: "trash", role: .destructive) {
            deleteRequest = DeleteRequest(id: document.id, name: document.displayName, isFolder: false)
        }
    }

    private func emptyFolderState(isSearching: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: isSearching ? "magnifyingglass" : "folder.badge.plus")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(AppTheme.blue)
            Text(AppLocalization.text(isSearching ? "没有匹配的文件夹或文件" : "还没有文件夹"))
                .font(.title3.weight(.semibold))
            Text(AppLocalization.text(isSearching ? "尝试搜索其他名称或标签。" : "先创建一个文件夹，再把相关文件上传到其中。"))
                .foregroundStyle(.secondary)
            if !isSearching {
                Button(AppLocalization.text("新建文件夹"), action: createFolderAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 300)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }

    private func emptyDocumentState(isSearching: Bool, uploadAction: @escaping () -> Void) -> some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: isSearching ? "line.3.horizontal.decrease.circle" : "doc.badge.plus")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(AppTheme.blue)
            Text(AppLocalization.text(isSearching ? "没有匹配的文件" : "文件夹还是空的"))
                .font(.title3.weight(.semibold))
            Text(AppLocalization.text(isSearching ? "可清除搜索或标签筛选后重试。" : "上传 Word、Excel、PPT、PDF、Markdown、文本等常见格式。"))
                .foregroundStyle(.secondary)
            if !isSearching {
                Button(AppLocalization.text("上传文件"), action: uploadAction)
                    .buttonStyle(.borderedProminent)
                Text(AppLocalization.text("也可以直接从访达拖入文件上传"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private func fileSymbol(for fileExtension: String) -> String {
        switch fileExtension.lowercased() {
        case "doc", "docx", "rtf", "rtfd": "doc.text.fill"
        case "xls", "xlsx", "csv", "tsv": "tablecells.fill"
        case "ppt", "pptx": "rectangle.on.rectangle.angled"
        case "pdf": "doc.richtext.fill"
        case "md", "markdown", "txt": "text.alignleft"
        case "png", "jpg", "jpeg", "heic", "tif", "tiff": "photo.fill"
        case "zip", "7z": "archivebox.fill"
        default: "doc.fill"
        }
    }
}

private struct DeleteRequest: Identifiable {
    let id: String
    let name: String
    let isFolder: Bool
}

// V4.6 batch-Q2：DocumentFolderReorderDropDelegate 已泛型化到 SharedListComponents.swift，
// 文件夹网格改用 ReorderDropDelegate.documentFolder 工厂。
