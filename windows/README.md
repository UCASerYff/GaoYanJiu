# 搞研究 Windows V4.14

适用于 Windows 10 和 11 x64。Windows 构建号为 1，命令行报告 4.14+1。安装包由 Windows Installer 管理，包含界面和命令行程序。

## 安装与资料

1. 下载发行附件 `GaoYanJiu-Windows-4.14-x64.msi` 及同名 `.sha256` 文件。
2. 在 PowerShell 中计算 SHA-256，与校验文件中的值比较。安装包没有 Authenticode 签名。
3. 退出旧版搞研究，在当前 Windows 用户下双击 MSI，完成后从开始菜单打开「搞研究」。安装目录是 `%LOCALAPPDATA%\GaoYanJiu\`。

```powershell
Get-FileHash -Algorithm SHA256 .\GaoYanJiu-Windows-4.14-x64.msi
Get-Content .\GaoYanJiu-Windows-4.14-x64.msi.sha256
```

旧版 Windows 资料继续使用 `%APPDATA%\GaoSeries\Research\AcademicAchievementManager\`。首次使用时需确认创建资料库。若资料确实存在但缺失、损坏或版本不受支持，界面会报告原因并保护原文件。卸载 MSI 保留资料。旧便携版的程序文件可以在验证新版本后自行移除。

`library.json` 沿用 schema 32，保留扩展字段、历史项目、历史资金、回收站、附件与研究城状态。V4.14 工作区已移除项目管理和资金栏目。Windows 凭据由本机 DPAPI 加密，保存在资料目录的 `secrets\`。应用通过本机回环访问界面及资料，常规入口使用 Edge 应用窗口，Edge 不可用时用系统浏览器打开。

## 工作流

| 页面 | 可用操作 |
| --- | --- |
| 在投管理 | 手动新增、编辑、上下文搜索、拖动排序、查看状态历史、标记已读、归档、恢复追踪及回收站。宽窗口右侧显示门户，窄窗口通过工具栏打开 |
| 投稿门户 | 选择内置或自定义投稿系统、保存门户、在浏览器登录、提取当前稿件、逐项审核导入、更新状态和检查时间。多门户可按顺序刷新 |
| 成果管理 | 成果类型、专利子类、署名、日期、编号、链接、PDF/图片附件。提供成果类别、署名和年度图表，两列图表随工作区宽度排列 |
| 刊物指标 | 成果编辑器通过 Crossref 推荐刊名和 ISSN。输入 EasyScholar 密钥后可查询并随成果保存指标 |
| 实验数据、总结报告、重要文献 | 文件夹、标签、时间和标签排序、拖放与批量上传、去重、文件名及全文搜索、PDF/图片和索引文本预览、下载、编辑和回收站 |
| 证书 | 名称、日期、标签、附件、可排序记录表、年度及标签图表 |
| 研究城 | 三维视角、平移、旋转、缩放，房屋摆件和地形的放置、移动及收回，相邻扩建、祈愿、库存、金币、票券和历史 |
| 桌面小组件 | 从开始菜单打开「搞研究 - 在投状态持续时间」或「搞研究 - 成果与署名分布」。两者使用同一资料库的本地统计快照，点击可定位到主界面 |

全文索引支持常见文本、DOCX/PPTX/XLSX，以及含文字层的 PDF（最大 128 MiB，每份最多索引前 300 页）。扫描件可以送搞操作识别。浏览器单次上传限制为 256 MiB，需要导入更大的单个资料文件时可在文件夹的资料交接菜单中指定本机路径。

### 跨应用交接

- 在研究资料条目的操作菜单中选择「送搞操作识别文字（OCR）」。在搞操作审核、执行识别并导出 `OCR-<UUID>.gaoaction`。回到搞研究的「资料交接与回执」打开结果，在有效期内接收后审核并应用。原件保留，OCR 派生件按来源及页码建立索引。源 PDF 与交接摘要一致时，支持定位原页。
- 「从搞文件选择资料」使用 GaoAction V1 文件选择。编辑流程会给搞文件发送副本，用户可把编辑结果回导为同一资料的新版本或关联附件。也可审核从搞文件直接收到的资料并导出回执。
- 已安装的同伴应用可通过能力查询及交接启动参数接入。若同伴不可用或其版本不提供相应启动入口，应用会保留端到端交接包供手动打开。Windows 版同时识别旧 Windows 搞文件的历史收件方标识；新交接使用 `com.academic-achievement.manager`。

## 验收边界

- 在 Windows 11 x64 用隔离数据验收。七页的浅色、深色、宽窄布局及 175% 模拟缩放通过 Chromium 无头回归。Windows 10 和 macOS V4.14 的实机并排截图尚未验收。
- 投稿门户使用浏览器捕获并经人工审核。需手动登录和刷新，待跟进提醒在应用内显示。真实出版商登录和真实 EasyScholar 密钥尚未验收。
- 研究城复用原始天空、草地、岩石贴图和原目录标识。建筑与地形用 Canvas 三维几何重建，SceneKit 材质、阴影和部分模型细节有差异。
- 桌面小组件以独立 Windows 小窗运行，保留统计和链接。Windows 11 Widgets 面板无系统注册。
- 搞操作 V1.16 x64 安装版已用合成 PNG 和双页 PDF 测试原生 OCR、6 份结果、来源摘要和重复去重。搞文件已用 Windows 源码测试选择、编辑回导和回执。两个同伴应用的前台交互尚未验收。

## 构建与复现

在 Windows x64 上使用干净的 CPython 3.12 环境运行以下命令。正常构建会安装开发依赖、运行回归并输出 MSI 及 SHA-256 到 `windows/dist/`。GitHub Actions 上传 Windows 构建产物。

```powershell
pwsh -File .\windows\build.ps1 -Python C:\path\to\venv\Scripts\python.exe
python .\windows\tests\smoke_install.py .\windows\dist\GaoYanJiu-Windows-4.14-x64.msi
node .\windows\tests\smoke_browser.mjs "C:\Program Files\Google\Chrome\Application\chrome.exe" C:\path\to\venv\Scripts\python.exe
```

`GaoYanJiu-cli.exe` 支持 `--version`、`--inspect`、`--create-empty`、`--widget-snapshot`、`--widget submissions|works` 和 `--capabilities`。可用 `--data-dir` 或 `GAO_RESEARCH_DATA_DIR` 指定隔离资料。`--gaoaction PATH` 打开待审交接。`gaoyanjiu://submissions` 和 `gaoyanjiu://works` 定位页面，`gaoyanjiu://widget` 打开桌面组件。
