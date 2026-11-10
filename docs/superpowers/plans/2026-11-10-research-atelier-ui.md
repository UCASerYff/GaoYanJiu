# 搞研究 4.13 学术工作室界面 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将搞研究改造为米白、墨绿、陶土色的学术工作室界面，删除资金栏目，并把状态更新、已归档和投稿门户收进在投管理，随后安全安装并发布 4.13。

**Architecture:** 保留 `PaperStore` 和 schema32 作为唯一业务权威，新增轻量 `SubmissionScope` 界面状态并复用原论文筛选实现。新主题与门户组件放在独立文件中，`ContentView` 只组合导航、页签、搜索、论文列表和门户面板；资金历史模型继续服务备份、回收站和迁移，但不再拥有可见页面。

**Tech Stack:** macOS 14+、Swift 5、SwiftUI、AppKit、Combine、现有 zsh/Python 构建与回归脚本、Apple Development 签名、GitHub Releases。

## Global Constraints

- 只修改 `/Users/yufeifan/Desktop/搞app/搞研究`，不修改其他独立应用。
- 版本从 `4.12 / build 13` 升至 `4.13 / build 14`，应用和 Widget 同步。
- 资料格式保持 schema32；原数据目录、App Group、UserDefaults 域和钥匙串服务不变。
- 不删除论文、资金历史、PDF、Word、照片、其他附件、游戏进度、设置或私有备份。
- 所有新 `.app` 在创建前必须位于真实 `.noindex` 容器；正式入口只保留 `/Applications/搞研究.app`。
- 默认不启动 GUI、浏览器、真实投稿门户或 GUI 冒烟；只执行静态、编译、签名和隔离非 GUI 测试。
- 构建使用根目录统一 `build_lease.py`，安装使用项目脚本和团队 `5G96498KGJ` 的已授权 Apple Development 身份。
- GitHub 只发布源码和发行 ZIP/SHA-256，不上传个人数据、私有附件、备份、凭据或 `.superpowers/` 视觉稿。

---

### Task 1: 投稿页签模型与旧导航状态迁移

**Files:**
- Modify: `Sources/Models.swift:747-809`
- Modify: `Sources/PaperStore.swift:160-189`
- Modify: `Tests/ResearchProductIntegration.swift:761-793`
- Modify: `scripts/test_product.sh:53`

**Interfaces:**
- Produces: `SubmissionScope.all / .changed / .hidden`、`SubmissionScope.legacyFilter: LibraryFilter`。
- Produces: `LibraryFilter.sidebarCases: [LibraryFilter]`，不包含资金、状态更新和已归档。
- Produces: `ResearchNavigationMigration.resolve(filter:submissionScope:) -> (filter: LibraryFilter, submissionScope: SubmissionScope)`。
- Consumes: 原 `PaperStore.papers(matching:search:)`，继续保持论文搜索、排序和 hidden/changed 语义。

- [ ] **Step 1: 写入失败的隔离回归**

在 `ResearchProductIntegration` 增加 `workspaceNavigation()`，用三个论文记录覆盖全部、状态更新和归档，并断言资金原始值不再生成导航模块：

```swift
static func workspaceNavigation() throws {
    let (store, _) = try makeStore()
    let now = Date()
    func paper(_ id: String, changed: Bool, hidden: Bool) -> PaperRecord {
        PaperRecord(key: id, sourceID: "manual", site: "fixture", url: "", manuscriptID: id,
                    title: "Workspace " + id, journal: "Fixture Journal", status: "Under Review",
                    checkedAt: now, statusSince: now, statusSinceSource: "fixture",
                    previousStatus: nil, changed: changed, hidden: hidden,
                    history: [], submissionHistory: nil)
    }
    store.papers = [paper("ordinary", changed: false, hidden: false),
                    paper("updated", changed: true, hidden: false),
                    paper("archived", changed: true, hidden: true)]
    try require(store.papers(matching: .all, search: "").map(\.id) == ["ordinary", "updated"], "全部页签包含归档或漏记在投")
    try require(store.papers(matching: .changed, search: "").map(\.id) == ["updated"], "状态更新页签口径改变")
    try require(store.papers(matching: .hidden, search: "").map(\.id) == ["archived"], "归档页签口径改变")
    try require(SubmissionScope.changed.legacyFilter == .changed && SubmissionScope.hidden.legacyFilter == .hidden, "页签未映射原筛选")
    let migrated = ResearchNavigationMigration.resolve(filter: .hidden, submissionScope: .all)
    try require(migrated.filter == .all && migrated.submissionScope == .hidden, "旧归档导航未迁入在投页签")
    try require(!LibraryFilter.sidebarCases.contains(.changed) && !LibraryFilter.sidebarCases.contains(.hidden), "侧栏仍含独立投稿页")
    try require(LibraryFilter(rawValue: "funding") == nil, "资金模块仍可导航")
}
```

在 `main()` 的 switch 增加：

```swift
case "workspace-navigation": try workspaceNavigation()
```

在 `scripts/test_product.sh` 的 `CASES` 开头加入 `workspace-navigation`。

- [ ] **Step 2: 运行测试并确认先失败**

Run: `./scripts/test_product.sh workspace-navigation`

Expected: 编译失败，提示找不到 `SubmissionScope` 或 `ResearchNavigationMigration`；不得运行真实应用或访问真实资料。

- [ ] **Step 3: 实现页签与迁移模型**

在 `Models.swift` 的 `LibraryFilter` 前加入：

```swift
enum SubmissionScope: String, CaseIterable, Identifiable {
    case all, changed, hidden
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: AppLocalization.text("全部")
        case .changed: AppLocalization.text("状态更新")
        case .hidden: AppLocalization.text("已归档")
        }
    }
    var legacyFilter: LibraryFilter {
        switch self {
        case .all: .all
        case .changed: .changed
        case .hidden: .hidden
        }
    }
}

enum ResearchNavigationMigration {
    static func resolve(filter: LibraryFilter, submissionScope: SubmissionScope)
        -> (filter: LibraryFilter, submissionScope: SubmissionScope) {
        switch filter {
        case .changed: (.all, .changed)
        case .hidden: (.all, .hidden)
        default: (filter, submissionScope)
        }
    }
}
```

从 `LibraryFilter` 删除 `case funding` 及 funding 的 title、symbol、`isSubmissionFilter` 分支；保留 changed/hidden 作为内部筛选与迁移兼容值。增加：

```swift
static let sidebarCases: [LibraryFilter] = [
    .all, .existing, .projects, .experimentData,
    .summaryReports, .importantLiterature, .certificates, .rewardCity,
]
```

从 `PaperStore.papers(matching:search:)` 删除 `.funding` 空数组分支，其余筛选逻辑逐字保留。

- [ ] **Step 4: 运行回归确认通过**

Run: `./scripts/test_product.sh workspace-navigation`

Expected: `PASS Product workspace-navigation` 和 `Targeted product integration checks passed. No GUI or smoke test was performed.`

- [ ] **Step 5: 提交导航模型**

```bash
git add Sources/Models.swift Sources/PaperStore.swift Tests/ResearchProductIntegration.swift scripts/test_product.sh
git commit -m "Consolidate submission scopes and remove funding navigation"
```

---

### Task 2: 学术工作室主题与共享组件

**Files:**
- Create: `Sources/WorkspaceTheme.swift`
- Create: `Sources/WorkspaceComponents.swift`
- Modify: `Sources/Views.swift:6-11`
- Modify: `Sources/SharedListComponents.swift:115-158`

**Interfaces:**
- Produces: `AppTheme.accent / teal / clay / canvas / sidebar / card / border`，并保留 `AppTheme.blue` 作为 accent 兼容别名。
- Produces: `AppTheme.titleFont(_ size: CGFloat) -> Font`。
- Produces: `View.workspaceCard(cornerRadius:padding:)`、`WorkspaceSearchField`、`SubmissionScopeTabs`。
- Consumes: Task 1 的 `SubmissionScope`。

- [ ] **Step 1: 建立动态浅色/深色主题**

创建 `WorkspaceTheme.swift`，删除 `Views.swift` 顶部旧 `AppTheme`：

```swift
import AppKit
import SwiftUI

enum AppTheme {
    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255, alpha: 1)
    }
    private static func adaptive(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    static let accent = adaptive(light: rgb(0x244b42), dark: rgb(0xa7e6c8))
    static let blue = accent
    static let teal = adaptive(light: rgb(0x4f7465), dark: rgb(0x83b79d))
    static let clay = adaptive(light: rgb(0xad6347), dark: rgb(0xd99577))
    static let canvas = adaptive(light: rgb(0xf3f0e8), dark: rgb(0x171b19))
    static let sidebar = adaptive(light: rgb(0xe7e6dc), dark: rgb(0x202623))
    static let card = adaptive(light: rgb(0xfffdf8), dark: rgb(0x222824))
    static let border = adaptive(light: rgb(0xdcd8cc), dark: rgb(0x3a413b))
    static func titleFont(_ size: CGFloat = 30) -> Font {
        .custom("Songti SC", size: size, relativeTo: .title)
    }
}
```

- [ ] **Step 2: 建立搜索、卡片和页签组件**

创建 `WorkspaceComponents.swift`：

```swift
import SwiftUI

private struct WorkspaceCardModifier: ViewModifier {
    var cornerRadius: CGFloat
    var padding: CGFloat
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(AppTheme.card, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).stroke(AppTheme.border))
            .shadow(color: .black.opacity(0.035), radius: 7, y: 3)
    }
}

extension View {
    func workspaceCard(cornerRadius: CGFloat = 14, padding: CGFloat = 16) -> some View {
        modifier(WorkspaceCardModifier(cornerRadius: cornerRadius, padding: padding))
    }
}

struct WorkspaceSearchField: View {
    let prompt: String
    @Binding var text: String
    var focus: FocusState<Bool>.Binding
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain).focused(focus)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
                    .accessibilityLabel(AppLocalization.text("清除搜索"))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(AppTheme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(AppTheme.border))
        .frame(minWidth: 250, maxWidth: 360)
    }
}

struct SubmissionScopeTabs: View {
    @Binding var selection: SubmissionScope
    let counts: [SubmissionScope: Int]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(SubmissionScope.allCases) { scope in
                Button { selection = scope } label: {
                    HStack(spacing: 5) {
                        Text(scope.title)
                        Text("\(counts[scope] ?? 0)").monospacedDigit().foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(selection == scope ? AppTheme.accent.opacity(0.13) : .clear,
                                in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == scope ? .isSelected : [])
            }
        }
        .padding(4).background(AppTheme.sidebar, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
    }
}
```

- [ ] **Step 3: 应用共享空状态样式并编译**

把 `ListEmptyStateView` 的图标和主按钮颜色改用 `AppTheme.accent`，背景改用 `AppTheme.card`，描边改用 `AppTheme.border`；保留原按钮动作、文案和 `embedded` 布局参数。

Run: `./scripts/build_framework.sh`

Expected: `Built .../build.noindex/Frameworks/Research.framework`，无 Swift 编译错误。

- [ ] **Step 4: 提交主题组件**

```bash
git add Sources/WorkspaceTheme.swift Sources/WorkspaceComponents.swift Sources/Views.swift Sources/SharedListComponents.swift
git commit -m "Add research atelier theme and workspace components"
```

---

### Task 3: 重组侧栏、在投页签与门户面板

**Files:**
- Create: `Sources/SubmissionPortalPanel.swift`
- Modify: `Sources/Views.swift:66-944`
- Modify: `Sources/Views.swift:1388-1435`
- Delete: `Sources/FundingViews.swift`
- Modify: `Resources/en.lproj/Localizable.strings`

**Interfaces:**
- Consumes: `SubmissionScope`、`ResearchNavigationMigration`、`LibraryFilter.sidebarCases`、`WorkspaceSearchField`、`SubmissionScopeTabs`。
- Produces: `SubmissionPortalPanel(openPortal:addPortal:deletePortal:)`，复用原门户状态与闭包。
- Produces: `ContentView.effectivePaperFilter: LibraryFilter`，把在投页签映射到原查询。

- [ ] **Step 1: 建立独立门户面板**

创建 `SubmissionPortalPanel.swift`，注入 `PaperStore`，通过三个闭包调用 `ContentView` 原有的登录、新增和删除流程：

```swift
import SwiftUI

struct SubmissionPortalPanel: View {
    @EnvironmentObject private var store: PaperStore
    let openPortal: (PortalAccount) -> Void
    let addPortal: () -> Void
    let deletePortal: (PortalAccount) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label(AppLocalization.text("投稿门户"), systemImage: "link")
                    .font(.headline)
                Spacer()
                Button(action: addPortal) { Image(systemName: "plus") }
                    .buttonStyle(.plain).accessibilityLabel(AppLocalization.text("从投稿系统导入"))
            }
            Text(AppLocalization.format("%d 个投稿门户", store.portals.count))
                .font(.caption).foregroundStyle(.secondary)
            if store.portals.isEmpty {
                Text(AppLocalization.text("连接投稿门户，开始整理你的学术成果"))
                    .font(.callout).foregroundStyle(.secondary)
                Button(AppLocalization.text("从投稿系统导入"), action: addPortal)
                    .buttonStyle(.borderedProminent).tint(AppTheme.accent)
            } else {
                ForEach(store.portals) { portal in
                    HStack(spacing: 9) {
                        Button { openPortal(portal) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(portal.publisherName).font(.callout.weight(.medium)).lineLimit(1)
                                Text(portal.lastError == nil ? AppLocalization.text("最近同步正常") : AppLocalization.text("同步有错误"))
                                    .font(.caption2).foregroundStyle(portal.lastError == nil ? .secondary : AppTheme.clay)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(.plain)
                        Button { deletePortal(portal) } label: { Image(systemName: "trash") }
                            .buttonStyle(.plain).foregroundStyle(.secondary)
                            .disabled(store.isRefreshing).accessibilityLabel(AppLocalization.text("删除门户"))
                    }
                    Divider().overlay(AppTheme.border)
                }
                Button(AppLocalization.text(store.isRefreshing ? "刷新中" : "刷新全部")) { store.refreshAll() }
                    .disabled(store.isRefreshing)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .workspaceCard(cornerRadius: 14, padding: 16)
    }
}
```

- [ ] **Step 2: 收拢导航和页签状态**

在 `ContentView` 增加：

```swift
@SceneStorage("gqns.research.submissionScope") private var submissionScope: SubmissionScope = .all
@State private var showingPortalSheet = false

private var effectivePaperFilter: LibraryFilter {
    filter == .all ? submissionScope.legacyFilter : filter
}
```

`displayedPapers` 改用 `effectivePaperFilter`。在现有 `.onAppear` 中首先执行：

```swift
let migrated = ResearchNavigationMigration.resolve(filter: filter, submissionScope: submissionScope)
filter = migrated.filter
submissionScope = migrated.submissionScope
```

侧栏使用分组后的显式数组：`.all/.existing/.projects`、`.experimentData/.summaryReports/.importantLiterature/.certificates`、`.rewardCity`；标题分别为「研究工作台」「资料与资产」「探索」。侧栏宽 248，背景 `AppTheme.sidebar`，选中态 `AppTheme.accent`，计数胶囊使用 `AppTheme.card.opacity(0.65)`。

删除侧栏中的旧 `portalSection`、`searchField` 和 funding 所有分支。新增 `.sheet(isPresented: $showingPortalSheet)`，嵌入同一 `SubmissionPortalPanel` 并设置 `.frame(width: 360, height: 520)`。

- [ ] **Step 3: 组合在投主区域**

在 `DashboardHeader` 上方放置 `WorkspaceSearchField(prompt:searchPrompt,text:$search,focus:$searchFocused)`。在在投页的标题下方放置：

```swift
SubmissionScopeTabs(selection: $submissionScope, counts: [
    .all: store.visiblePapers.count,
    .changed: store.changedCount,
    .hidden: store.papers.filter(\.hidden).count,
])
```

把现有论文 `ScrollView` 提取为 `submissionList`，其中空状态使用 `effectivePaperFilter`，统计趋势仅在 `submissionScope == .all` 时显示。用几何宽度决定门户布局：

```swift
GeometryReader { proxy in
    HStack(alignment: .top, spacing: 16) {
        submissionList.frame(maxWidth: .infinity, maxHeight: .infinity)
        if proxy.size.width >= 980 {
            SubmissionPortalPanel(
                openPortal: { importContext = ImportContext(publisher: publisher(for: $0)) },
                addPortal: { importContext = ImportContext(publisher: nil) },
                deletePortal: { portalToRemove = $0 }
            ).frame(width: 250)
        }
    }
    .padding(.horizontal, 24).padding(.bottom, 24)
}
```

在在投页工具区始终提供「门户」按钮以打开 `showingPortalSheet`，保证窄窗口可访问全部门户功能。论文卡片的拖拽、点击、删除闭包原样保留。

- [ ] **Step 4: 删除资金可见实现并补齐文案**

删除 `Sources/FundingViews.swift`，移除 `displayedFundingRecords`、资金搜索提示、资金工具栏按钮、资金 dashboard 分支、资金统计、资金最近更新和资金菜单分支。保留 `Module.swift` 的 funding 深链转交以及全部资金数据/备份/回收站模型。

在英文 strings 增加：

```text
"研究工作台" = "Research Workspace";
"资料与资产" = "Library & Assets";
"探索" = "Explore";
"全部" = "All";
"门户" = "Portals";
"同步有错误" = "Sync error";
```

- [ ] **Step 5: 验证并提交界面重组**

Run: `./scripts/test_product.sh workspace-navigation && ./scripts/build_framework.sh`

Expected: 页签回归通过且 framework 编译成功；源码中不存在 `FundingDashboard` 或 `.funding` 导航分支。

```bash
git add Sources/Views.swift Sources/SubmissionPortalPanel.swift Sources/FundingViews.swift Resources/en.lproj/Localizable.strings
git commit -m "Merge submission views and portals into atelier workspace"
```

---

### Task 4: 完成全局视觉与窄窗口可访问性

**Files:**
- Modify: `Sources/Views.swift:1152-1550`
- Modify: `Sources/SharedListComponents.swift`
- Modify: `Sources/DocumentLibraryViews.swift`
- Modify: `Sources/ProjectViews.swift`
- Modify: `Sources/CertificateViews.swift`
- Modify: `Sources/ManualAndExistingViews.swift`
- Modify: `Host/AppMain.swift:71-88`

**Interfaces:**
- Consumes: Task 2 的主题和 `workspaceCard`。
- Consumes: Task 3 的窄窗口门户 sheet；本任务不改变业务闭包或数据查询。

- [ ] **Step 1: 统一页头、统计卡、趋势卡和论文卡**

`DashboardHeader` 标题改用 `AppTheme.titleFont(30)`，说明使用 `.secondary`；统计卡使用 `AppTheme.card`、`AppTheme.border`、图标 accent/teal/clay。投稿统计只保留「论文记录、仍在投、已接受、状态更新」四项，不再把门户数量作为统计卡。

`SubmissionAnalyticsCard`、`PaperCard` 和 `EmptyLibraryView` 使用 `AppTheme.card` 与 `AppTheme.border`；状态更新和警示统一 `AppTheme.clay`，普通状态使用 `AppTheme.accent`。保留原 `accessibilityElement(children: .combine)`、上下文菜单和删除动作。

- [ ] **Step 2: 同步其他业务页面**

将 `ProjectViews`、`CertificateViews`、`ManualAndExistingViews`、`DocumentLibraryViews` 的主列表卡片背景统一为 `AppTheme.card`，描边统一为 `AppTheme.border`，主要按钮 tint 统一为 `AppTheme.accent`。不修改编辑器字段、保存校验、附件路径、拖放代理或详情状态机。

宿主窗口工具栏背景由 `windowBackgroundColor` 改为 `AppTheme.canvas`，窗口默认尺寸和最小尺寸不变。

- [ ] **Step 3: 静态检查交互与数据保护**

Run: `git diff --check && ./scripts/build_framework.sh && ./scripts/test_product.sh workspace-navigation`

Expected: 无空白错误，编译和页签回归通过。检查 diff 只含颜色、字体、布局与组件组合，不包含持久字段、附件路径、保存函数或门户凭据改动。

- [ ] **Step 4: 提交视觉完成项**

```bash
git add Sources/Views.swift Sources/SharedListComponents.swift Sources/DocumentLibraryViews.swift Sources/ProjectViews.swift Sources/CertificateViews.swift Sources/ManualAndExistingViews.swift Host/AppMain.swift
git commit -m "Apply atelier styling across research workflows"
```

---

### Task 5: 版本、文档、完整构建与隔离验证

**Files:**
- Modify: `Info.plist`
- Modify: `Widgets/Info.plist`
- Modify: `README.md`
- Modify: `docs/WIDGET_VALIDATION.md`（仅记录本轮实际验证范围）

**Interfaces:**
- Consumes: Tasks 1-4 的完整源码。
- Produces: `dist/GaoYanJiu-4.13.zip` 和 `dist/GaoYanJiu-4.13.zip.sha256`。

- [ ] **Step 1: 更新版本和发行说明**

将应用与 Widget 的 `CFBundleShortVersionString` 改为 `4.13`、`CFBundleVersion` 改为 `14`。README 标题、下载文件名、校验命令和 snapshot 示例改为 4.13；功能说明删除「研究保留原资金只读历史」的可见栏目表述，新增：

```markdown
## V4.13 更新

- 全新「学术工作室」界面：米白画布、墨绿主色与陶土色提醒，浅色/深色模式分别适配。
- 状态更新、已归档改为在投管理内部页签；投稿门户并入在投页，窄窗口使用独立门户面板。
- 删除资金导航和资金页面；历史字段仅继续服务迁移、备份与回收站安全，旧资金深链仍转交搞积蓄。
- 资料格式保持 schema32，原数据、附件、钥匙串和小组件共享路径不变。
```

- [ ] **Step 2: 获取统一构建锁**

```bash
python3 "/Users/yufeifan/Desktop/搞app/合并迁移-2026-11-02/build_lease.py" status
python3 "/Users/yufeifan/Desktop/搞app/合并迁移-2026-11-02/build_lease.py" acquire --owner research-4.13 --purpose "Research 4.13 atelier build" --title "搞研究4.13"
```

Expected: `acquired: true`；将返回的 32 位 token 保存为当前 shell 的 `BUILD_TOKEN` 环境变量。若已有其他有效锁，等待其释放，不抢锁。

- [ ] **Step 3: 运行定向测试和完整构建**

```bash
./scripts/test_product.sh workspace-navigation
./scripts/test_consolidation.sh
./scripts/test_backup.sh
./scripts/test_library_load.sh
./scripts/test_trash_persistence.sh
./scripts/test_widgets.sh
./scripts/test_widget_store.sh
python3 Tests/InstallSafetyRegression.py
./scripts/build.sh
./scripts/package.sh
```

Expected: 所有命令退出码 0；应用与 Widget 均为 4.13/build 14，签名验证通过，生成 ZIP 和 SHA-256。记录实际结果，未运行的旧测试不得声称通过。

- [ ] **Step 4: 核验发行包后提交并释放构建锁**

```bash
plutil -lint Info.plist Widgets/Info.plist
git diff --check
shasum -a 256 -c dist/GaoYanJiu-4.13.zip.sha256
codesign --verify --deep --strict build.noindex/搞研究.app
git add Info.plist Widgets/Info.plist README.md docs/WIDGET_VALIDATION.md
git commit -m "Release research atelier V4.13"
python3 "/Users/yufeifan/Desktop/搞app/合并迁移-2026-11-02/build_lease.py" release --owner research-4.13 --token "$BUILD_TOKEN"
```

Expected: plist、差异、校验和及签名全部通过；构建锁返回 `released: true`。

---

### Task 6: 私有备份、安装、唯一入口清理与 GitHub 发布

**Files:**
- Modify only through existing tools: `~/Library/Application Support/GaoSeries/UpgradeBackups/Research/` 中新增私有快照；不得复制到仓库。
- Replace: `/Applications/搞研究.app`。
- Remove after verification: `rollback.noindex/` 中本轮旧 App、`build.noindex/`、旧 `dist/GaoYanJiu-*.zip*`；保留 4.13 发行包和用户资料。

**Interfaces:**
- Consumes: Task 5 的发行 ZIP 和校验文件。
- Produces: `/Applications/搞研究.app` 4.13/build 14、私有升级核验结果、GitHub `v4.13` Release。

- [ ] **Step 1: 退出应用并创建私有快照**

```bash
if pgrep -f '^/Applications/搞研究.app/Contents/MacOS/AcademicAchievementManager' >/dev/null; then
  osascript -e 'tell application "搞研究" to quit'
fi
python3 scripts/upgrade_data.py snapshot --version 4.13
```

Expected: 返回私有 backup 目录和逐文件核验成功。将返回目录保存为当前 shell 的 `BACKUP_DIR` 环境变量；若备份失败或任何数据不可读，停止安装，不能把缺失数据当空库。

- [ ] **Step 2: 从已核验发行包安装**

```bash
./scripts/install.sh
```

Expected: 安装 4.13/build 14，团队签名、App Group、扩展入口和连续小组件登记检查通过；旧 App 位于 `rollback.noindex`，尚未删除。

- [ ] **Step 3: 核验真实数据、附件和小组件快照**

```bash
python3 scripts/upgrade_data.py verify-live "$BACKUP_DIR"
"/Applications/搞研究.app/Contents/MacOS/AcademicAchievementManager" --widget-diagnostics
```

Expected: 业务记录、资金历史、研究城、设置、数据库、全部附件无未解释差异；Widget 诊断读取有效快照。若出现差异，停止清理并查明，必要时使用安装脚本恢复副本回滚。该维护命令不得启动 GUI 或新建资料库。

- [ ] **Step 4: 精确清理旧程序与中间构建**

确认核验通过后，删除本轮 `rollback.noindex` 旧 App、`build.noindex`、`.release.noindex`、`.install-staging.noindex` 和 dist 中除 4.13 外的 `GaoYanJiu-*.zip`/`.sha256`。不得删除 `~/Library/Application Support/GaoSeries/Research/`、App Group、UserDefaults、钥匙串或私有升级备份。

使用 `mdfind "kMDItemCFBundleIdentifier == 'com.academic-achievement.manager'"`、实际文件路径检查和 `lsregister -dump`/`registered_apps.py` 复核。Expected: 有效 App 与登记只指向 `/Applications/搞研究.app`；查询失败或索引未收敛时标记唯一性未完成，不宣称清理完成。

- [ ] **Step 5: 发布源码和 4.13 Release**

```bash
git status --short
git push origin main
git tag -a v4.13 -m "搞研究 V4.13"
git push origin v4.13
gh release create v4.13 dist/GaoYanJiu-4.13.zip dist/GaoYanJiu-4.13.zip.sha256 \
  --repo UCASerYff/GaoYanJiu --title "搞研究 V4.13" \
  --notes "学术工作室全新界面；状态更新、已归档和投稿门户并入在投管理；移除资金栏目。资料格式与原数据路径不变。"
gh release view v4.13 --repo UCASerYff/GaoYanJiu --json url,assets,tagName
```

Expected: main 和 v4.13 推送成功，Release 只含 4.13 ZIP 与 SHA-256；仓库无个人数据、附件、备份、凭据或视觉稿。最终回复明确列出编译/测试/数据/唯一入口结果，以及未执行真实 GUI 视觉与门户操作的边界。
