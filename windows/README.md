# 搞研究 Windows 版

面向 Windows 10/11 x64 的独立版本，营销版本与当前 Mac 版同为 **4.14**，Windows 构建号为 **1**。代码只放在 `windows/`，不改 Mac 版的 Swift 源码、签名或资料路径。

界面在本机浏览器中打开。服务只监听 `127.0.0.1`，不对外网提供页面，也不把个人资料上传到 GitHub。

## 选型

使用 **Python 3.12 标准库** 实现业务，界面是随程序打包的本地网页，安装包用 **PyInstaller** 在 `windows-latest` 上打成单个 exe。

这样选，是因为：

- 业务和测试可以在 Linux 上完成，不需要 Windows SDK 或 Xcode。
- GitHub Actions 的 `windows-latest` 能直接跑测试、打包，并上传 exe。
- 没有 Electron 或自带运行时的 .NET 自包含发布那么大的体积，也没有第二套 UI 框架要维护。
- 资料仍是 Mac 版的 schema 32 `library.json`。未知字段会原样保留，方便以后把同一份资料拷回 Mac。

没有做成原生 WinUI。三维研究城、WidgetKit 和 Mac 同伴应用本来就依赖 AppKit / SceneKit，换成浏览器界面可以把已经对齐的业务先跑起来。

## 构建

在 Windows 10/11 x64 上安装 Python 3.12，然后：

```powershell
cd windows
powershell -ExecutionPolicy Bypass -File .\build.ps1
```

脚本会安装开发依赖、运行单元测试，并在 `windows/dist/` 生成：

- `GaoYanJiu.exe`：打开界面的窗口程序
- `GaoYanJiu-cli.exe`：命令行，用于检查资料和生成统计快照

GitHub Actions 工作流 `.github/workflows/windows.yml` 在 `windows-latest` 上执行同一套步骤，再以后台方式启动 `GaoYanJiu.exe`（不打开浏览器），确认本机页面和 `/api/bootstrap` 有响应后退出，并把两个 exe 作为 artifact `GaoYanJiu-Windows-4.14` 上传。这个工作流不会创建 GitHub Release。

只跑测试：

```powershell
cd windows
python -m pip install -r requirements-dev.txt
python -m pytest -q
```

在 Linux 或 macOS 上也可以跑同一套测试。开发时启动界面：

```sh
cd windows
PYTHONPATH=src python3 launch.py --data-dir /tmp/gaoyanjiu-dev --no-browser --port 8765
```

然后用浏览器打开 `http://127.0.0.1:8765/`。

## 运行与安装

不需要安装程序。把 `GaoYanJiu.exe` 放到任意文件夹，双击运行。程序会打开系统浏览器。关闭窗口后，在页面右上角选择“退出”，进程才会结束。

资料目录：

`%APPDATA%\GaoSeries\Research\AcademicAchievementManager\`

第一次打开时需要本人确认“创建我的资料库”。程序不会在资料缺失、损坏或版本更高时用空库覆盖原文件，也不会写自动备份。

命令行：

```powershell
.\GaoYanJiu-cli.exe --version
.\GaoYanJiu-cli.exe --data-dir D:\ResearchData --create-empty
.\GaoYanJiu-cli.exe --inspect
.\GaoYanJiu-cli.exe --widget-snapshot
```

`--inspect` 只打印记录条数和奖励城字段名，不打印标题、正文或路径里的个人内容。环境变量 `GAO_RESEARCH_DATA_DIR` 可以改资料目录，和 Mac 版的测试钩子同名。

门户密码和 EasyScholar Secret Key 在 Windows 上用 DPAPI 加密，放在资料目录的 `secrets\` 下，不写入 `library.json`。

## 数据与网络

| 位置 | 内容 |
| --- | --- |
| `library.json` | schema 32：在投、成果、证书、资料、回收站、门户账号、历史项目和资金、研究城 |
| `Attachments\`、`CertificateAttachments\`、`ManagedDocuments\`、`TrashStorage\` | 附件副本 |
| `settings.json` | 外观、语言、待跟进天数 |
| `secrets\` | EasyScholar 密钥和门户密码 |
| `widget-snapshot.json` | 只含计数的 Windows 统计快照 |

会主动访问的网络接口：

- `https://api.crossref.org/journals`：期刊名建议
- `https://www.easyscholar.cc/open/getPublicationRank`：填写密钥后查询期刊指标
- 内置投稿网站只在浏览器中打开，程序不登录、不抓取稿件状态

Mac 版的投稿页内嵌浏览器、搞文件、搞操作、搞门户和 WidgetKit 都不在这些请求里。

## 功能对齐

| 功能 | 状态 | 说明 |
| --- | --- | --- |
| 在投记录的新建、编辑、状态历史、归档、搜索 | 已对齐 | 状态文本变化会记下上一状态 |
| “状态更新”页 | 部分 | Mac 手动保存会把更新标记清掉。Windows 没有网页抓取，保存时默认也不标记；需要时在新建框里选择“标为状态更新” |
| 成果类型、专利细分、署名、类别条形图 | 已对齐 | 高度规则与 Mac 相同：`max(215, 类别数 × 30 + 35)`。窄窗口改为上下排列 |
| 成果和证书附件 | 已对齐 | 按 SHA-256 管理资料文件；附件移入回收站后才能从原位置删除 |
| 实验数据、总结报告、重要文献 | 部分 | 文件夹、导入、标签、下载和同文件夹去重已有。文本索引覆盖 txt/md/csv/json/xml/yaml、docx/pptx/xlsx，以及未压缩 PDF 里的可见文字 |
| 回收站 | 已对齐 | 保留 30 天，恢复时发现原位置已有同一条会停止。超期清理在打开界面时执行 |
| schema 32 资料往返 | 已对齐 | 额外字段保留。低于或高于 32 的库只读，不改磁盘文件 |
| 损坏、缺失、未来版本不覆盖 | 已对齐 | 发现附件目录等既有痕迹时，不能新建空库 |
| 不制作备份 | 已对齐 | 保存使用临时文件原子替换，替换完成后不保留副本 |
| Crossref 期刊建议、EasyScholar 指标解析 | 已对齐 | 解析规则与 Mac 版相同，包括自定义评价和空值过滤 |
| 21 个内置投稿系统 | 部分 | 可以打开网站并保存账号。没有内嵌浏览器，也不会自动读出稿件状态 |
| 研究城券、保底、金币、相邻购地、抽奖、地形 | 部分 | 房屋券、摆件券、79 抽保底、72 小时金币上限和 100 金币购地与 Mac 相同。界面是二维地块，一地放一件，没有 SceneKit 旋转占地和三维模型 |
| 历史项目、历史资金 | 部分 | 只读显示并在保存其他资料时保留。Mac 4.14 已去掉项目页；资金由搞积蓄管理，Windows 上没有这个应用 |
| `research.importDocuments` 交接包 | 部分 | 校验版本、目标、120 秒有效期、nonce、路径和 SHA-256 后导入所选文件夹。带 `targetRecordID` 的旧参数会拒绝，不会自动选第一个文件夹 |
| 向搞文件、搞操作、搞门户发起编辑、OCR、选择文件 | 未实现 | 这些同伴应用是 macOS bundle，Windows 上没有对应程序 |
| OCR 派生件、外部编辑回导和导入事务日志 | 未实现 | Mac 版依赖上述同伴应用和完整 journal |
| WidgetKit 桌面小组件 | 部分 | 会写 `widget-snapshot.json` 计数。Windows 没有 WidgetKit，也不能注册 Mac 的 App Group |
| 系统通知 | 部分 | 打开时提示超过设定天数仍未终态的在投。没有 Windows 通知横幅 |
| 中英文与浅色/深色 | 部分 | 导航和主要按钮有中英切换，外观可跟随系统。不是 Mac 版的全量文案 |
| `gaoyanjiu://` 深链 | 未实现 | 没有注册 Windows URL 协议 |
| 启动耗时私有日志 | 未实现 | 命令行只提供只读 `--inspect` |
| 三维场景、游戏贴图、macOS 小组件扩展 | 未实现 | 资源和使用它们的代码都是 AppKit / SceneKit / WidgetKit |

单个导入文件的上限是 512 MiB。浏览器上传上限是 256 MiB。交接包沿用 Mac 的 256 项和 2 GiB 总量上限。更大的文件可以用“粘贴本机路径”导入，由程序直接读磁盘。

## 已知问题

- 窗口程序没有自己的原生窗口，关闭浏览器标签不会退出进程，需要点“退出”。
- 二维研究城不检查建筑占地是否跨地块，也不绘制 Mac 版的模型。
- 压缩过的 PDF、扫描件和旧版 `.doc` 不会进入全文索引。
- DPAPI 凭据不能在另一台 Windows 电脑上解开，也不能被 Mac 钥匙串读取。
- 同一份 `library.json` 不要同时被 Mac 版和 Windows 版打开写入。
