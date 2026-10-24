# StratagemDesk

受《HELLDIVERS 2》战备系统启发的 macOS / Windows 桌面命令启动器。按住快捷键、输入方向序列，即可执行自己配置的操作或工作流。

## 安装与使用

从 Releases 下载对应平台的 ZIP 并完整解压：

- **macOS 14+ / Apple Silicon**：打开 `StratagemDeskPublic.app`。
- **Windows x64**：运行 `StratagemDeskPublic.exe`，保留同目录下的 DLL、素材和许可文件。安装包已包含 .NET 运行时。

macOS 默认快捷键为 **Command + Option + S**，Windows 为 **Ctrl + Alt + S**。按住快捷键呼出面板并输入方向序列；需要确认时按 Return / Enter。松开快捷键收起面板，已经开始的工作流会继续执行。

初次使用时条目均为停用状态。先检查并编辑操作，完成审核、启用和保存后，才可通过快捷键执行。

当前安装包未提供正式发布者签名：Windows 未签名，macOS 使用临时签名且未公证。

## 功能

- 内置 115 条游戏战备及对应图标，另有 8 个桌面操作示例。游戏条目需要自行配置操作。
- 自定义方向序列、图标和快捷键，支持批量启停。
- 每个战备独立保存「默认 / 当前 / 已保存」状态；快捷键使用已保存的配置。
- 编辑多步骤工作流，支持 Shell / PowerShell、运行程序、打开应用或文件 / URL、延迟、通知，以及 macOS 快捷指令。
- 逐步测试、超时、取消、失败后继续，以及 JSON 配置导入 / 导出。

导入配置会停用条目并撤销操作审核，跨平台操作和路径需重新配置。导入时还会重置文件图标路径，需要时可重新选择本地图片；不支持网络图片、网络卷或文件链接。

## 配置与安全

配置目录：

- macOS：`~/Library/Application Support/StratagemDesk-Public/`
- Windows：`%LOCALAPPDATA%\StratagemDesk-Public\`

操作以当前用户权限执行。审核前请检查脚本、参数和目标路径；敏感操作可开启日志隐藏。配置会保存执行参数，请勿将其当作密钥存储，也不要在分享配置时附带密码或令牌。更多说明见 [安全政策](https://github.com/EJYDOvO/StratagemDesk-/security/policy)。

## 源码构建

macOS 安装 Xcode 后运行 `scripts/build.sh`，输出位于 `build/Release/`。

Windows 安装 .NET 10 SDK 后运行：

```sh
dotnet publish Windows/StratagemDesk.App -c Release -r win-x64 --self-contained true -o build/windows-x64
```

## 许可

项目自有代码、8 个桌面示例及 `desk.*.svg` 原创图标使用 [MIT 许可证](https://github.com/EJYDOvO/StratagemDesk-/blob/main/LICENSE)。

**游戏图标、115 条战备数据和上游原始文件不纳入项目 MIT 许可，也未被重新许可。** 其来源、原有条款及版权信息见 [第三方声明](THIRD_PARTY.md) 和 [游戏内容声明](https://github.com/EJYDOvO/StratagemDesk-/blob/main/Sources/StratagemCore/Artwork/GAME_CONTENT_NOTICE.md)。本项目为非官方工具，与游戏权利方无隶属或背书关系。

SharpVectors.Wpf、.NET 运行时及用户导入的素材保留各自适用的许可。Windows 的 PowerShell 操作用 `$args` 读取结构化参数；第三方运行时声明保存在安装包的 `licenses/` 目录。
