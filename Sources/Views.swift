import AppKit
import Charts
import SwiftUI
import UniformTypeIdentifiers

enum AppTheme {
    static let indigo = Color(red: 0.08, green: 0.20, blue: 0.43)
    static let blue = Color(red: 0.10, green: 0.36, blue: 0.78)
    static let teal = Color(red: 0.08, green: 0.58, blue: 0.54)
    static let canvas = Color(nsColor: .windowBackgroundColor)
}

struct ImportContext: Identifiable {
    let id = UUID()
    let publisher: PublisherDefinition?
}

struct ManualSubmissionContext: Identifiable {
    let id = UUID()
    let paperID: String?
}

struct ExistingWorkEditorContext: Identifiable {
    let id = UUID()
    let workID: String?
}

struct ProjectEditorContext: Identifiable {
    let id = UUID()
    let projectID: String?
}

struct CertificateEditorContext: Identifiable {
    let id = UUID()
    let recordID: String?
}

struct FundingEditorContext: Identifiable {
    let id = UUID()
    let recordID: String?
}

struct DocumentFolderEditorContext: Identifiable {
    let id = UUID()
    let kind: DocumentLibraryKind
    let folderID: String?
}

struct ManagedDocumentEditorContext: Identifiable {
    let id = UUID()
    let documentID: String
}

/// 菜单栏命令跨文件通信（PaperSignalApp 发送，ContentView 接收）。
extension Notification.Name {
    static let appFocusSearch = Notification.Name("appFocusSearch")
    static let appCreateRecord = Notification.Name("appCreateRecord")
    static let appOpenSettings = Notification.Name("appOpenSettings")
    static let appRefreshSubmissions = Notification.Name("appRefreshSubmissions")
    /// 小组件深链（gaoyanjiu://submissions | gaoyanjiu://works）：object 为 URL host 字符串。
    static let appOpenWidgetDeepLink = Notification.Name("appOpenWidgetDeepLink")
}

/// 菜单栏命令的展示状态：由 ContentView 按当前模块同步，App 的 .commands 读取。
final class MenuCommandState: ObservableObject {
    @Published var newRecordTitle = AppLocalization.text("添加在投论文")
    @Published var canCreateRecord = true
    @Published var canRefreshSubmissions = false
}

struct ContentView: View {
    @EnvironmentObject private var store: PaperStore
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var menuState: MenuCommandState
    @SceneStorage("gqns.page.Research") private var filter: LibraryFilter = .all
    @SceneStorage("gqns.research.search") private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var searchEscapeMonitor: Any?
    @State private var paperPendingDeletion: PaperRecord?
    @State private var selectedPaper: PaperRecord?
    @State private var selectedWork: ExistingWork?
    @State private var selectedProject: ResearchProject?
    @State private var selectedCertificate: CertificateRecord?
    @State private var importContext: ImportContext?
    @State private var manualSubmissionContext: ManualSubmissionContext?
    @State private var existingWorkEditorContext: ExistingWorkEditorContext?
    @State private var projectEditorContext: ProjectEditorContext?
    @State private var certificateEditorContext: CertificateEditorContext?
    @State private var fundingEditorContext: FundingEditorContext?
    @State private var documentFolderEditorContext: DocumentFolderEditorContext?
    @State private var managedDocumentEditorContext: ManagedDocumentEditorContext?
    @State private var draggedPaperID: String?
    @State private var portalToRemove: PortalAccount?
    @State private var showingTrash = false
    @State private var loadFailureAlertDismissed = false
    /// 侧栏隐藏/显示（场景级记忆；键全 app 唯一，与其它模块互不冲突）。
    /// 只有 隐藏↔显示 两态，不提供「收起成图标栏」。
    @SceneStorage("gqns.sidebarHidden.research") private var sidebarHidden = false
    /// 自绘侧栏导航行的 hover 跟踪（浅灰反馈，与词元一致）。
    @State private var hoveredFilter: LibraryFilter?
    @Environment(\.colorScheme) private var colorScheme

    private var displayedPapers: [PaperRecord] {
        store.papers(matching: filter, search: search)
    }

    private var displayedWorks: [ExistingWork] {
        store.existingWorks(matching: search)
    }

    private var displayedProjects: [ResearchProject] {
        store.projects(matching: search)
    }

    private var displayedCertificates: [CertificateRecord] {
        store.certificates(matching: search)
    }

    private var displayedFundingRecords: [FundingRecord] {
        store.fundingRecords(matching: search)
    }

    private var searchPrompt: String {
        switch filter {
        case .existing: AppLocalization.text("搜索成果、作者或 DOI")
        case .projects: AppLocalization.text("搜索项目、内容或步骤")
        case .experimentData, .summaryReports, .importantLiterature: AppLocalization.text("搜索文件夹、文件名称或标签")
        case .certificates: AppLocalization.text("搜索证书名称、标签或附件")
        case .funding: AppLocalization.text("搜索资金名称、年份或收款账户")
        case .rewardCity: AppLocalization.text("研究城中的物品可在库存中筛选")
        default: AppLocalization.text("搜索标题、期刊或稿号")
        }
    }

    private var loadFailureAlertMessage: String {
        var message = AppLocalization.text("数据没有丢失，但资料库文件无法读取。为保护数据，应用已暂停所有写入，直到恢复出可用的资料库。")
        if let name = store.quarantinedLibraryFileName {
            message += "\n\n" + AppLocalization.format("无法读取的文件已隔离保存为“%@”。", name)
        }
        message += "\n\n" + AppLocalization.text("可从每日自动备份中恢复，也可以直接点击下方按钮：")
        return message
    }

    private var baseInterface: some View {
        // 侧栏重设计（对齐词元 2.2/2.3 标杆）：弃用系统 NavigationSplitView 列表侧栏，改自绘——
        // 品牌头部 + 浮动卡片式选中态导航行 + hover 反馈 + 状态底卡，宽 236、.regularMaterial。
        // 统一工具栏契约：.navigation 恰好一个 28×28 侧栏切换按钮（⌃⌘S）；
        // 原有 trailing 按钮全部保留，包在固定宽 360 的右对齐容器里。
        HStack(spacing: 0) {
            if !sidebarHidden {
                sidebar
                // 自绘发丝线替代系统 Divider：避免 Tahoe 统一标题栏下系统 separator 冷启动首帧误渲染成灰带
                Rectangle().fill(Color.primary.opacity(0.12)).frame(width: 1).frame(maxHeight: .infinity)
            }
            dashboard
                .id(settings.language)
        }
        .frame(minWidth: 1040, minHeight: 700)
        .animation(.easeInOut(duration: 0.22), value: sidebarHidden)
        .toolbar {
            toolbarItemNoChrome(.navigation) {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { sidebarHidden.toggle() }
                } label: {
                    SidebarToggleIcon()
                }
                .buttonStyle(.plain)
                .keyboardShortcut("s", modifiers: [.command, .control])
                .help(AppLocalization.text(sidebarHidden ? "显示侧边栏" : "隐藏侧边栏"))
            }
            toolbarItemNoChrome(.primaryAction) {
                HStack(spacing: 12) {
                    Button {
                        showingTrash = true
                    } label: {
                        Label(AppLocalization.format("回收站（%d）", store.trashItems.count), systemImage: "trash")
                    }

                    if filter.isSubmissionFilter {
                        Button {
                            store.refreshAll()
                        } label: {
                            Label(AppLocalization.text(store.isRefreshing ? "刷新中" : "刷新全部"), systemImage: "arrow.clockwise")
                        }
                        .disabled(store.portals.isEmpty || store.isRefreshing)
                    }

                    if filter == .existing {
                        Button {
                            existingWorkEditorContext = ExistingWorkEditorContext(workID: nil)
                        } label: {
                            Label(AppLocalization.text("新建成果"), systemImage: "plus")
                        }
                        .buttonStyle(ToolbarProminentStyle())
                    } else if filter == .projects {
                        Button {
                            projectEditorContext = ProjectEditorContext(projectID: nil)
                        } label: {
                            Label(AppLocalization.text("新建项目"), systemImage: "plus")
                        }
                        .buttonStyle(ToolbarProminentStyle())
                    } else if let kind = filter.documentLibraryKind {
                        Button {
                            documentFolderEditorContext = DocumentFolderEditorContext(kind: kind, folderID: nil)
                        } label: {
                            Label(AppLocalization.text("新建文件夹"), systemImage: "folder.badge.plus")
                        }
                        .buttonStyle(ToolbarProminentStyle())
                    } else if filter == .certificates {
                        Button {
                            certificateEditorContext = CertificateEditorContext(recordID: nil)
                        } label: {
                            Label(AppLocalization.text("新建证书记录"), systemImage: "plus")
                        }
                        .buttonStyle(ToolbarProminentStyle())
                    } else if filter == .funding {
                        Button {
                            fundingEditorContext = FundingEditorContext(recordID: nil)
                        } label: {
                            Label(AppLocalization.text("新建资金记录"), systemImage: "plus")
                        }
                        .buttonStyle(ToolbarProminentStyle())
                    } else if filter == .rewardCity {
                        Button {
                            store.collectRewardCoins()
                        } label: {
                            Label(AppLocalization.text("收取金币"), systemImage: "dollarsign.circle.fill")
                        }
                        .disabled(store.pendingRewardCoins() < 0.01)
                    } else {
                        Menu {
                            Button {
                                manualSubmissionContext = ManualSubmissionContext(paperID: nil)
                            } label: {
                                Label(AppLocalization.text("手动添加"), systemImage: "square.and.pencil")
                            }
                            Button {
                                importContext = ImportContext(publisher: nil)
                            } label: {
                                Label(AppLocalization.text("从投稿系统导入"), systemImage: "safari")
                            }
                        } label: {
                            Label(AppLocalization.text("添加在投"), systemImage: "plus")
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    }
                }
                .frame(width: 360, alignment: .trailing)
            }

        }
        .sheet(item: $selectedPaper) { paper in
            PaperDetailView(paperID: paper.id)
                .environmentObject(store)
        }
        .onChange(of: importContext?.id) { _ in
            guard let context = importContext else { return }
            PortalImportWindow.shared.show(publisher: context.publisher, store: store, settings: settings)
            importContext = nil
        }
        .sheet(item: $manualSubmissionContext) { context in
            ManualSubmissionEditor(
                paper: context.paperID.flatMap { id in store.papers.first(where: { $0.id == id }) }
            )
            .environmentObject(store)
        }
        .sheet(item: $selectedWork) { work in
            ExistingWorkDetailView(workID: work.id)
                .environmentObject(store)
        }
        .sheet(item: $existingWorkEditorContext) { context in
            ExistingWorkEditor(
                work: context.workID.flatMap { id in store.existingWorks.first(where: { $0.id == id }) }
            )
            .environmentObject(store)
        }
        .sheet(item: $selectedProject) { project in
            ProjectDetailView(projectID: project.id)
                .environmentObject(store)
        }
        .sheet(item: $projectEditorContext) { context in
            ProjectEditor(
                project: context.projectID.flatMap { id in store.projects.first(where: { $0.id == id }) }
            )
            .environmentObject(store)
        }
        .sheet(item: $selectedCertificate) { record in
            CertificateDetailView(recordID: record.id)
                .environmentObject(store)
        }
        .sheet(item: $certificateEditorContext) { context in
            CertificateEditor(
                record: context.recordID.flatMap { id in store.certificates.first(where: { $0.id == id }) }
            )
            .environmentObject(store)
        }
        .sheet(item: $fundingEditorContext) { context in
            FundingEditor(
                record: context.recordID.flatMap { id in store.fundingRecords.first(where: { $0.id == id }) }
            )
            .environmentObject(store)
        }
        .sheet(item: $documentFolderEditorContext) { context in
            DocumentFolderEditor(
                kind: context.kind,
                folder: context.folderID.flatMap { id in store.documentFolders.first(where: { $0.id == id }) }
            )
            .environmentObject(store)
        }
        .sheet(item: $managedDocumentEditorContext) { context in
            if let document = store.managedDocuments.first(where: { $0.id == context.documentID }) {
                ManagedDocumentEditor(document: document)
                    .environmentObject(store)
            }
        }
        .sheet(isPresented: $showingTrash) {
            RecycleBinView()
                .environmentObject(store)
        }
        .confirmationDialog(AppLocalization.text("删除投稿门户？"), isPresented: Binding(get: { portalToRemove != nil }, set: { if !$0 { portalToRemove = nil } }), titleVisibility: .visible, presenting: portalToRemove) { portal in
            Button(AppLocalization.text("删除门户，保留论文"), role: .destructive) {
                store.removePortal(portal)
                portalToRemove = nil
            }
            Button(AppLocalization.text("取消"), role: .cancel) { portalToRemove = nil }
        } message: { _ in
            Text(AppLocalization.text("删除后将停止自动刷新此门户，已导入的论文和历史记录会保留。"))
        }
        .confirmationDialog(
            AppLocalization.text("删除论文及其本地历史？"),
            isPresented: Binding(
                get: { paperPendingDeletion != nil },
                set: { if !$0 { paperPendingDeletion = nil } }
            ),
            titleVisibility: .visible,
            presenting: paperPendingDeletion
        ) { paper in
            Button(AppLocalization.text("删除"), role: .destructive) {
                store.delete(paper)
                paperPendingDeletion = nil
            }
            Button(AppLocalization.text("取消"), role: .cancel) { paperPendingDeletion = nil }
        } message: { _ in
            Text(AppLocalization.text("记录会移入回收站，可在30天内恢复；不会影响出版商网站上的论文。"))
        }
        .alert(AppLocalization.text("搞研究"), isPresented: Binding(
            get: { store.lastError != nil },
            set: { if !$0 { store.lastError = nil } }
        )) {
            Button(AppLocalization.text("好"), role: .cancel) { store.lastError = nil }
        } message: {
            Text(store.lastError ?? "")
        }
        .alert(
            AppLocalization.text("保存失败"),
            isPresented: Binding(
                get: { store.persistenceAlert != nil },
                set: { if !$0 { store.persistenceAlert = nil } }
            )
        ) {
            Button(AppLocalization.text("好"), role: .cancel) { store.persistenceAlert = nil }
        } message: {
            Text(store.persistenceAlert ?? "")
        }
        .alert(
            AppLocalization.text("资料库无法读取"),
            isPresented: Binding(
                get: { store.libraryLoadFailed && !loadFailureAlertDismissed },
                set: { if !$0 { loadFailureAlertDismissed = true } }
            )
        ) {
            Button(AppLocalization.text("从备份恢复…")) {
                loadFailureAlertDismissed = true
                store.chooseAndRestoreFullBackup()
            }
            Button(AppLocalization.text("稍后"), role: .cancel) {
                loadFailureAlertDismissed = true
            }
        } message: {
            Text(loadFailureAlertMessage)
        }
        .safeAreaInset(edge: .bottom) {
            if store.lastDeletedTrashID != nil {
                HStack(spacing: 12) {
                    Image(systemName: "trash.fill")
                        .foregroundStyle(AppTheme.blue)
                        .accessibilityHidden(true)
                    Text(store.deletionMessage)
                        .font(.callout)
                    Spacer()
                    Button(AppLocalization.text("撤销")) { store.undoLastDeletion() }
                        .buttonStyle(.borderedProminent)
                    Button {
                        store.lastDeletedTrashID = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(AppLocalization.text("关闭提示"))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
            } else if !store.backupMessage.isEmpty {
                HStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                    Text(store.backupMessage)
                        .font(.callout)
                    Spacer()
                    Button {
                        store.backupMessage = ""
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(AppLocalization.text("关闭提示"))
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(.regularMaterial)
                .overlay(alignment: .top) { Divider() }
            }
        }
    }

    var body: some View {
        baseInterface
        .onReceive(NotificationCenter.default.publisher(for: .appFocusSearch)) { _ in
            guard !hasActiveSheet else { return }
            searchFocused = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .appCreateRecord)) { _ in
            guard !hasActiveSheet else { return }
            createRecordForCurrentFilter()
        }
        .onReceive(NotificationCenter.default.publisher(for: .appRefreshSubmissions)) { _ in
            guard filter.isSubmissionFilter, !store.portals.isEmpty, !store.isRefreshing else { return }
            store.refreshAll()
        }
        // 小组件深链：切换到对应模块；搜索词由 onChange(of: filter) 统一清空
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("GaoSeries.research.game"))) { _ in filter = .rewardCity }
        .onReceive(NotificationCenter.default.publisher(for: .appOpenWidgetDeepLink)) { note in
            guard let target = note.object as? String else { return }
            switch target {
            case "submissions":
                if filter != .all { filter = .all } else { search = "" }
            case "works":
                if filter != .existing { filter = .existing } else { search = "" }
            default:
                break
            }
        }
        .onAppear {
            if searchEscapeMonitor == nil {
                let searchBinding = $search
                let focusBinding = $searchFocused
                searchEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { (event: NSEvent) -> NSEvent? in
                    // ESC：仅在搜索框聚焦时清空并取消焦点，其余情况放行
                    guard event.keyCode == 53, focusBinding.wrappedValue else { return event }
                    searchBinding.wrappedValue = ""
                    focusBinding.wrappedValue = false
                    return nil
                }
            }
            syncMenuCommandState()
        }
        .onDisappear {
            if let monitor = searchEscapeMonitor {
                NSEvent.removeMonitor(monitor)
                searchEscapeMonitor = nil
            }
        }
        // 切换模块时清空搜索词（简单可预期），并同步菜单命令状态
        .onChange(of: filter) { _ in
            if !search.isEmpty { search = "" }
            syncMenuCommandState()
        }
        .onChange(of: store.portals.count) { _ in syncMenuCommandState() }
        .onChange(of: store.isRefreshing) { _ in syncMenuCommandState() }
        .onChange(of: settings.language) { _ in syncMenuCommandState() }
        .task {
            if settings.notificationsEnabled {
                _ = await NotificationManager.shared.configure(
                    store: store,
                    settings: settings,
                    requestAuthorization: false
                )
            }
        }
    }

    // MARK: 自绘侧边栏（词元标杆）：品牌头部 + 搜索框 + 浮动卡片选中态导航行 + 投稿门户 + 状态底卡

    private var sidebar: some View {
        VStack(spacing: 0) {
            brandHeader
            searchField
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // 「有更新」「已归档」紧邻「在投管理」，不再隔在奖励模块之后
                    sidebarSection(AppLocalization.text("管理模块"), filters: [
                        .all, .changed, .hidden,
                        .existing, .projects, .experimentData,
                        .summaryReports, .importantLiterature, .certificates, .funding,
                    ])
                    sidebarSection(AppLocalization.text("奖励模块"), filters: [.rewardCity])
                    if filter.isSubmissionFilter && !store.portals.isEmpty {
                        portalSection
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            statusFooter
        }
        .frame(width: 236)
        .frame(maxHeight: .infinity)
        .background(.regularMaterial)
    }

    private var brandHeader: some View {
        HStack(spacing: 10) {
            if let image = NSImage(contentsOf: ResearchBundle.bundle.url(forResource: "AcademicAchievementManagerIcon", withExtension: "png") ?? URL(fileURLWithPath: "")) {
                Image(nsImage: image).resizable()
                    .interpolation(.high)
                    .frame(width: 38, height: 38)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(AppLocalization.text("搞研究")).font(.headline)
                Text(AppLocalization.text("投稿、成果与研究资产")).font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity)
    }

    /// 搜索框是模块既有功能（⌘F 聚焦、逐筛选换提示语），新侧栏原样保留、仅视觉对齐标杆。
    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(searchPrompt, text: $search)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !search.isEmpty {
                Button {
                    search = ""
                    searchFocused = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(AppLocalization.text("清除搜索"))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 14)
        .padding(.bottom, 2)
    }

    @ViewBuilder private func sidebarSection(_ title: String, filters: [LibraryFilter]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            ForEach(filters) { sidebarRow($0) }
        }
    }

    /// 浮动卡片选中态导航行：accent 底白字 + 柔和投影（深色下投影 opacity 调高），hover 浅灰反馈；计数胶囊保留。
    private func sidebarRow(_ item: LibraryFilter) -> some View {
        let selected = filter == item
        let hovered = hoveredFilter == item
        return Button { filter = item } label: {
            HStack(spacing: 10) {
                Image(systemName: item.symbol)
                    .font(.callout)
                    .frame(width: 20)
                    .accessibilityHidden(true)
                Text(item.title)
                    .font(.callout.weight(selected ? .semibold : .regular))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count(for: item))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(selected ? Color.white : Color.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 2)
                    .background(selected ? Color.white.opacity(0.22) : Color.primary.opacity(0.05), in: Capsule())
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 32)
            .foregroundStyle(selected ? Color.white : Color.primary)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(AppTheme.blue)
                        .shadow(color: AppTheme.blue.opacity(colorScheme == .dark ? 0.45 : 0.32), radius: 5, y: 2)
                } else if hovered {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering in hoveredFilter = hovering ? item : nil }
    }

    /// 投稿门户分组（仅投稿筛选且有门户时显示）：行内按钮行为与旧 List 版完全一致——
    /// 点击重新打开登录窗口、右侧垃圾桶删除、右键菜单删除。
    private var portalSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(AppLocalization.text("投稿门户"))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.bottom, 2)
            ForEach(store.portals) { portal in
                let stale = portal.lastChecked.map { Date().timeIntervalSince($0)>86400 } ?? true
                HStack(spacing: 6) {
                    Button {
                        importContext = ImportContext(publisher: publisher(for: portal))
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: portal.lastError != nil ? "exclamationmark" : stale ? "clock" : "checkmark")
                                .font(.caption.bold())
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(portal.lastError != nil ? Color.orange : stale ? Color.secondary : AppTheme.teal, in: Circle())
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(portal.publisherName)
                                    .font(.callout.weight(.medium))
                                    .lineLimit(1)
                                Text((URL(string: portal.url)?.host ?? portal.name) + "/" + (URL(string: portal.url)?.path.split(separator: "/").first.map(String.init) ?? ""))
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption2.bold())
                                .foregroundStyle(.tertiary)
                                .accessibilityHidden(true)
                        }
                        .padding(.vertical, 5)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityValue(portal.lastError != nil ? "同步有错误" : stale ? "历史状态，需刷新" : "最近同步正常")
                    .help(AppLocalization.text("重新打开登录窗口"))
                    Button {
                        portalToRemove = portal
                    } label: {
                        Image(systemName: "trash")
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .disabled(store.isRefreshing)
                    .accessibilityLabel(AppLocalization.text("删除门户"))
                    .help(AppLocalization.text("删除门户"))
                }
                .contextMenu {
                    Button(AppLocalization.text("删除门户"), role: .destructive) { portalToRemove = portal }
                        .disabled(store.isRefreshing)
                }
            }
        }
    }

    /// 状态底卡（词元 statusFooter 风格）：门户同步状态 + 存储说明。
    private var statusFooter: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle().fill(store.isRefreshing ? AppTheme.blue : AppTheme.teal).frame(width: 7, height: 7)
                Text(store.isRefreshing
                     ? AppLocalization.text("正在同步投稿门户…")
                     : AppLocalization.format("%d 个投稿门户", store.portals.count)).font(.caption)
                Spacer(minLength: 0)
            }
            Text(AppLocalization.text("本地存储 · 每日自动备份")).font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var dashboard: some View {
        ZStack {
            AppTheme.canvas.ignoresSafeArea()
            VStack(spacing: 0) {
                DashboardHeader(filter: filter)
                if filter.isSubmissionFilter && (store.isRefreshing || !store.refreshMessage.isEmpty) {
                    HStack(spacing: 10) {
                        if store.isRefreshing { ProgressView().controlSize(.small) }
                        Image(systemName: store.isRefreshing ? "network" : "checkmark.circle.fill")
                            .foregroundStyle(store.isRefreshing ? Color.accentColor : Color.green)
                            .accessibilityHidden(true)
                        Text(store.refreshMessage)
                            .font(.callout)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(AppTheme.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 12).stroke(AppTheme.blue.opacity(0.15)))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 10)
                }

                if filter == .existing {
                    ExistingWorksDashboard(
                        works: displayedWorks,
                        isSearching: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        openAction: { selectedWork = $0 },
                        createAction: { existingWorkEditorContext = ExistingWorkEditorContext(workID: nil) }
                    )
                } else if filter == .projects {
                    ProjectDashboard(
                        projects: displayedProjects,
                        isSearching: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        openAction: { selectedProject = $0 },
                        createAction: { projectEditorContext = ProjectEditorContext(projectID: nil) }
                    )
                } else if let kind = filter.documentLibraryKind {
                    DocumentLibraryDashboard(
                        kind: kind,
                        search: search,
                        createFolderAction: {
                            documentFolderEditorContext = DocumentFolderEditorContext(kind: kind, folderID: nil)
                        },
                        editFolderAction: { folder in
                            documentFolderEditorContext = DocumentFolderEditorContext(kind: kind, folderID: folder.id)
                        },
                        editDocumentAction: { document in
                            managedDocumentEditorContext = ManagedDocumentEditorContext(documentID: document.id)
                        }
                    )
                    .id(kind)
                } else if filter == .certificates {
                    CertificateDashboard(
                        records: displayedCertificates,
                        isSearching: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        openAction: { selectedCertificate = $0 },
                        createAction: { certificateEditorContext = CertificateEditorContext(recordID: nil) }
                    )
                } else if filter == .funding {
                    FundingDashboard(
                        records: displayedFundingRecords,
                        allRecords: store.fundingRecords,
                        isSearching: !search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                        openAction: { fundingEditorContext = FundingEditorContext(recordID: $0.id) },
                        createAction: { fundingEditorContext = FundingEditorContext(recordID: nil) }
                    )
                } else if filter == .rewardCity {
                    RewardCityDashboard()
                } else if displayedPapers.isEmpty {
                    EmptyLibraryView(
                        filter: filter,
                        manualAction: { manualSubmissionContext = ManualSubmissionContext(paperID: nil) },
                        importAction: { importContext = ImportContext(publisher: nil) }
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 18) {
                            if filter == .all {
                                DisclosureGroup("投稿统计与趋势") { SubmissionAnalytics(papers: displayedPapers) }
                            }

                            LazyVStack(spacing: 12) {
                                ForEach(displayedPapers) { paper in
                                    PaperCard(
                                        paper: paper,
                                        action: {
                                            selectedPaper = paper
                                            if paper.changed { store.markRead(paper) }
                                        },
                                        deleteAction: {
                                            paperPendingDeletion = paper
                                        }
                                    )
                                    .onDrag {
                                        draggedPaperID = paper.id
                                        return NSItemProvider(object: paper.id as NSString)
                                    }
                                    .onDrop(
                                        of: [UTType.plainText],
                                        delegate: ReorderDropDelegate.paper(
                                            targetID: paper.id,
                                            draggedID: $draggedPaperID,
                                            store: store
                                        )
                                    )
                                }
                            }
                        }
                        .frame(maxWidth: 1100)
                        .padding(.horizontal, 24)
                        .padding(.bottom, 28)
                    }
                }
            }
        }
    }

    private func count(for item: LibraryFilter) -> Int {
        switch item {
        case .all: store.visiblePapers.count
        case .existing: store.existingWorks.count
        case .projects: store.projects.count
        case .experimentData: store.documentCount(for: .experimentData)
        case .summaryReports: store.documentCount(for: .summaryReports)
        case .importantLiterature: store.documentCount(for: .importantLiterature)
        case .certificates: store.certificates.count
        case .funding: store.fundingRecords.count
        case .rewardCity: store.rewardCity.placements.count
        case .changed: store.changedCount
        case .hidden: store.papers.filter(\.hidden).count
        }
    }

    /// 是否有 sheet/编辑器正在展示；展示中忽略菜单命令，避免重复弹出。
    private var hasActiveSheet: Bool {
        selectedPaper != nil
            || selectedWork != nil
            || selectedProject != nil
            || selectedCertificate != nil
            || importContext != nil
            || manualSubmissionContext != nil
            || existingWorkEditorContext != nil
            || projectEditorContext != nil
            || certificateEditorContext != nil
            || fundingEditorContext != nil
            || documentFolderEditorContext != nil
            || managedDocumentEditorContext != nil
            || showingTrash
    }

    /// ⌘N：与工具栏「新建」按钮走同一组状态机入口。
    private func createRecordForCurrentFilter() {
        switch filter {
        case .existing:
            existingWorkEditorContext = ExistingWorkEditorContext(workID: nil)
        case .projects:
            projectEditorContext = ProjectEditorContext(projectID: nil)
        case .experimentData, .summaryReports, .importantLiterature:
            if let kind = filter.documentLibraryKind {
                documentFolderEditorContext = DocumentFolderEditorContext(kind: kind, folderID: nil)
            }
        case .certificates:
            certificateEditorContext = CertificateEditorContext(recordID: nil)
        case .funding:
            fundingEditorContext = FundingEditorContext(recordID: nil)
        case .all, .changed, .hidden:
            manualSubmissionContext = ManualSubmissionContext(paperID: nil)
        case .rewardCity:
            break
        }
    }

    /// 同步菜单栏命令的标题与可用状态（App 侧 .commands 读取 MenuCommandState）。
    private func syncMenuCommandState() {
        switch filter {
        case .existing:
            menuState.newRecordTitle = AppLocalization.text("新建成果")
            menuState.canCreateRecord = true
        case .projects:
            menuState.newRecordTitle = AppLocalization.text("新建项目")
            menuState.canCreateRecord = true
        case .experimentData, .summaryReports, .importantLiterature:
            menuState.newRecordTitle = AppLocalization.text("新建文件夹")
            menuState.canCreateRecord = true
        case .certificates:
            menuState.newRecordTitle = AppLocalization.text("新建证书记录")
            menuState.canCreateRecord = true
        case .funding:
            menuState.newRecordTitle = AppLocalization.text("新建资金记录")
            menuState.canCreateRecord = true
        case .all, .changed, .hidden:
            menuState.newRecordTitle = AppLocalization.text("添加在投论文")
            menuState.canCreateRecord = true
        case .rewardCity:
            menuState.newRecordTitle = AppLocalization.text("添加在投论文")
            menuState.canCreateRecord = false
        }
        menuState.canRefreshSubmissions = filter.isSubmissionFilter && !store.portals.isEmpty && !store.isRefreshing
    }

    private func publisher(for portal: PortalAccount) -> PublisherDefinition {
        let base = portal.publisher
        return PublisherDefinition(
            id: base.id,
            name: base.name,
            kind: base.kind,
            url: portal.url,
            subtitle: base.subtitle,
            symbol: base.symbol,
            brands: base.brands
        )
    }
}

private struct SubmissionCountDatum: Identifiable {
    let id: String
    let label: String
    let count: Int
}

private enum SubmissionAlertLevel: String, CaseIterable {
    case overdue
    case watch
    case normal
    case completed

    var title: String {
        switch self {
        case .overdue: AppLocalization.text("超期")
        case .watch: AppLocalization.text("关注")
        case .normal: AppLocalization.text("正常")
        case .completed: AppLocalization.text("终态")
        }
    }

    var color: Color {
        switch self {
        case .overdue: .red
        case .watch: .orange
        case .normal: AppTheme.blue
        case .completed: .secondary
        }
    }
}

private struct SubmissionDurationDatum: Identifiable {
    let id: String
    let label: String
    let days: Int
    let level: SubmissionAlertLevel
}

private struct SubmissionAnalytics: View {
    let papers: [PaperRecord]

    private var statusData: [SubmissionCountDatum] {
        Dictionary(grouping: papers) {
            let status = $0.status.trimmingCharacters(in: .whitespacesAndNewlines)
            return localizedSubmissionStatus(status.isEmpty ? AppLocalization.text("未填写") : status)
        }
            .map { status, records in
                SubmissionCountDatum(id: status, label: status, count: records.count)
            }
            .sorted {
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.label < $1.label
            }
    }

    private var durationData: [SubmissionDurationDatum] {
        papers.map { paper in
            let days = max(0, Calendar.current.dateComponents(
                [.day],
                from: Calendar.current.startOfDay(for: paper.statusSince),
                to: Calendar.current.startOfDay(for: Date())
            ).day ?? 0)
            let title = paper.title.count > 26 ? "\(paper.title.prefix(26))…" : paper.title
            let identifier = paper.manuscriptID == "未填写" ? String(paper.id.prefix(6)) : paper.manuscriptID
            return SubmissionDurationDatum(
                id: paper.id,
                label: "\(title) · \(identifier)",
                days: days,
                level: alertLevel(for: paper.status, days: days)
            )
        }
        .sorted {
            if $0.days != $1.days { return $0.days > $1.days }
            return $0.label < $1.label
        }
    }

    private var overdueCount: Int { durationData.filter { $0.level == .overdue }.count }
    private var watchCount: Int { durationData.filter { $0.level == .watch }.count }

    var body: some View {
        VStack(spacing: 14) {
            SubmissionAnalyticsCard(
                title: "当前投稿状态分布",
                subtitle: "按当前列表中的论文状态自动统计"
            ) {
                Chart(statusData) { item in
                    BarMark(
                        x: .value(AppLocalization.text("论文数量"), item.count),
                        y: .value(AppLocalization.text("投稿状态"), item.label)
                    )
                    .foregroundStyle(AppTheme.blue.gradient)
                    .cornerRadius(3)
                    .annotation(position: .trailing) {
                        Text("\(item.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxis {
                    AxisMarks(position: .bottom) {
                        AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                        AxisValueLabel()
                    }
                }
                .frame(height: max(190, CGFloat(statusData.count) * 30))
                .accessibilityChartDescriptor(ChartAccessibility.descriptor(
                    title: AppLocalization.text("当前投稿状态分布"),
                    summary: AppLocalization.format(
                        "共 %d 种投稿状态，合计 %d 篇论文",
                        statusData.count,
                        statusData.reduce(0) { $0 + $1.count }
                    ),
                    categoryAxisTitle: AppLocalization.text("投稿状态"),
                    valueAxisTitle: AppLocalization.text("论文数量"),
                    points: statusData.map { (category: $0.label, value: Double($0.count)) },
                    valueDescription: { AppLocalization.format("%d 篇", Int($0)) }
                ))
            }

            SubmissionAnalyticsCard(
                title: "各论文状态持续时间",
                subtitle: "60–89 天标为关注，满 90 天标为超期；终态稿件不提醒"
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    Chart(durationData) { item in
                        BarMark(
                            x: .value(AppLocalization.text("持续天数"), item.days),
                            y: .value(AppLocalization.text("论文"), item.label)
                        )
                        .foregroundStyle(by: .value(AppLocalization.text("提醒级别"), item.level.title))
                        .cornerRadius(3)
                        .annotation(position: .trailing) {
                            Text(item.level == .normal || item.level == .completed
                                 ? AppLocalization.format("%d 天", item.days)
                                 : "\(AppLocalization.format("%d 天", item.days)) · \(item.level.title)")
                                .font(.caption2)
                                .foregroundStyle(item.level.color)
                                .lineLimit(1)
                        }
                    }
                    .chartForegroundStyleScale([
                        SubmissionAlertLevel.overdue.title: Color.red,
                        SubmissionAlertLevel.watch.title: Color.orange,
                        SubmissionAlertLevel.normal.title: AppTheme.blue,
                        SubmissionAlertLevel.completed.title: Color.secondary,
                    ])
                    .chartLegend(position: .top, alignment: .leading, spacing: 14)
                    .chartXAxis {
                        AxisMarks(position: .bottom) {
                            AxisGridLine().foregroundStyle(Color.primary.opacity(0.08))
                            AxisValueLabel()
                        }
                    }
                    .frame(height: max(220, CGFloat(durationData.count) * 32))
                    .accessibilityChartDescriptor(ChartAccessibility.descriptor(
                        title: AppLocalization.text("各论文状态持续时间"),
                        summary: AppLocalization.format(
                            "共 %d 篇论文，最长持续 %d 天",
                            durationData.count,
                            durationData.map(\.days).max() ?? 0
                        ),
                        categoryAxisTitle: AppLocalization.text("论文"),
                        valueAxisTitle: AppLocalization.text("持续天数"),
                        points: durationData.map { (category: $0.label, value: Double($0.days)) },
                        valueDescription: { AppLocalization.format("%d 天", Int($0)) }
                    ))

                    HStack(spacing: 14) {
                        Label(AppLocalization.format("超期 %d", overdueCount), systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(overdueCount > 0 ? Color.red : Color.secondary)
                        Label(AppLocalization.format("关注 %d", watchCount), systemImage: "clock.badge.exclamationmark")
                            .foregroundStyle(watchCount > 0 ? Color.orange : Color.secondary)
                    }
                    .font(.caption.weight(.medium))
                }
            }
        }
    }

    private func alertLevel(for status: String, days: Int) -> SubmissionAlertLevel {
        // 终态判断统一走 SubmissionStatusClassifier（与通知提醒、小组件导出同一权威来源）
        if SubmissionStatusClassifier.isTerminal(status) { return .completed }
        if days >= 90 { return .overdue }
        if days >= 60 { return .watch }
        return .normal
    }

    private func localizedSubmissionStatus(_ status: String) -> String {
        let normalized = status.lowercased()
        let mappings: [(keywords: [String], key: String)] = [
            (["accepted", "accept", "已接受", "接收", "录用"], "已接受"),
            (["under review", "in review", "外审", "审稿中"], "审稿中"),
            (["screening", "technical check", "initial check", "初审", "形式审查"], "初审中"),
            (["revision", "revise", "修改"], "修改中"),
            (["rejected", "reject", "declined", "拒稿"], "已拒稿"),
            (["withdrawn", "withdraw", "撤稿"], "已撤稿"),
            (["submitted", "submission received", "已投稿", "已提交"], "已提交"),
        ]
        for mapping in mappings where mapping.keywords.contains(where: normalized.contains) {
            return AppLocalization.text(mapping.key)
        }
        return status
    }
}

private struct SubmissionAnalyticsCard<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(AppLocalization.text(title))
                    .font(.headline)
                Text(AppLocalization.text(subtitle))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.07)))
    }
}

private struct DashboardHeader: View {
    @EnvironmentObject private var store: PaperStore
    let filter: LibraryFilter

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(filter.title)
                        .font(.system(size: 28, weight: .semibold))
                    Text(lastCheckedText)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 12) {
                if filter == .existing {
                    StatCard(value: store.existingWorks.count, label: "成果总数", symbol: "checkmark.seal", color: AppTheme.blue)
                    StatCard(
                        value: store.existingWorks.reduce(0) { $0 + $1.attachments.count },
                        label: "附件",
                        symbol: "paperclip",
                        color: AppTheme.teal
                    )
                    StatCard(value: currentYearCount, label: "本年成果", symbol: "calendar", color: .orange)
                } else if filter == .projects {
                    StatCard(value: store.projects.count, label: "项目总数", symbol: "folder", color: AppTheme.blue)
                    StatCard(
                        value: store.projects.reduce(0) { $0 + $1.steps.count },
                        label: "项目步骤",
                        symbol: "list.bullet.clipboard",
                        color: AppTheme.teal
                    )
                    StatCard(
                        value: store.projects.reduce(0) { $0 + $1.completedStepCount },
                        label: "已完成步骤",
                        symbol: "checkmark.circle",
                        color: .orange
                    )
                } else if let kind = filter.documentLibraryKind {
                    StatCard(
                        value: store.documentFolders.filter { $0.libraryKind == kind }.count,
                        label: "文件夹",
                        symbol: "folder",
                        color: AppTheme.blue
                    )
                    StatCard(
                        value: store.documentCount(for: kind),
                        label: "文件",
                        symbol: "doc",
                        color: AppTheme.teal
                    )
                    let folderIDs = Set(store.documentFolders.filter { $0.libraryKind == kind }.map(\.id))
                    StatCard(
                        value: Set(store.managedDocuments.filter { folderIDs.contains($0.folderID) }.flatMap(\.tags)).count,
                        label: "标签",
                        symbol: "tag",
                        color: .orange
                    )
                } else if filter == .certificates {
                    StatCard(value: store.certificates.count, label: "记录总数", symbol: "rectangle.badge.checkmark", color: AppTheme.blue)
                    StatCard(
                        value: Set(store.certificates.flatMap(\.tags)).count,
                        label: "标签种类",
                        symbol: "tag",
                        color: AppTheme.teal
                    )
                    StatCard(
                        value: store.certificates.reduce(0) { $0 + $1.attachments.count },
                        label: "附件",
                        symbol: "paperclip",
                        color: .orange
                    )
                } else if filter == .funding {
                    StatCard(value: store.fundingRecords.count, label: "资金项目", symbol: "banknote", color: AppTheme.blue)
                    StatCard(
                        value: Set(store.fundingRecords.map(\.receivingAccount)).count,
                        label: "收款账户",
                        symbol: "creditcard",
                        color: AppTheme.teal
                    )
                    StatCard(
                        value: currentYearFundingCount,
                        label: "本年安排",
                        symbol: "calendar",
                        color: .orange
                    )
                } else if filter == .rewardCity {
                    StatCard(
                        value: Int(store.rewardCity.coins + store.pendingRewardCoins()),
                        label: "金币",
                        symbol: "dollarsign.circle",
                        color: .orange
                    )
                    StatCard(
                        value: store.rewardCity.buildingTickets,
                        label: "房屋券",
                        symbol: "ticket",
                        color: AppTheme.blue
                    )
                    StatCard(
                        value: store.rewardCity.decorationTickets,
                        label: "摆件券",
                        symbol: "seal",
                        color: AppTheme.teal
                    )
                } else {
                    // 3.36：口径拆分——总数是「论文记录」，另列「仍在投 / 已接受」（终态不再算在投）。
                    StatCard(value: store.visiblePapers.count, label: "论文记录", symbol: "doc.text", color: AppTheme.blue)
                    StatCard(value: store.inReviewPapers.count, label: "仍在投", symbol: "paperplane", color: AppTheme.teal)
                    StatCard(value: store.acceptedPapers.count, label: "已接受", symbol: "checkmark.seal", color: .green)
                    StatCard(value: store.changedCount, label: "状态更新", symbol: "bell.badge", color: .orange)
                    StatCard(value: store.portals.count, label: "投稿门户", symbol: "link", color: AppTheme.teal)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 22)
    }

    private var lastCheckedText: String {
        if filter == .existing {
            guard let date = store.existingWorks.map(\.updatedAt).max() else {
                return AppLocalization.text("手动建立已发表论文、会议成果和其他学术产出")
            }
            return AppLocalization.format("最近更新：%@", Formatters.dateTime.string(from: date))
        }
        if filter == .projects {
            guard let date = store.projects.map(\.updatedAt).max() else {
                return AppLocalization.text("创建项目并自定义内容、步骤和时间节点")
            }
            return AppLocalization.format("最近更新：%@", Formatters.dateTime.string(from: date))
        }
        if let kind = filter.documentLibraryKind {
            let folderIDs = Set(store.documentFolders.filter { $0.libraryKind == kind }.map(\.id))
            let latestFolderDate = store.documentFolders
                .filter { $0.libraryKind == kind }
                .map(\.updatedAt)
                .max()
            let latestDocumentDate = store.managedDocuments
                .filter { folderIDs.contains($0.folderID) }
                .map(\.updatedAt)
                .max()
            if let date = [latestFolderDate, latestDocumentDate].compactMap({ $0 }).max() {
                return AppLocalization.format("最近更新：%@", Formatters.dateTime.string(from: date))
            }
            return kind.folderPrompt
        }
        if filter == .certificates {
            guard let date = store.certificates.map(\.updatedAt).max() else {
                return AppLocalization.text("用多维表格管理证书、标签和附件")
            }
            return AppLocalization.format("最近更新：%@", Formatters.dateTime.string(from: date))
        }
        if filter == .funding {
            guard let date = store.fundingRecords.map(\.updatedAt).max() else {
                return AppLocalization.text("按年度和月份管理资金组成与收款账户")
            }
            return AppLocalization.format("最近更新：%@", Formatters.dateTime.string(from: date))
        }
        if filter == .rewardCity {
            return AppLocalization.text("让每一份学术积累，长成属于你的绿色研究城")
        }
        guard let date = store.lastChecked else { return AppLocalization.text("连接投稿门户，开始整理你的学术成果") }
        return AppLocalization.format("最近检查：%@", Formatters.dateTime.string(from: date))
    }

    private var currentYearCount: Int {
        let calendar = Calendar.current
        let year = calendar.component(.year, from: Date())
        return store.existingWorks.filter {
            calendar.component(.year, from: $0.completedAt) == year
        }.count
    }

    private var currentYearFundingCount: Int {
        let year = Calendar.current.component(.year, from: Date())
        return store.fundingRecords.filter { $0.year == year }.count
    }
}

private struct StatCard: View {
    let value: Int
    let label: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(color)
                .frame(width: 32, height: 32)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(value)")
                    .font(.title3.weight(.semibold).monospacedDigit())
                Text(AppLocalization.text(label))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.07)))
        .accessibilityElement(children: .combine)
    }
}

private struct EmptyLibraryView: View {
    let filter: LibraryFilter
    let manualAction: () -> Void
    let importAction: () -> Void

    var body: some View {
        VStack(spacing: 17) {
            Spacer()
            Image(systemName: filter == .hidden ? "archivebox.fill" : "doc.badge.plus")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(AppTheme.blue)
                .frame(width: 72, height: 72)
                .background(AppTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                .accessibilityHidden(true)
            Text(AppLocalization.text(filter == .hidden ? "归档中没有论文" : filter == .changed ? "暂时没有新的状态变化" : "还没有在投论文"))
                .font(.system(size: 23, weight: .semibold))
            Text(AppLocalization.text(filter == .all
                 ? "可以手动建立记录，也可以登录出版商系统自动导入。"
                 : "状态变化会保留在本机历史记录中。"))
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .lineSpacing(4)
                .frame(maxWidth: 460)
            if filter == .all {
                HStack(spacing: 10) {
                    Button(action: manualAction) {
                        Label(AppLocalization.text("手动添加"), systemImage: "square.and.pencil")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.blue)
                    Button(action: importAction) {
                        Label(AppLocalization.text("从投稿系统导入"), systemImage: "safari")
                    }
                    .buttonStyle(.bordered)
                }
                .font(.headline)
                .controlSize(.large)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(42)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.primary.opacity(0.07)))
        .padding(.horizontal, 24)
        .padding(.bottom, 24)
    }
}

private struct PaperCard: View {
    @EnvironmentObject private var store: PaperStore
    let paper: PaperRecord
    let action: () -> Void
    let deleteAction: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 15) {
                Image(systemName: paper.changed ? "bell.badge.fill" : "doc.text.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(paper.changed ? Color.orange : AppTheme.blue)
                    .frame(width: 38, height: 38)
                    .background((paper.changed ? Color.orange : AppTheme.blue).opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        Text(paper.site.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(AppTheme.blue)
                        Text("·")
                            .foregroundStyle(.tertiary)
                        Text(paper.displayManuscriptID)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                        if paper.changed {
                            Text(AppLocalization.text("有更新"))
                                .font(.caption2.bold())
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.orange.opacity(0.14), in: Capsule())
                                .foregroundStyle(.orange)
                        }
                    }
                    Text(paper.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Text(paper.journal)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 16)

                VStack(alignment: .trailing, spacing: 7) {
                    Text(paper.status)
                        .font(.callout.weight(.bold))
                        .foregroundStyle(paper.changed ? Color.orange : AppTheme.indigo)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background((paper.changed ? Color.orange : AppTheme.blue).opacity(0.1), in: Capsule())
                    Text(AppLocalization.format("此阶段 %@", Formatters.duration(since: paper.statusSince)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(AppLocalization.format("更新于 %@", Formatters.shortDate.string(from: paper.checkedAt)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: 230, alignment: .trailing)

                Image(systemName: "line.3.horizontal")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
                    .help(AppLocalization.text("上下拖动调整顺序"))
            }
            .padding(17)
            .contentShape(Rectangle())
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).fill(AppTheme.blue.opacity(hovering ? 0.05 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(paper.changed ? Color.orange.opacity(hovering ? 0.42 : 0.28) : Color.primary.opacity(hovering ? 0.16 : 0.07)))
        }
        .buttonStyle(.plain)
        // 悬停反馈：轻微提亮 + 手型指针（推入/弹出成对，避免悬停状态残留）
        .onHover { isHovering in
            if isHovering == hovering { return }
            hovering = isHovering
            if isHovering { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
        .contextMenu {
            Button(AppLocalization.text("查看详情")) { action() }
            Button(AppLocalization.text(paper.hidden ? "恢复追踪" : "归档")) {
                store.setArchived(paper, archived: !paper.hidden)
            }
            Divider()
            Button(AppLocalization.text("删除"), role: .destructive) { deleteAction() }
        }
    }
}

struct PaperDetailView: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.dismiss) private var dismiss
    let paperID: String
    @State private var confirmDelete = false
    @State private var editManual = false

    private var paper: PaperRecord? { store.papers.first { $0.id == paperID } }

    var body: some View {
        Group {
            if let paper {
                VStack(spacing: 0) {
                    HStack {
                        Text(AppLocalization.text("论文详情"))
                            .font(.headline)
                        Spacer()
                        Button(AppLocalization.text("完成")) { dismiss() }
                            .keyboardShortcut(.cancelAction)
                    }
                    .padding()
                    Divider()

                    ScrollView {
                        VStack(alignment: .leading, spacing: 22) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(paper.site.uppercased())
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text(paper.title)
                                    .font(.system(size: 25, weight: .bold, design: .rounded))
                                Text(paper.journal)
                                    .foregroundStyle(.secondary)
                                Text(AppLocalization.format("稿号：%@", paper.displayManuscriptID))
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                Text(AppLocalization.text("当前状态"))
                                    .font(.caption.bold())
                                    .foregroundStyle(.secondary)
                                Text(paper.status)
                                    .font(.title3.bold())
                                Text(AppLocalization.format("已处于此阶段 %@ · %@", Formatters.duration(since: paper.statusSince), paper.statusSinceSource))
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(16)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(AppTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                            if let submissionHistory = paper.submissionHistory, !submissionHistory.isEmpty {
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(AppLocalization.text("投稿记录"))
                                        .font(.headline)
                                    Text(submissionHistory)
                                        .textSelection(.enabled)
                                }
                            }

                            VStack(alignment: .leading, spacing: 12) {
                                Text(AppLocalization.text("本地状态历史"))
                                    .font(.headline)
                                ForEach(paper.history.reversed()) { event in
                                    HStack(alignment: .top, spacing: 12) {
                                        Circle()
                                            .fill(event.status == paper.status ? AppTheme.teal : Color.secondary.opacity(0.4))
                                            .frame(width: 9, height: 9)
                                            .padding(.top, 5)
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(event.status)
                                                .font(.callout.weight(.medium))
                                            Text(Formatters.dateTime.string(from: event.checkedAt))
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }

                            Divider()

                            HStack {
                                if paper.isManual {
                                    Button {
                                        editManual = true
                                    } label: {
                                        Label(AppLocalization.text("编辑信息与状态"), systemImage: "square.and.pencil")
                                    }
                                    .buttonStyle(.borderedProminent)
                                }
                                if !paper.url.isEmpty {
                                    Button {
                                        if let url = URL(string: paper.url) { NSWorkspace.shared.open(url) }
                                    } label: {
                                        Label(AppLocalization.text(paper.isManual ? "打开相关网页" : "在浏览器中打开门户"), systemImage: "safari")
                                    }
                                }
                                Button(AppLocalization.text(paper.hidden ? "恢复追踪" : "归档")) {
                                    store.setArchived(paper, archived: !paper.hidden)
                                    dismiss()
                                }
                                Spacer()
                                Button(AppLocalization.text("删除记录"), role: .destructive) { confirmDelete = true }
                            }
                        }
                        .padding(28)
                    }
                }
            } else {
                Text(AppLocalization.text("这篇论文已被删除。"))
                    .padding(40)
            }
        }
        .frame(minWidth: 660, minHeight: 600)
        .alert(AppLocalization.text("删除论文及其本地历史？"), isPresented: $confirmDelete) {
            Button(AppLocalization.text("取消"), role: .cancel) {}
            Button(AppLocalization.text("删除"), role: .destructive) {
                if let paper { store.delete(paper) }
                dismiss()
            }
        } message: {
            Text(AppLocalization.text("记录会移入回收站，可在30天内恢复；不会影响出版商网站上的论文。"))
        }
        .sheet(isPresented: $editManual) {
            ManualSubmissionEditor(paper: paper)
                .environmentObject(store)
        }
    }
}

struct ImportSheetView: View {
    @EnvironmentObject private var store: PaperStore
    @Environment(\.closePortalWindow) private var dismiss
    @State private var selectedPublisher: PublisherDefinition?
    @State private var urlPublisher: PublisherDefinition?
    @State private var customName = ""
    @State private var customURL = ""

    init(initialPublisher: PublisherDefinition?) {
        _selectedPublisher = State(initialValue: initialPublisher)
    }

    var body: some View {
        Group {
            if let publisher = selectedPublisher {
                PortalImporterView(publisher: publisher, store: store) {
                    selectedPublisher = nil
                }
            } else if let publisher = urlPublisher {
                journalURLSetup(for: publisher)
            } else {
                publisherPicker
            }
        }
        .frame(minWidth: 900, minHeight: 650)
    }

    private var publisherPicker: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(AppLocalization.text("连接投稿门户"))
                        .font(.title2.bold())
                    Text(AppLocalization.text("选择论文投稿系统，在内置网页中登录并导入成果。"))
                        .foregroundStyle(.secondary)
                    Label(AppLocalization.text("暂不支持中文期刊自动导入跟踪，请手动导入"), systemImage: "info.circle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.orange)
                        .padding(.top, 5)
                }
                Spacer()
                Button(AppLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(22)
            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    ForEach(PublisherDefinition.builtIns) { publisher in
                        Button {
                            choosePublisher(publisher)
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: publisher.symbol)
                                    .font(.title2)
                                    .foregroundStyle(AppTheme.blue)
                                    .frame(width: 44, height: 44)
                                    .background(AppTheme.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 11))
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(publisher.name)
                                        .font(.headline)
                                        .foregroundStyle(.primary)
                                    Text(publisher.brands)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                                    .accessibilityHidden(true)
                            }
                            .padding(14)
                            .contentShape(Rectangle())
                            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                            .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.07)))
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label(AppLocalization.text("其他投稿网站"), systemImage: "globe")
                            .font(.headline)
                        Spacer()
                    }
                    HStack {
                        TextField(AppLocalization.text("来源名称（例如：期刊名）"), text: $customName)
                        TextField(AppLocalization.text("https://投稿网站地址"), text: $customURL)
                        Button(AppLocalization.text("打开")) { openCustomPortal() }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.blue)
                            .disabled(customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                    Text(AppLocalization.text("适用于期刊自建系统或尚未列出的投稿门户。"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(16)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 13).stroke(Color.primary.opacity(0.07)))
                .padding(.top, 16)
            }
            .padding(22)
        }
    }

    private func journalURLSetup(for publisher: PublisherDefinition) -> some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    urlPublisher = nil
                    customURL = ""
                } label: {
                    Label(AppLocalization.text("返回"), systemImage: "chevron.left")
                }
                Spacer()
                Button(AppLocalization.text("取消")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(18)
            Divider()

            VStack(spacing: 18) {
                Spacer()
                Image(systemName: publisher.symbol)
                    .font(.system(size: 34, weight: .medium))
                    .foregroundStyle(AppTheme.blue)
                    .frame(width: 72, height: 72)
                    .background(AppTheme.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16))
                    .accessibilityHidden(true)
                VStack(spacing: 7) {
                    Text(publisher.name)
                        .font(.title2.weight(.semibold))
                    Text(AppLocalization.text("该系统由每本期刊提供独立登录网址。请粘贴期刊投稿页面或作者后台网址。"))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: 520)

                HStack(spacing: 10) {
                    TextField(AppLocalization.text("https://期刊投稿系统网址"), text: $customURL)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { openJournalPortal(publisher) }
                    Button(AppLocalization.text("打开并登录")) { openJournalPortal(publisher) }
                        .buttonStyle(.borderedProminent)
                        .tint(AppTheme.blue)
                        .disabled(customURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .frame(maxWidth: 620)

                Text(AppLocalization.text("通常可以从期刊官网的 “Submit manuscript” 链接或投稿确认邮件中找到该网址。"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding(32)
        }
    }

    private func choosePublisher(_ publisher: PublisherDefinition) {
        if publisher.requiresJournalURL {
            customURL = ""
            urlPublisher = publisher
        } else {
            selectedPublisher = publisher
        }
    }

    private func openJournalPortal(_ publisher: PublisherDefinition) {
        var url = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.contains("://") { url = "https://\(url)" }
        selectedPublisher = PublisherDefinition(
            id: publisher.id,
            name: publisher.name,
            kind: publisher.kind,
            url: url,
            subtitle: publisher.subtitle,
            symbol: publisher.symbol,
            brands: publisher.brands
        )
        urlPublisher = nil
    }

    private func openCustomPortal() {
        var url = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !url.contains("://") { url = "https://\(url)" }
        let name = customName.trimmingCharacters(in: .whitespacesAndNewlines)
        selectedPublisher = PublisherDefinition(
            id: "custom-\(UUID().uuidString)",
            name: name.isEmpty ? (URL(string: url)?.host ?? AppLocalization.text("自定义投稿网站")) : name,
            kind: "generic",
            url: url,
            subtitle: AppLocalization.text("自定义投稿网站"),
            symbol: "safari.fill",
            brands: URL(string: url)?.host ?? ""
        )
    }
}

private struct PortalImporterView: View {
    @Environment(\.closePortalWindow) private var dismiss
    @StateObject private var model: PortalBrowserModel
    @State private var showCredentialEditor = false
    let backAction: () -> Void

    init(publisher: PublisherDefinition, store: PaperStore, backAction: @escaping () -> Void) {
        _model = StateObject(wrappedValue: PortalBrowserModel(publisher: publisher, store: store))
        self.backAction = backAction
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Button(action: backAction) { Image(systemName: "chevron.left") }
                    .accessibilityLabel(AppLocalization.text("返回出版商列表"))
                    .help(AppLocalization.text("返回出版商列表"))
                Image(systemName: model.publisher.symbol)
                    .foregroundStyle(AppTheme.blue)
                    .accessibilityHidden(true)
                Text(model.publisher.name)
                    .font(.callout.weight(.semibold))
                Button(action: model.goBack) { Image(systemName: "arrow.left") }
                    .accessibilityLabel(AppLocalization.text("后退"))
                    .disabled(!model.webView.canGoBack)
                Button(action: model.goForward) { Image(systemName: "arrow.right") }
                    .accessibilityLabel(AppLocalization.text("前进"))
                    .disabled(!model.webView.canGoForward)
                Button(action: model.reload) { Image(systemName: "arrow.clockwise") }
                    .accessibilityLabel(AppLocalization.text("重新载入"))

                TextField(AppLocalization.text("投稿网站地址"), text: $model.address)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { model.loadAddress() }
                Button(AppLocalization.text("前往")) { model.loadAddress() }

                Button(AppLocalization.text("完成")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(10)
            .background(.bar)

            Divider()

            PortalWebView(webView: model.webView)

            Divider()

            HStack(spacing: 10) {
                if model.isLoading || model.isExtracting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: model.importedCount > 0 ? "checkmark.circle.fill" : "lock.shield")
                        .foregroundStyle(model.importedCount > 0 ? Color.green : Color.secondary)
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.statusMessage)
                        .font(.callout)
                        .lineLimit(2)
                    if !model.credentialMessage.isEmpty {
                        Text(model.credentialMessage)
                            .font(.caption)
                            .foregroundStyle(AppTheme.blue)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if model.savedCredentials.count == 1, let credential = model.savedCredentials.first {
                    Button {
                        model.oneClickLogin(credentialID: credential.id)
                    } label: {
                        Label(AppLocalization.text("一键登录"), systemImage: "key.fill")
                    }
                    .help(AppLocalization.format("使用账号 %@ 登录", credential.username))
                } else if model.savedCredentials.count > 1 {
                    Menu {
                        ForEach(model.savedCredentials) { credential in
                            Button {
                                model.oneClickLogin(credentialID: credential.id)
                            } label: {
                                Label(credential.username, systemImage: "person.crop.circle")
                            }
                        }
                    } label: {
                        Label(AppLocalization.text("选择账号登录"), systemImage: "key.fill")
                    }
                    .help(AppLocalization.text("为同一期刊选择一个已保存账号并立即登录"))
                }
                Button {
                    showCredentialEditor = true
                } label: {
                    Label(AppLocalization.text(model.hasSavedCredential ? "管理登录信息" : "保存登录信息"), systemImage: "person.badge.key.fill")
                }
                .help(model.credentialMessage.isEmpty ? AppLocalization.text("账号密码仅保存在 macOS 钥匙串") : model.credentialMessage)
                Button(AppLocalization.text("立即导入")) { model.importCurrentPage() }
                    .buttonStyle(.borderedProminent)
                    .tint(AppTheme.blue)
                    .disabled(model.isExtracting)
            }
            .padding(12)
            .background(.bar)
        }
        .sheet(isPresented: $showCredentialEditor) {
            PortalCredentialEditor(model: model)
        }
    }
}

private struct PortalCredentialEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: PortalBrowserModel
    @State private var username: String
    @State private var password: String

    init(model: PortalBrowserModel) {
        self.model = model
        _username = State(initialValue: "")
        _password = State(initialValue: "")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(AppLocalization.text("投稿门户登录信息"))
                        .font(.title2.weight(.semibold))
                    Text(AppLocalization.text("同一期刊可保存多个账号，并选择任一账号一键登录。"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "key.fill")
                    .font(.title2)
                    .foregroundStyle(AppTheme.blue)
                    .accessibilityHidden(true)
            }

            if !model.savedCredentials.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLocalization.text("已保存账号"))
                        .font(.headline)
                    ForEach(model.savedCredentials) { credential in
                        HStack(spacing: 10) {
                            Image(systemName: "person.crop.circle.fill")
                                .foregroundStyle(AppTheme.blue)
                                .accessibilityHidden(true)
                            Text(credential.username)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                username = credential.username
                                password = credential.password
                            } label: {
                                Label(AppLocalization.text("编辑"), systemImage: "pencil")
                            }
                            Button(AppLocalization.text("登录")) {
                                dismiss()
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    model.oneClickLogin(credentialID: credential.id)
                                }
                            }
                            Button(role: .destructive) {
                                model.deleteSavedCredential(credentialID: credential.id)
                                if username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == credential.id {
                                    username = ""
                                    password = ""
                                }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .accessibilityLabel(AppLocalization.text("删除该账号"))
                            .help(AppLocalization.text("删除该账号"))
                        }
                        .padding(10)
                        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
                    }
                }
            }

            VStack(alignment: .leading, spacing: 12) {
                Text(AppLocalization.text(model.savedCredentials.isEmpty ? "添加账号" : "添加或更新账号"))
                    .font(.headline)
                TextField(AppLocalization.text("账号或邮箱"), text: $username)
                    .textContentType(.username)
                SecureField(AppLocalization.text("密码"), text: $password)
                    .textContentType(.password)
            }

            Label(AppLocalization.text("登录信息使用 macOS 钥匙串加密保存，不写入资料库、完整备份或导出的安装包。"), systemImage: "lock.shield.fill")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !model.credentialMessage.isEmpty {
                Text(model.credentialMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(AppLocalization.text("关闭")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(AppLocalization.text("保存")) {
                    if model.saveCredential(username: username, password: password) {
                        username = ""
                        password = ""
                    }
                }
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
                Button(AppLocalization.text("保存并登录")) {
                    if model.saveCredential(username: username, password: password) {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { model.oneClickLogin() }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || password.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 620, height: model.savedCredentials.isEmpty ? 370 : 500)
    }
}

enum Formatters {
    static var dateTime: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.language.locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }

    static var shortDate: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.language.locale
        formatter.setLocalizedDateFormatFromTemplate("MMMd HH:mm")
        return formatter
    }

    static var workDate: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.language.locale
        formatter.setLocalizedDateFormatFromTemplate("yMMM")
        return formatter
    }

    static var longDate: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = AppLocalization.language.locale
        formatter.dateStyle = .long
        return formatter
    }

    static func duration(since date: Date) -> String {
        let seconds = max(0, Date().timeIntervalSince(date))
        let hours = Int(seconds / 3_600)
        if hours < 1 { return AppLocalization.text("不到 1 小时") }
        if hours < 24 { return AppLocalization.format("%d 小时", hours) }
        let days = hours / 24
        if days < 30 { return AppLocalization.format("%d 天", days) }
        let months = days / 30
        return AppLocalization.format("约 %d 个月", months)
    }
}

// MARK: - 工具栏项 chrome 隐藏（macOS 26 起工具栏项带 sharedBackground 玻璃胶囊，
// 自绘的侧栏切换按钮与固定宽 360 trailing 容器会被罩上多余色块；只去底色，不改几何与交互）
@ToolbarContentBuilder
private func toolbarItemNoChrome<Content: View>(
    _ placement: ToolbarItemPlacement,
    @ViewBuilder content: @escaping () -> Content
) -> some ToolbarContent {
    if #available(macOS 26.0, *) {
        ToolbarItem(placement: placement, content: content)
            .sharedBackgroundVisibility(.hidden)
    } else {
        ToolbarItem(placement: placement, content: content)
    }
}

/// 侧栏切换按钮图标：chrome 隐藏后补轻量 hover 底色，保证图标清晰、反馈合理。
private struct SidebarToggleIcon: View {
    @State private var hovering = false
    var body: some View {
        Image(systemName: "sidebar.left")
            .frame(width: 28, height: 28)
            .background(
                Color.primary.opacity(hovering ? 0.08 : 0),
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.easeInOut(duration: 0.12), value: hovering)
    }
}

/// 工具栏 prominent 按钮样式：macOS 26 隐藏工具栏 sharedBackground 后，.borderedProminent
/// 的白字依赖那层胶囊底色，会直接隐形；此样式自绘 accent 胶囊底（按下变暗），任何上下文可见。
private struct ToolbarProminentStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 1), in: Capsule())
            .foregroundStyle(.white)
    }
}
