# StratagemDesk Public Edition

A macOS and Windows desktop command launcher: hold a shortcut, enter a direction sequence, and run a workflow you have reviewed. Original code, eight geometric icons and eight desktop demonstrations are licensed under MIT. This private candidate also bundles 115 third-party game catalog entries and icons, explicitly excluded from the project MIT license; see [THIRD_PARTY.md](THIRD_PARTY.md).

这是单独维护的公开候选版，目前仓库仍为 private，需由仓库所有者另行决定何时公开。它以新的 Git 历史开始，不继承旧仓库的提交、截图、运行日志、Release 或用户配置。

## 使用

从本仓库 Releases 下载对应平台的 ZIP，完整解压。Windows 运行 `StratagemDeskPublic.exe`，macOS 使用 `StratagemDeskPublic.app`。Windows 包自带 .NET 运行时，macOS 要求 macOS 14+ Apple Silicon。

- macOS 默认按住 **Command + Option + S**；Windows 默认按住 **Ctrl + Alt + S**。
- 按住时输入方向序列，按 Return/Enter 确认；松开收起窗口，已开始的工作流继续执行。
- 初次运行全部条目停用、动作未审核。检查操作、审核、启用并保存后才可通过快捷键执行。
- 包含 115 条游戏战备和对应图标，另保留 Terminal、Home Folder、Calculator、File Browser、Clock、Status、Pause、Workflow 这 8 个桌面示例。游戏条目默认停用、无操作步骤，需自行编辑；原有桌面示例配置继续保留。支持自定义条目、批量启停及默认 / 当前 / 已保存独立档案。
- 可编辑 Shell / PowerShell、可执行文件、启动应用、打开文件/URL、延迟、通知及 macOS 快捷指令，支持逐步测试、失败后继续、取消和超时。
- 热键只使用已保存状态，草稿测试明确预览当前编辑内容。导入会停用条目并撤销动作审核，平台专用操作需要重新配置。

公开版使用独立的配置目录、应用身份、Windows 托盘单例和登录启动项，不读取另一版本的默认配置。macOS 为 `~/Library/Application Support/StratagemDesk-Public/`，Windows 为 `%LOCALAPPDATA%\StratagemDesk-Public\`。同时运行多个版本时，请为它们设置不同的全局快捷键。

## 安全与验证

这是以当前用户权限执行经审核操作的命令启动器，不是脚本沙箱。它不自动提权、不收集遥测、不下载素材。用户自行配置的命令和 URL 仍可以访问网络或修改文件。敏感步骤会隐藏整条工作流日志；配置仍需保存执行参数，不是密钥保险箱。

程序、构建和测试只在 GitHub Actions 运行；不要求在开发用 Mac 执行。两端工作流包含核心、进程、配置与档案测试；Windows 另检查键盘监听生命周期、WPF 控制器和原生 PowerShell，macOS 构建并校验签名。公开检查使用 Gitleaks 扫描完整历史，并分别核对原创素材、游戏来源、MIT 排除声明和作者邮箱。

当前为预览版：Windows 未进行 Authenticode 签名，macOS 为 ad-hoc 签名且未公证；真实键盘、全屏、混合 DPI、锁屏、通知和登录启动仍需交互式桌面验收。

## 许可

**项目 MIT 不覆盖恢复的游戏图标、115 条战备数据和上游原始文件；这些内容保留原权利和上游条款，不被重新许可。** 来源、固定版本、逐项 URL/哈希和版权边界见 [THIRD_PARTY.md](THIRD_PARTY.md) 及 [游戏内容声明](Sources/StratagemCore/Artwork/GAME_CONTENT_NOTICE.md)，声明随两端应用打包。

项目自有代码、`desktop-examples.json` 中 8 个桌面示例和 `desk.*.svg` 原创几何图标使用 [MIT](LICENSE)。Windows 的 SharpVectors.Wpf 使用 BSD-3-Clause，运行时和相关第三方声明保持各自许可，见 [THIRD_PARTY.md](THIRD_PARTY.md) 与 [Windows/THIRD_PARTY.txt](Windows/THIRD_PARTY.txt)。MIT 不覆盖用户导入的图片、脚本或其他外部内容。
