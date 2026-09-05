# ChatGPT Bar

macOS 菜单栏 ChatGPT 网页壳：`WKWebView` 加载 `https://chatgpt.com`，提供全局快捷键、菜单栏菜单、窗口置顶、URL Scheme / Services 文本投递，以及可配置的页面选择器与 JS 桥。

这是按原型需求重写的初版（0.1.0），重点是修掉原型里“看起来能用其实不能用”的部分：Services 未注册、全局热键处理器叠加、页面桥失败静默、没有导航/UI 代理、代理设置无效。

## 功能需求覆盖

- 菜单栏常驻：左键开关面板，右键弹出菜单（`popUp(positioning:at:in:)`，不再临时挂 `statusItem.menu`）。
- 面板可选不抢焦点（non-activating panel），点击面板内部时主动 `makeKey()`。
- `Pin` 置顶（`.floating`）与取消置顶，状态持久化。
- 全局快捷键开关面板；`Pin` / `New Chat` / `New Temp Chat` / `Copy Last Response` 为面板内局部快捷键。
- URL Scheme 接收外部文本，支持 `append` / `replace` / `send` / `open`。
- macOS Services“Send to ChatGPT Bar”。
- 选择器可配置，附带 `检测选择器` 与 `导出 DOM 候选` 自检，以及 `恢复内置默认`。
- 注入 `WKUserScript` 页面桥，所有入口返回 `{ ok, value | error }`。
- 代理配置（仅 macOS 14+，见下）。

## 目录结构

```text
chatgpt-bar/
├── Package.swift
├── Sources/
│   ├── ChatGPTBarKit/          # 纯逻辑，无 AppKit/WebKit，被 SelfTest 覆盖
│   │   ├── AppSettings.swift   # Codable 设置 + 存储 + 旧版本迁移
│   │   ├── Shortcut.swift      # 键位/修饰键与显示
│   │   ├── SelectorSet.swift   # 内置选择器 + 用户覆盖
│   │   ├── URLCommand.swift    # chatgptbar:// 解析
│   │   ├── NavigationPolicy.swift
│   │   └── BridgeScript.swift  # 页面桥 JS 生成 + 响应解析
│   ├── ChatGPTBar/             # AppKit + WebKit 装配
│   │   ├── main.swift
│   │   ├── AppDelegate.swift
│   │   ├── PanelController.swift
│   │   ├── ChatWebController.swift
│   │   ├── PopupWindowController.swift
│   │   ├── StatusItemController.swift
│   │   ├── SettingsWindowController.swift
│   │   ├── HotKeyCenter.swift
│   │   ├── ShortcutRouter.swift
│   │   └── Feedback.swift
│   └── SelfTest/               # 纯逻辑检查（CLT 无 XCTest）
├── Support/Info.plist
└── scripts/build.sh
```

## 构建与运行

```sh
sh scripts/build.sh          # 产出 dist/ChatGPT Bar.app（ad-hoc 签名）
open "dist/ChatGPT Bar.app"
swift run SelfTest           # 48 项纯逻辑检查
```

`swift build` 的最低系统版本由 `Package.swift` 的 `platforms: [.macOS(.v13)]` 决定，与 `Info.plist` 的 `LSMinimumSystemVersion` 一致。调试期可用 `open "dist/ChatGPT Bar.app" --args --settings` 直接打开设置窗口。

## 架构要点

### 设置：单一来源

`AppSettings` 是一个 `Codable` 结构，整体以 JSON 写入 `UserDefaults`（键 `settings.json`），带 `schemaVersion`。设置窗口编辑的是草稿副本，只有点“保存并应用”才提交，`AppDelegate.apply(_:)` 对比新旧值决定要不要重建页面桥、重载页面、重建面板、重注册热键。

快捷键用 `Shortcut?` 表示，`nil` 才是“未设置”。原型把 `0` 当未设置，因此 `A` 键（keyCode 0）和无修饰键组合永远存不下来。

选择器只持久化“用户覆盖”，编辑回内置值等于清除覆盖，因此以后升级内置选择器不会被旧存档永久遮挡。首次启动会迁移原型写下的扁平键（`hotkeyKeyCode`、`selector.*`、`panelFrame`、`nonActivating`），代理设置故意不迁移。

### 页面桥：可观测的失败

`BridgeScript` 生成的 `window.__chatgptBar` 每个入口都返回 `{ ok, value | error }`；Swift 侧用 `callAsyncJavaScript` 传参（不做字符串拼接），失败统一走 HUD 提示，例如 `复制失败：找不到回复内容（assistant 选择器失配）`。

就绪判定靠轮询选择器直到超时（默认 8s），不再用 `0.4s` / `250ms` 硬编码延迟；页面还没首次加载完的调用会进等待队列，`didFinish` 后统一冲刷。

`Copy Last Response` 改为原生实现：取 `assistant` 节点文本写入 `NSPasteboard`，不再点击页面上英文 `aria-label="Copy message"` 的按钮。

### WebView：补齐网页壳该有的代理

- `WKNavigationDelegate`：白名单内（chatgpt.com / openai.com / 各登录方）留在面板，其他主框架跳转交给默认浏览器；子资源与 iframe 永不拦截；未知 scheme 拒绝。
- `WKUIDelegate`：`createWebViewWith` 用弹窗窗口承载 `target=_blank` 与 OAuth 登录；`runOpenPanel` 支持附件上传；JS `alert/confirm/prompt` 走 `NSAlert`；麦克风权限只对白名单域名放行。
- 下载：`canShowMIMEType == false` 转 `.download`，`WKDownloadDelegate` 落盘到 `~/Downloads` 并自动去重命名。
- 加载失败显示原生错误层与“重新加载”，Web Content Process 崩溃自动恢复。
- UA 不再硬编码 Safari 版本，改为在系统 UA 后追加 `ChatGPTBar/<version>`。

### 热键与局部快捷键

`HotKeyCenter` 只安装一次 Carbon event handler，重注册前先 `UnregisterEventHotKey`，并把 `OSStatus` 转成可见错误（例如“该快捷键已被其他应用占用”）。原型每次改快捷键都会叠加一个 handler，导致按一次触发 N 次。

`ShortcutRouter` 只有一个 local monitor，且局部快捷键只在聊天面板是 key window 时命中，不会再吞掉设置窗口输入框里的按键或网页自身快捷键；录制状态下 `Esc` 取消，不会一直吃按键。

### 安全

`chatgptbar://paste?...&send=1` 默认会先弹确认框（预览前 300 字），因为任何进程或网页都能打开 URL Scheme；要免确认需在设置里显式打开。`send=1` 时强制显示面板。`dump` 不再作为 URL 命令暴露（它会写剪贴板），只保留在设置界面。文本长度上限 100k。

## 代理

`WKWebView` 不读 `HTTP_PROXY` 环境变量（网络在独立 Network Process，CFNetwork 也不认这套约定），原型的实现是无效代码。这里改用 `WKWebsiteDataStore.proxyConfigurations`（`ProxyConfiguration(httpCONNECTProxy:)`），仅 macOS 14+ 生效；低于 14 时设置项禁用并提示改用系统代理。

## 已验证 / 未验证

已在本机（macOS 15.7.1、Swift 6.0.3、仅 Command Line Tools）实测：

- `swift build` 通过，`swift run SelfTest` 48 项检查通过。
- 打包启动、面板加载 chatgpt.com、设置窗口渲染与滚动正常。
- 旧版设置迁移生效（原型保存的 toggle 快捷键与选择器被读入）。
- `chatgptbar://paste?...&mode=replace` 成功写入真实网页输入框。
- 失败路径可见：空会话下 `chatgptbar://copyLastResponse` 弹出橙色提示。

尚未实测：

- Services 菜单项（已设置 `NSApp.servicesProvider` 与 `NSPortName`，但 Launch Services 缓存可能需要重新登录）。
- OAuth 弹窗登录、附件上传、下载、麦克风授权。
- macOS 14+ 代理路径（本机为 15.x，未接真实代理验证）。
- `New Temp Chat`：内置选择器可能与当前站点不符，回退到 `/?temporary-chat=true`，该参数未经核实。
- 内置选择器整体是按当前站点结构推测的，首次使用建议先跑一次 `检测选择器`，MISS 的用 `导出 DOM 候选` 更新。

## 已知限制

- 没有应用图标（缺 `CFBundleIconFile` 资源），菜单栏用 SF Symbol。
- ad-hoc 签名、未启用 hardened runtime；分发需要自行配置签名与公证。
- 与原型共用 bundle id `com.local.chatgptbar`，两个 app 同时运行会共享 `UserDefaults` 并争抢同一个 URL Scheme，建议先退出旧版。
- `chatgpt.com` DOM 会变化，选择器仍然是需要人工维护的部分。
