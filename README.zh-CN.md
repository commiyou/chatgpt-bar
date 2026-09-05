# ChatGPT Bar

[English](README.md) | [简体中文](README.zh-CN.md)

一个接近原生体验的 macOS 菜单栏 ChatGPT 网页壳，使用 Swift / AppKit / `WKWebView` 构建。

ChatGPT Bar 把 ChatGPT 放进一个可常驻、可置顶、可快速呼出的 macOS 面板，内置全局快捷键、URL Scheme、macOS Services、可配置页面选择器、诊断工具和本地优先设置。

![ChatGPT Bar panel](docs/images/panel.png)

![ChatGPT Bar settings](docs/images/settings.png)

## 功能

- **菜单栏常驻**：左键显示 / 隐藏面板，右键打开菜单。
- **全局快捷键**：默认 `⌥⌘Space` 显示 / 隐藏面板。
- **面板内快捷键**：默认 `⌘P` Pin、`⌘N` New Chat、`⌘⇧N` New Temp Chat、`⌘⇧C` Copy Last Response。
- **Pin 置顶**：使用 macOS `.floating` window level，状态持久化。
- **可配置的回复复制**：默认使用 `getLastResponse` Markdown，也可以触发 ChatGPT 原生 Copy 并观察系统剪贴板。
- **URL Scheme**：支持 `open`、`newChat`、`newTempChat`、`copyLastResponse`、`paste`，可逐项禁用。
- **macOS Services**：从其他应用发送选中文本。
- **外部粘贴模式**：`append`、`replace`、`send`，自动发送默认需要确认。
- **页面适配**：选择器可配置，支持检测选择器、导出 DOM 候选和恢复内置默认。
- **失败可见**：选择器失配、快捷键冲突、页面桥失败、命令禁用都有提示。
- **代理**：macOS 14+ 使用 `WKWebsiteDataStore.proxyConfigurations`。
- **本地优先**：无遥测；登录态和设置保存在本机。

## 系统要求

- macOS 13 Ventura 或更高版本
- Apple Silicon 或 Intel Mac

## 安装

从 [Releases](../../releases/latest) 下载对应架构：

| 机型 | 产物 |
| --- | --- |
| Apple Silicon | `ChatGPTBar-macos-arm64-v<version>.zip` |
| Intel | `ChatGPTBar-macos-x86_64-v<version>.zip` |

Release 还会附带源码包和 `SHA256SUMS.txt`。

当前产物是 ad-hoc 签名，未公证。如果 macOS 阻止首次启动，运行：

```sh
xattr -dr com.apple.quarantine "ChatGPT Bar.app"
```

本地构建：

```sh
sh scripts/build.sh
open "dist/ChatGPT Bar.app"
```

## 快捷键

| 动作 | 默认快捷键 | 作用范围 |
| --- | ---: | --- |
| 显示 / 隐藏面板 | `⌥⌘Space` | 全局 |
| Pin / Unpin | `⌘P` | 面板聚焦 |
| New Chat | `⌘N` | 面板聚焦 |
| New Temp Chat | `⌘⇧N` | 面板聚焦 |
| Copy Last Response | `⌘⇧C` | 面板聚焦 |

快捷键可在 **Settings → Shortcuts** 修改。局部快捷键只在聊天面板是 key window 时生效，避免吞掉设置窗口或网页输入框中的按键。

## 复制策略

可以在 **设置 → 通用 → 复制** 中选择 `Copy Last Response` 的策略：

- **Markdown（`getLastResponse`）**：通过页面桥读取最后一条 assistant 容器，
  从渲染后的 DOM 重建 Markdown，再由原生应用写入 macOS 剪贴板。
- **GPT 原生 Copy**：触发最后一条回复附近的页面 Copy 按钮，并等待系统剪贴板
  发生变化。不会包装或拦截 `navigator.clipboard`，页面仍使用自己的原始逻辑。

`getLastResponse` bridge 始终返回 `markdown` 字段。两种策略特意分开，因为
ChatGPT 原生 Copy 可能只产生纯文本，而且脚本触发的点击不一定拥有和真实鼠标
点击相同的 user activation 权限。

## URL Scheme

所有外部命令通过 `chatgptbar://` 触发，可在 **Settings → URL Scheme** 中逐项启用 / 禁用。

| 命令 | 示例 |
| --- | --- |
| `open` | `chatgptbar://open` |
| `newChat` | `chatgptbar://newChat` |
| `newTempChat` | `chatgptbar://newTempChat` |
| `copyLastResponse` | `chatgptbar://copyLastResponse` |
| `paste` | `chatgptbar://paste?text=hello&mode=append&send=0` |

`paste` 支持参数：

- `mode=append|replace`
- `send=0|1`
- `reveal=0|1`

`send=1` 默认会弹确认框，因为任何本地进程都可以打开 URL Scheme。若确认风险后要免确认，需要在设置中显式打开。

## Pin 语义

Pin 使用 macOS `.floating` window level，表示高于普通窗口并尽量跨 Space 显示。它不是系统级“永远最高”：菜单、安全授权界面和部分独占全屏窗口仍可能显示在上面。

非激活面板在应用失焦时可能被 AppKit 重新排序，因此代码会在显示、切换 Pin、成为 / 失去 key window 时重新应用层级和置前状态。

## 诊断

直接运行 bundle 内可执行文件：

```sh
BIN="dist/ChatGPT Bar.app/Contents/MacOS/ChatGPTBar"

"$BIN" --settings [general|shortcuts|urlScheme|page]
"$BIN" --url "https://chatgpt.com/c/<id>"
"$BIN" --dev-report /tmp/report.json --settle 10 --ab --exit-after-report
"$BIN" --dev-report /tmp/report.json --probe-composer
"$BIN" --force-optimization 0|1
```

报告包含文档提交、UI load、首条回复出现时间、滚动期间长帧统计和选择器命中情况。

## 开发

```sh
swift build
swift run SelfTest
sh scripts/build.sh

# 构建指定架构
ARCHS=x86_64 sh scripts/build.sh

# 构建两种架构（支持的环境）
ARCHS="arm64 x86_64" sh scripts/build.sh
```

`SelfTest` 是普通 SwiftPM 可执行测试入口，适合在没有完整 Xcode / XCTest 的 Command Line Tools 环境运行纯逻辑检查。窗口层级、多显示器、全屏和真实 ChatGPT 行为仍需手测。

## 目录结构

```text
.
├── Package.swift
├── Sources/
│   ├── ChatGPTBarKit/          # 纯逻辑：设置、快捷键、选择器、页面桥
│   ├── ChatGPTBar/             # AppKit + WebKit 装配与 UI
│   └── SelfTest/               # 纯逻辑自检
├── Support/Info.plist
├── Resources/
├── scripts/build.sh
└── docs/images/
```

## 发版

1. 更新 `Support/Info.plist` 中的 `CFBundleShortVersionString`。
2. 更新 `CHANGELOG.md`。
3. 合并到 `main`。

Release workflow 会检测未发布的版本号，自动创建 `v<version>` tag，分别构建 `arm64` 和 `x86_64`，创建源码包，并上传所有产物。

也可以在 Actions 页手动触发 workflow 并指定版本，带不带 `v` 前缀都可以。

## 签名与公证

当前 release 产物是 ad-hoc 签名，适合本地构建和自用分发。公开分发建议配置：

1. Apple Developer Program 会员。
2. `Developer ID Application` 证书。
3. 签名时启用 Hardened Runtime。
4. 使用 `notarytool` 公证，并用 `stapler staple` 附加票据。

CI 需要配置证书、证书密码、Apple ID 或 App Store Connect API key、Apple Team ID 等仓库 secrets。当前仓库刻意不保存任何签名凭证。

## 隐私与安全

- 不采集遥测。
- 不代理页面内容，除非你在设置中配置代理。
- ChatGPT 登录态、Cookie、缓存保存在本机应用数据目录。
- 外部 URL 命令可逐项禁用，自动发送需要显式开启。

## 已知限制

- 页面选择器依赖 ChatGPT DOM，站点改版后需要重新校准。
- DOM 回退无法完美还原所有复杂卡片、表格或自定义组件。
- 产物是 ad-hoc 签名，未公证。
- OAuth 弹窗、麦克风授权和 macOS 14+ 代理路径需要继续手测。

## 贡献

提交 issue 或 PR 前请先看 [CONTRIBUTING.md](CONTRIBUTING.md)。安全漏洞请参考 [SECURITY.md](SECURITY.md)，不要直接在公开 issue 中提交细节。

## License

[MIT](LICENSE)
