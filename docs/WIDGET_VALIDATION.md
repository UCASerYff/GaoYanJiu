# 小组件证据与人工验收

默认不自动运行冒烟测试，不为测试启动应用、浏览器、模拟器或窗口。静态、编译和隔离定向检查不能替代以下实际系统验收。

## V4.14 项目移除、类别图与无备份隔离验证（2026-11-10）

- `./scripts/test_product.sh workspace-navigation portal-presentation existing-work-analytics` 通过。覆盖项目旧导航回到在投“全部”、真实侧栏不再包含项目，以及普通成果、三类专利、未细分专利的统计守恒、顺序、唯一 ID、动态图表高度和宽窄布局阈值；全部使用隔离合成数据。静态检查同时拒绝每日备份、手动备份、迁移备份及持久升级快照实现残留。
- `./scripts/test_consolidation.sh`、`./scripts/test_library_load.sh`、`./scripts/test_trash_persistence.sh` 均通过。资料库加载安全为 15 组隔离检查，其中迁移用例明确确认不会生成备份目录或额外兄弟产物；真实项目字段和回收站兼容实现保留，没有用空资料覆盖真实记录。
- `./scripts/test_widgets.sh`、`./scripts/test_widget_store.sh` 分别通过 73 项和 77 项定向断言；启动诊断隔离回归通过；`python3 Tests/InstallSafetyRegression.py` 通过 12/12，确认安装成功只保留新版、失败清理半成品、任何情况均不创建旧程序回滚副本。未启动应用、Widget 宿主、浏览器或 GUI，安装安全测试仅使用隔离伪造系统。
- 原根协调目录及统一 `build_lease.py` 已不存在，本轮未重建锁服务；每次构建前均检查无其他 `swiftc` 或本应用构建进程。`zsh scripts/test_startup_diagnostics.sh`、`./scripts/build.sh` 与 `./scripts/package.sh` 成功，应用和 Widget 均为 4.14 / build 15，plist 与 `codesign --verify --deep --strict build.noindex/搞研究.app` 检查通过。
- `dist/GaoYanJiu-4.14.zip` 及同名 `.sha256` 已生成，在 `dist` 内校验返回 `GaoYanJiu-4.14.zip: OK`；ZIP SHA-256 为 `413ec04fbe2b3d90070a5ae6229369860ea24930b84c00b8eaf826cb4d49b313`。
- 此处仅记录构建和隔离验证。真实安装、资料核验、GUI 类别图视觉、真实投稿门户及桌面 Widget 显示验收不以这些结果代替，须按实际完成情况另行记录。

## V4.13 最终审查修复隔离验证（2026-11-10）

- `./scripts/test_product.sh workspace-navigation portal-presentation` 通过。覆盖真实侧栏目录、changed/hidden 旧状态迁移、三个投稿页签计数、从每个 scope 进入投稿深链后回到“全部”并清理搜索，以及门户 error/stale/healthy、host/path、检查时间和辅助状态；全部使用隔离合成数据。
- 完整 Task 5 清单已在根构建租约下重跑并通过：工作区导航、整合、备份、15 组资料库加载、回收站持久化、73 项 Widget 断言、77 项 Widget Store 断言，以及安装安全回归 12/12。没有启动应用、Widget 宿主或 GUI，安装安全测试仅使用隔离伪造系统。
- 深色与浅色侧栏选中态完成源码接线和静态对比度计算：浅色行／计数胶囊为 9.72:1／6.90:1，深色为 11.42:1／9.13:1。门户帮助和辅助状态也完成源码级核对；这些不是视觉验收。
- `./scripts/build.sh` 与 `./scripts/package.sh` 在根构建租约 `research-4.13-final-fix` 下成功执行，租约已释放。源码及构建产物中的应用与 Widget 均为 4.13 / build 14，四份 plist 均通过 `plutil -lint`；`codesign --verify --deep --strict --verbose=2 build.noindex/搞研究.app` 通过。
- `dist/GaoYanJiu-4.13.zip` 及同名 `.sha256` 已重新生成。在 `dist` 内运行 `shasum -a 256 -c GaoYanJiu-4.13.zip.sha256` 返回 `GaoYanJiu-4.13.zip: OK`；ZIP SHA-256 为 `ac348d34f9a9500dad662ce95f90685c2142a2a8aa0d7f71e87464312ca7d514`。
- 未执行真实安装、真实资料备份或核验、清理、应用或浏览器启动、真实投稿门户操作、GUI 冒烟及桌面小组件显示验收。静态、编译、签名、发行包与隔离定向检查不能替代这些实际系统验收。

## 如何理解时间

- 资料库写入：真实 `library.json` 文件写入时间，可能是索引、附件或研究城保存，不等于最后一次成果编辑。
- 统计内容更新：最近可核验统计内容对应的时间。`legacy-publication` 表示继承旧快照，历史编辑时间无法反推；业务值不变时保持旧时间。
- 快照发布：当前有效统计快照生成时间，包含来源文件及内容摘要。
- 组件成功读取：扩展真正读取有效快照的记录。预览与 Timeline 请求分开；失败保留最近成功证据。读取成功不表示桌面已经渲染。

设置的模块页显示这些状态。`--widget-diagnostics` 维护命令只读取既有状态，不伪造组件读取。`--refresh-widget-snapshot` 仅在既有资料库有效且来源未改变时发布，不创建资料库、迁移主资料或打开窗口。两条命令均位于应用内 `Contents/MacOS/AcademicAchievementManager` 二进制。

## 本人操作的验收清单

1. 核对本机主程序与扩展版本、构建号、团队、App Group 和登记路径。只处理本应用已失效的记录，禁止全局清空系统登记或修改其他应用。
2. 在原资料上比对业务库、快照和桌面数值，保留前后证据。本人完成一条成果的新增、修改、删除后，分别核对分类、署名和总量，保留或恢复真实业务状态；不得将演示夹具当作实际验收。
3. `ResearchSubmissionDuration` 支持 medium、large；`ResearchAchievementStatistics` 支持 large。逐一确认各尺寸、多个实例、首次添加和重新添加；分别点击后应定位投稿或成果页。
4. 分别确认主程序未打开、窗口关闭、程序退出、重启、睡眠唤醒、午夜、跨月及时区变化。在投持续天数按所在时区的日历日计算，终态显示保持其语义。Calendar 单元断言只验证计算，不能证明实际设备经历了这些场景。
5. 记录系统是否请求 Timeline、成功读取哪一版快照、发布至读取的实际延迟与桌面最终显示。没有请求或未看到显示时，明确记录缺少哪一层证据；不能承诺固定秒数刷新，也不能靠高频 reload 或只更新日期掩盖旧业务值。

故障时维持原件与最后有效快照。损坏、缺失、无法读取、未来 schema 的异常路径使用隔离资料验证，不能破坏用户真实资料来测试。

真实资料、截图、逐文件核验及系统日志只保留在私有验证记录中，不上传 GitHub。
