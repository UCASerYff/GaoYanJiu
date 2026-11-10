# 搞研究 4.14 项目移除与类别图修复 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 删除项目管理全部可见功能和项目提醒，保留项目历史数据，并修复成果类别分布图的拥挤、截断与窄窗口布局。

**Architecture:** 旧 `.projects` 仅作为迁移兼容值存在，真实侧栏目录不再返回它，宿主删除全部项目视图和编辑状态。成果类别统计与布局计算移入独立纯 Swift 文件，SwiftUI 只负责渲染同一数据和布局结果。

**Tech Stack:** macOS 14+、Swift 5、SwiftUI、Charts、UserNotifications、现有 zsh/Python 隔离回归、Apple Development 签名、GitHub Releases。

## Global Constraints

- 只修改 `/Users/yufeifan/Desktop/搞app/搞研究`；版本为 4.14 / build 15，应用与 Widget 同步，schema32 不变。
- 保留 `ResearchProject`、`PersistedLibrary.projects`、备份、回收站、附件、研究城、设置、钥匙串和私有快照，不删除真实项目历史。
- 删除项目列表、详情、新建、编辑和项目步骤提醒；旧 `.projects` 场景进入在投管理“全部”。
- 类别统计口径不变：普通类型加专利子类和未细分专利，合计必须等于当前成果数。
- 默认不启动 GUI、浏览器、真实门户或 GUI 冒烟；所有新 `.app` 必须先位于 `.noindex` 容器。
- 构建优先使用根目录统一 `build_lease.py`；若协调目录已由总协调移除，先确认无其他构建任务并记录锁服务不可用，不重建或修改其他应用。
- 推送源码和 4.14 ZIP/SHA-256，不上传用户资料、私有备份或 `.superpowers/`。

---

### Task 1: 项目导航迁移与可见功能删除

**Files:**
- Modify: `Sources/Models.swift:766-810`
- Modify: `Sources/Views.swift`
- Modify: `Sources/NotificationManager.swift:31-40,75-106`
- Delete: `Sources/ProjectViews.swift`
- Test: `Tests/ResearchProductIntegration.swift:761-795`

**Interfaces:**
- `ResearchNavigationMigration.resolve(filter:submissionScope:)` 对 `.projects` 返回 `(.all, .all)`。
- `ResearchSidebarSection.workspace.filters == [.all, .existing]`。
- `LibraryFilter.projects` 保留 raw value 兼容，但不再产生任何可见分支。

- [ ] **Step 1: 写失败回归**

在 `workspaceNavigation()` 增加：

```swift
let migratedProjects = ResearchNavigationMigration.resolve(filter: .projects, submissionScope: .hidden)
try require(migratedProjects.filter == .all && migratedProjects.submissionScope == .all,
            "旧项目导航未回到在投全部")
try require(sidebar == [.all, .existing, .experimentData, .summaryReports,
                        .importantLiterature, .certificates, .rewardCity],
            "真实侧栏仍含项目管理")
```

- [ ] **Step 2: 观察 RED**

Run: `./scripts/test_product.sh workspace-navigation`
Expected: 旧项目迁移或侧栏断言失败。

- [ ] **Step 3: 删除项目可见实现**

在 `ResearchNavigationMigration.resolve` 增加 `case .projects: (.all, .all)`，从 workspace filters 删除 `.projects`。在 `ContentView.onAppear` 迁移前记录 `filter == .projects`，迁移后若是旧项目页则清空 `search`。

从 `Views.swift` 删除 `ProjectEditorContext`、`selectedProject`、`projectEditorContext`、`displayedProjects`、项目搜索提示、项目工具栏按钮、项目 sheet、项目 dashboard、项目计数、项目 sheet 状态、项目新建菜单、项目统计卡和最近更新分支。所有 switch 的 `.projects` 与 `.all/.changed/.hidden` 合并为安全的在投默认行为，但真实目录已不会再产生该值。

从 `NotificationManager.configure` 删除 `projectRequests` 调用，并删除整个 `projectRequests` 私有函数；投稿提醒和 `removeAllPendingNotificationRequests` 的既有刷新方式保持不变。删除 `Sources/ProjectViews.swift`，保留模型、仓库和回收站实现。

- [ ] **Step 4: 观察 GREEN 并静态核对**

Run: `./scripts/test_product.sh workspace-navigation && ./scripts/build_framework.sh`
Expected: 导航回归通过、框架编译成功。`Grep` 可见 Swift 文件中不再存在 `ProjectDashboard`、`ProjectDetailView`、`ProjectEditor` 或 `projectRequests`；`ResearchProject` 和 `PersistedLibrary.projects` 仍存在。

- [ ] **Step 5: 提交**

```bash
git add Sources/Models.swift Sources/Views.swift Sources/NotificationManager.swift Sources/ProjectViews.swift Tests/ResearchProductIntegration.swift
git commit -m "Remove project workspace while preserving project history"
```

---

### Task 2: 可测试的类别统计与自适应图表布局

**Files:**
- Create: `Sources/ExistingWorkAnalytics.swift`
- Modify: `Sources/ManualAndExistingViews.swift:222-359`
- Modify: `Tests/ResearchProductIntegration.swift`
- Modify: `scripts/test_product.sh`

**Interfaces:**
- `ExistingWorkCategoryDatum: Identifiable, Equatable`，字段 `id: String`、`label: String`、`count: Int`。
- `ExistingWorkAnalytics.categories(for: [ExistingWork]) -> [ExistingWorkCategoryDatum]`。
- `ExistingWorkAnalyticsLayout.chartHeight(categoryCount: Int) -> CGFloat`，最小 215，每个类别行 30，另加 35 点轴和留白。
- `ExistingWorkAnalyticsLayout.stackCards(width: CGFloat) -> Bool`，`width < 860` 时为 true。

- [ ] **Step 1: 写失败回归**

新增 `existingWorkAnalytics()`，用固定日期和空附件构造成果：

```swift
func work(_ id: String, _ type: ExistingWorkType, _ patent: PatentType? = nil) -> ExistingWork {
    ExistingWork(id: id, title: id, type: type, venue: "", authors: "", completedAt: Date(timeIntervalSince1970: 0),
                 identifier: "", url: "", notes: "", attachments: [], createdAt: Date(timeIntervalSince1970: 0),
                 updatedAt: Date(timeIntervalSince1970: 0), patentType: patent, journalISSN: nil,
                 journalMetrics: nil, authorPosition: nil)
}
let works = [work("journal", .journalArticle), work("invention", .patent, .invention),
             work("utility", .patent, .utilityModel), work("design", .patent, .design),
             work("other-patent", .patent), work("dataset", .dataset)]
let data = ExistingWorkAnalytics.categories(for: works)
try require(data.map(\.count).reduce(0, +) == works.count, "类别合计遗漏成果")
try require(data.map(\.id) == ["journalArticle", "patent-invention", "patent-utilityModel",
                               "patent-design", "patent-unspecified", "dataset"], "类别顺序或专利拆分改变")
try require(Set(data.map(\.id)).count == data.count && data.allSatisfy { $0.count > 0 }, "类别 ID 重复或包含空类别")
try require(ExistingWorkAnalyticsLayout.chartHeight(categoryCount: 0) == 215, "空图最小高度改变")
try require(ExistingWorkAnalyticsLayout.chartHeight(categoryCount: 12) == 395, "多类别高度未增长")
try require(ExistingWorkAnalyticsLayout.stackCards(width: 800) &&
            !ExistingWorkAnalyticsLayout.stackCards(width: 1000), "宽窄布局阈值错误")
```

在 main switch 和默认 CASES 加入 `existing-work-analytics`。

- [ ] **Step 2: 观察 RED**

Run: `./scripts/test_product.sh existing-work-analytics`
Expected: 找不到新统计/布局接口而编译失败。

- [ ] **Step 3: 实现纯数据与布局接口**

新建 `ExistingWorkAnalytics.swift`，导入 Foundation/CoreGraphics；将原 `typeData` 算法逐字迁入 `ExistingWorkAnalytics.categories(for:)`，只把返回类型改为新公共内部 datum。布局实现：

```swift
enum ExistingWorkAnalyticsLayout {
    static func chartHeight(categoryCount: Int) -> CGFloat {
        max(215, CGFloat(max(0, categoryCount)) * 30 + 35)
    }
    static func stackCards(width: CGFloat) -> Bool { width < 860 }
}
```

- [ ] **Step 4: 应用自适应 SwiftUI 布局**

`ExistingWorksAnalytics` 只删除旧 `typeData`，保留私有 `AnalyticsDatum` 给署名和年度图，避免无关改动。类别图改用 `ExistingWorkAnalytics.categories(for: works)`。

用 `GeometryReader` 读取两张上部卡片的真实宽度：`stackCards(width:)` 为 true 时使用 `VStack(alignment:.leading,spacing:14)`，否则使用原 `HStack(alignment:.top,spacing:14)`；把两张卡片提取为私有 `categoryCard` 和 `authorCard`，避免复制图表。GeometryReader 的最小高度使用上下布局所需高度，防止父 ScrollView 中内容裁切。

类别 `Chart` 的高度改为 `ExistingWorkAnalyticsLayout.chartHeight(categoryCount: typeData.count)`；增加：

```swift
.chartYAxis {
    AxisMarks(position: .leading) { AxisValueLabel().font(.caption) }
}
.chartPlotStyle { plot in plot.padding(.trailing, 28) }
```

保留原统计顺序、柱条、数量文本和无障碍 descriptor。

- [ ] **Step 5: 观察 GREEN 并提交**

Run: `./scripts/test_product.sh existing-work-analytics workspace-navigation && ./scripts/build_framework.sh`
Expected: 两个定向回归通过、框架编译成功。

```bash
git add Sources/ExistingWorkAnalytics.swift Sources/ManualAndExistingViews.swift Tests/ResearchProductIntegration.swift scripts/test_product.sh
git commit -m "Repair adaptive existing work category chart"
```

---

### Task 3: 4.14 完整回归、构建与发布

**Files:**
- Modify: `Info.plist`
- Modify: `Widgets/Info.plist`
- Modify: `README.md`
- Modify: `docs/WIDGET_VALIDATION.md`

- [ ] **Step 1: 更新版本与说明**

应用和 Widget 改为 4.14 / 15。README 下载、校验、snapshot 示例改为 4.14，新增 V4.14：项目可见功能与项目提醒删除、历史项目保留、类别图动态高度和窄窗口自适应。验证文档只写实际执行结果，不写 GUI 或桌面 Widget 已通过。

- [ ] **Step 2: 完整隔离验证和签名打包**

在持有可用根构建锁时依次运行：

```bash
./scripts/test_product.sh workspace-navigation portal-presentation existing-work-analytics
./scripts/test_consolidation.sh
./scripts/test_backup.sh
./scripts/test_library_load.sh
./scripts/test_trash_persistence.sh
./scripts/test_widgets.sh
./scripts/test_widget_store.sh
python3 Tests/InstallSafetyRegression.py
./scripts/build.sh
./scripts/package.sh
plutil -lint Info.plist Widgets/Info.plist
(cd dist && shasum -a 256 -c GaoYanJiu-4.14.zip.sha256)
codesign --verify --deep --strict build.noindex/搞研究.app
```

Expected: 全部退出码 0，app/Widget 均为 4.14/15；失败时停止，不安装。

- [ ] **Step 3: 提交并合并**

```bash
git add Info.plist Widgets/Info.plist README.md docs/WIDGET_VALIDATION.md
git commit -m "Release research workspace V4.14"
git diff --check
# 全分支审查无 Critical/Important 后：
git checkout main
git merge --ff-only workspace-cleanup
```

合并前后树一致时，已运行的同一提交测试证据继续有效；删除功能分支。

- [ ] **Step 4: 私有备份、安装、核验和精确清理**

退出旧应用后运行 `python3 scripts/upgrade_data.py snapshot --version 4.14`，保存返回目录；运行 `./scripts/install.sh`、`verify-live <返回目录>` 和正式二进制的 `--widget-diagnostics`。所有差异必须为 0，项目数保持升级前的 1。

核验后注销并删除本应用旧构建/回滚副本，删除 `build.noindex`、`rollback.noindex`、`.release.noindex`、`.install-staging.noindex` 和 4.13 本地旧包，只保留 4.14 ZIP/SHA、用户数据与私有备份。再次 `verify-live`。Spotlight、LaunchServices 各只返回 `/Applications/搞研究.app`，PlugInKit 只返回正式 4.14 扩展。

- [ ] **Step 5: GitHub 发布**

推送 main 和注释标签 v4.14，创建标题“搞研究 V4.14”的 Release，只上传 `GaoYanJiu-4.14.zip` 与 `.sha256`，核验 Release 资产摘要、远端提交和本地 HEAD 一致。最终明确未执行 GUI 视觉、真实门户和桌面 Widget 显示验收。
