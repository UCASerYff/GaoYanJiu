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
    @State private var previewPage: Int?
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
                title: document.displayName,
                provenance: store.documentProvenance(for: document.id),
                originalPDFURL: sourcePDFURL(for: document),
                initialPage: previewPage
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

                Menu {
                    Button(AppLocalization.text("从搞整理选择资料…"), systemImage: "magnifyingglass") {
                        chooseFromZhengLi(folderID: folder.id)
                    }
                    Button(AppLocalization.text("打开外部交接包…"), systemImage: "shippingbox") {
                        openActionPackageDialog()
                    }
                } label: {
                    Label(AppLocalization.text("资料交接"), systemImage: "arrow.triangle.swap")
                }
                .menuStyle(.borderedButton)

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
        VStack(alignment: .leading, spacing: 8) {
        HStack(spacing: 14) {
            Button { previewPage = nil; previewDocument = document } label: {
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
                        let prov = store.documentProvenance(for: document.id)
                        let rev = store.documentRevision(for: document.id)
                        if (prov != nil && (!prov!.pages.isEmpty || prov!.ocrEngine != nil)) || rev != nil {
                            HStack(spacing: 6) {
                                if let prov, !prov.pages.isEmpty || prov.ocrEngine != nil {
                                    HStack(spacing: 3) {
                                        Image(systemName: "text.viewfinder")
                                        Text(prov.pages.isEmpty ? "OCR 页码待核对" : AppLocalization.format("已OCR（%d页）", prov.pages.count))
                                    }
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(AppTheme.teal)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(AppTheme.teal.opacity(0.10), in: Capsule())
                                }
                                if let rev {
                                    HStack(spacing: 3) {
                                        Image(systemName: "arrow.triangle.branch")
                                        Text(rev.kind == "editedVersion" ? "编辑新版本" : "衍生件")
                                    }
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(Color.purple)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.10), in: Capsule())
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
            let pages = matchingOCRPages(for: document)
            if !pages.isEmpty {
                HStack(spacing: 8) {
                    Text("OCR 正文命中页：").font(.caption).foregroundStyle(.secondary)
                    ForEach(Array(pages.prefix(5).enumerated()), id: \.offset) { _, page in
                        Button(page.pageNumber > 0 ? "第 \(page.pageNumber) 页" : "页码未知") {
                            previewPage = page.pageNumber > 0 ? page.pageNumber : nil
                            previewDocument = document
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                    }
                }
            }
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

    private func matchingOCRPages(for document: ManagedDocument) -> [DocumentProvenance.Page] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return store.documentProvenance(for: document.id)?.pages.filter {
            $0.text?.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
        } ?? []
    }

    private func sourcePDFURL(for document: ManagedDocument) -> URL? {
        if let revision = store.documentRevision(for: document.id),
           let original = store.managedDocuments.first(where: { $0.id == revision.originalDocumentID }),
           original.fileExtension.lowercased() == "pdf" {
            return store.managedDocumentURL(original)
        }
        return document.fileExtension.lowercased() == "pdf" ? store.managedDocumentURL(document) : nil
    }

    @ViewBuilder
    private func documentMenuContent(_ document: ManagedDocument) -> some View {
        Button(AppLocalization.text("快速预览"), systemImage: "eye") { previewPage = nil; previewDocument = document }
        Button(AppLocalization.text("用默认应用打开"), systemImage: "arrow.up.forward.app") { store.openDocument(document) }
        Button(AppLocalization.text("在访达中显示"), systemImage: "folder") { store.revealDocument(document) }
        Button(AppLocalization.text("重命名与标签"), systemImage: "pencil") { editDocumentAction(document) }
        Divider()
        if ["pdf", "png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(document.fileExtension.lowercased()) {
            Button(AppLocalization.text("送搞截图识别文字（OCR）…"), systemImage: "text.viewfinder") {
                sendToJieTuOCR(document)
            }
        }
        Button(AppLocalization.text("在搞文件中编辑…"), systemImage: "square.and.pencil") {
            sendToWenJianEdit(document)
        }
        Button(AppLocalization.text("导入编辑新版本…"), systemImage: "arrow.triangle.merge") {
            importEditedCopy(for: document)
        }
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

    private func chooseFromZhengLi(folderID: String) {
        do {
            try store.requestChooseFilesFromZhengLi(targetFolderID: folderID) { prepared, provider in
                Task { @MainActor in
                    if provider.isAvailable {
                        do {
                            try await store.documentLibrary.exchangeClient.openInProvider(prepared)
                            store.exchangeFeedbackMessage = AppLocalization.text("已向搞整理发起文件选择请求，请在搞整理中选择要导入的文件并发送结果。")
                        } catch {
                            store.documentLibrary.exchangeClient.revealFallback(prepared)
                            store.exchangeFeedbackMessage = AppLocalization.format("启动搞整理失败（%@），已在访达中定位交接包。", error.localizedDescription)
                        }
                    } else {
                        store.documentLibrary.exchangeClient.revealFallback(prepared)
                        store.exchangeFeedbackMessage = AppLocalization.format("搞整理未就绪（%@）。已在访达中显示交接包，可手动发送。", provider.reason)
                    }
                }
            }
        } catch {
            store.exchangeFeedbackMessage = AppLocalization.format("发起文件选择失败：%@", error.localizedDescription)
        }
    }

    private func sendToJieTuOCR(_ document: ManagedDocument) {
        do {
            try store.requestOCRViaJieTu(for: document) { prepared, provider in
                Task { @MainActor in
                    if provider.isAvailable {
                        do {
                            try await store.documentLibrary.exchangeClient.openInProvider(prepared)
                            store.exchangeFeedbackMessage = AppLocalization.format("已将“%@”发送至搞截图进行文字识别（OCR），请在搞截图完成识别后发送结果。", document.displayName)
                        } catch {
                            store.documentLibrary.exchangeClient.revealFallback(prepared)
                            store.exchangeFeedbackMessage = AppLocalization.format("启动搞截图失败（%@），已在访达中定位交接包。", error.localizedDescription)
                        }
                    } else {
                        store.documentLibrary.exchangeClient.revealFallback(prepared)
                        store.exchangeFeedbackMessage = AppLocalization.format("搞截图未就绪（%@）。已在访达中显示交接包，可手动发送。", provider.reason)
                    }
                }
            }
        } catch {
            store.exchangeFeedbackMessage = AppLocalization.format("发起 OCR 识别失败：%@", error.localizedDescription)
        }
    }

    private func sendToWenJianEdit(_ document: ManagedDocument) {
        do {
            try store.requestEditViaWenJian(for: document) { prepared, provider in
                Task { @MainActor in
                    if provider.isAvailable {
                        do {
                            try await store.documentLibrary.exchangeClient.openInProvider(prepared)
                            store.exchangeFeedbackMessage = AppLocalization.format("已请求搞文件接收“%@”的副本。请在搞文件中确认并编辑，导出后再在“导入编辑新版本…”中选择文件并复核入库。", document.displayName)
                        } catch {
                            store.documentLibrary.exchangeClient.revealFallback(prepared)
                            store.exchangeFeedbackMessage = AppLocalization.format("启动搞文件失败（%@），已在访达中定位交接副本。", error.localizedDescription)
                        }
                    } else {
                        store.documentLibrary.exchangeClient.revealFallback(prepared)
                        store.exchangeFeedbackMessage = AppLocalization.format("搞文件未就绪（%@）。已在访达中显示副本，可手动打开。", provider.reason)
                    }
                }
            }
        } catch {
            store.exchangeFeedbackMessage = AppLocalization.format("发起外部编辑失败：%@", error.localizedDescription)
        }
    }

    private func importEditedCopy(for document: ManagedDocument) {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.text("选择编辑后的文件")
        panel.message = AppLocalization.format("请选择“%@”经搞文件或其他应用编辑后的副本。", document.displayName)
        panel.prompt = AppLocalization.text("导入")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        if let uti = UTType(filenameExtension: document.fileExtension) {
            panel.allowedContentTypes = [uti]
        }
        if panel.runModal() == .OK, let url = panel.url {
            let alert = NSAlert()
            alert.messageText = AppLocalization.text("导入编辑后的文件")
            alert.informativeText = AppLocalization.format("已选择：%@\n\n请选择导入方式：", url.lastPathComponent)
            alert.addButton(withTitle: AppLocalization.text("替换为新版本（保留历史摘要）"))
            alert.addButton(withTitle: AppLocalization.text("另存为新附件（关联原件）"))
            alert.addButton(withTitle: AppLocalization.text("取消"))
            let response = alert.runModal()
            if response == .alertFirstButtonReturn {
                performEditedImport(document: document, from: url, asNewVersion: true)
            } else if response == .alertSecondButtonReturn {
                performEditedImport(document: document, from: url, asNewVersion: false)
            }
        }
    }

    private func performEditedImport(document: ManagedDocument, from url: URL, asNewVersion: Bool) {
        Task { @MainActor in
            do {
                try await store.importEditedDocumentCopy(for: document, from: url, asNewVersion: asNewVersion)
                store.exchangeFeedbackMessage = asNewVersion
                    ? AppLocalization.format("已成功将“%@”替换为新版本。", document.displayName)
                    : AppLocalization.text("已将编辑副本作为新附件导入。")
            } catch {
                store.exchangeFeedbackMessage = AppLocalization.format("导入编辑副本失败：%@", error.localizedDescription)
            }
        }
    }

    private func openActionPackageDialog() {
        let panel = NSOpenPanel()
        panel.title = AppLocalization.text("打开外部交接包")
        panel.prompt = AppLocalization.text("打开")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        let uti = UTType(exportedAs: "com.gaoseries.action-package", conformingTo: .package)
        panel.allowedContentTypes = [uti]
        if panel.runModal() == .OK, let url = panel.url {
            store.handleIncomingPackage(at: url)
        }
    }
}

private struct DeleteRequest: Identifiable {
    let id: String
    let name: String
    let isFolder: Bool
}

struct ActionPackageReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PaperStore
    let context: PendingPackageReviewContext
    @State private var selectedFolderID: String
    @State private var isProcessing = false
    @State private var errorMessage: String?

    init(context: PendingPackageReviewContext) {
        self.context = context
        _selectedFolderID = State(initialValue: context.targetFolderID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 28))
                    .foregroundStyle(AppTheme.blue)
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.text("审核外部资料交接请求"))
                        .font(.title3.weight(.semibold))
                    Text(AppLocalization.format("来源声明：%@（声明未认证）", context.validatedPackage.manifest.sourceBundleID))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            Divider()

            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.text("目标文件夹")).font(.headline)
                Picker("", selection: $selectedFolderID) {
                    Text(AppLocalization.text("请选择文件夹")).tag("")
                    ForEach(store.documentFolders) { folder in
                        Text("\(folder.name) (\(folder.libraryKind.title))").tag(folder.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text(AppLocalization.format("拟导入文件列表 (%d 项)", context.validatedPackage.stagedItems.count))
                    .font(.headline)
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(context.validatedPackage.stagedItems, id: \.item.id) { staged in
                            HStack {
                                Image(systemName: "doc.fill")
                                    .foregroundStyle(.secondary)
                                Text(staged.originalFilename)
                                    .font(.body)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: staged.item.byteCount, countStyle: .file))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(String(staged.item.sha256.prefix(8)))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button(AppLocalization.text("拒绝并取消")) {
                    store.pendingPackageReview = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isProcessing)

                Button(AppLocalization.text("确认导入")) {
                    confirmImport()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedFolderID.isEmpty || isProcessing)
            }
        }
        .padding(24)
        .frame(width: 540)
        .interactiveDismissDisabled(isProcessing)
    }

    private func confirmImport() {
        guard let folder = store.documentFolders.first(where: { $0.id == selectedFolderID }) else {
            errorMessage = AppLocalization.text("请选择有效的目标文件夹")
            return
        }
        isProcessing = true
        Task { @MainActor in
            do {
                let outcome = try await store.documentLibrary.importStagedDocuments(context.validatedPackage, into: folder)
                store.exchangeFeedbackMessage = AppLocalization.format("已成功导入 %d 项文件，%d 项内容已存在去重保留。", outcome.importedCount, outcome.duplicateCount)
                store.pendingPackageReview = nil
                dismiss()
            } catch {
                isProcessing = false
                errorMessage = AppLocalization.format("导入失败：%@", error.localizedDescription)
            }
        }
    }
}

struct ExchangeResultReviewSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: PaperStore
    let review: PendingExchangeResultReview
    @State private var targetFolderID: String
    @State private var reselectedReferences: [String: URL] = [:]
    @State private var acknowledgedWarnings = false
    @State private var isProcessing = false
    @State private var errorMessage: String?

    init(review: PendingExchangeResultReview) {
        self.review = review
        _targetFolderID = State(initialValue: review.targetFolderID ?? "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("审核资料交接结果").font(.title2.weight(.semibold))
            Text(review.summary).font(.callout)
            Text("来源声明：\(review.result.package.manifest.sourceBundleID)（声明未认证）")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            if review.result.session.action == .chooseFiles {
                Picker("导入文件夹", selection: $targetFolderID) {
                    Text("请选择文件夹").tag("")
                    ForEach(store.documentFolders) { folder in
                        Text("\(folder.name)（\(folder.libraryKind.title)）").tag(folder.id)
                    }
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(review.result.selectedReferences) { reference in
                        HStack {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(reference.displayName)
                                if let selected = reselectedReferences[reference.id] {
                                    Text("本次选择：\(selected.lastPathComponent)").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button("重新选择文件…") { selectFile(for: reference) }
                                .disabled(isProcessing)
                        }
                    }
                    ForEach(review.result.ocrOutputs, id: \.itemID) { output in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(output.localCopy.lastPathComponent).font(.headline)
                            Text("\(ByteCountFormatter.string(fromByteCount: output.byteCount, countStyle: .file)) · \(output.pages.count) 个页来源")
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(output.warnings.enumerated()), id: \.offset) { _, warning in
                                Text(warning).font(.caption).foregroundStyle(.orange)
                            }
                            if output.pages.contains(where: { $0.confidence == nil }) {
                                Text("部分或全部页未提供置信度。").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 260)
            if review.requiresExplicitReview && review.canApply {
                Toggle("我已核对结果中的不完整信息，确认按当前结果导入", isOn: $acknowledgedWarnings)
                    .toggleStyle(.checkbox)
            }
            if let errorMessage {
                Text(errorMessage).font(.callout).foregroundStyle(.red)
            }
            HStack {
                if isProcessing { ProgressView().controlSize(.small) }
                Spacer()
                Button("关闭") {
                    store.documentLibrary.pendingExchangeResultReview = nil
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isProcessing)
                if review.canApply {
                    Button("确认导入", action: apply)
                        .buttonStyle(.borderedProminent)
                        .disabled(isProcessing || (review.requiresExplicitReview && !acknowledgedWarnings)
                                  || (review.result.session.action == .chooseFiles && targetFolderID.isEmpty))
                }
            }
        }
        .padding(24)
        .frame(width: 640)
        .interactiveDismissDisabled(isProcessing)
    }

    private func selectFile(for reference: GaoActionReference) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = "重新选择：\(reference.displayName)"
        if panel.runModal() == .OK, let url = panel.url { reselectedReferences[reference.id] = url }
    }

    private func apply() {
        isProcessing = true
        errorMessage = nil
        Task { @MainActor in
            do {
                let outcome = try await store.documentLibrary.applyExchangeResult(
                    review, userApproved: true,
                    targetFolderID: targetFolderID.isEmpty ? nil : targetFolderID,
                    reselectedReferences: reselectedReferences)
                store.documentLibrary.pendingExchangeResultReview = nil
                store.exchangeFeedbackMessage = AppLocalization.format("已导入 %d 项文件，%d 项内容已存在。", outcome.importedCount, outcome.duplicateCount)
                dismiss()
            } catch {
                isProcessing = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
