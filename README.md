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
│   │   ├── LaunchOptions.swift # 诊断开关与报告落盘
│   │   └── Feedback.swift
│   └── SelfTest/               # 纯逻辑检查（CLT 无 XCTest）
├── Support/Info.plist
└── scripts/build.sh
```

## 构建与运行

```sh
sh scripts/build.sh          # 产出 dist/ChatGPT Bar.app（ad-hoc 签名）
open "dist/ChatGPT Bar.app"
swift run SelfTest           # 57 项纯逻辑检查
```

`swift build` 的最低系统版本由 `Package.swift` 的 `platforms: [.macOS(.v13)]` 决定，与 `Info.plist` 的 `LSMinimumSystemVersion` 一致。

### 诊断开关

这些开关只用于开发与排查，直接跑 bundle 里的可执行文件（`open --args` 在已有实例运行时不会把参数传进去）：

```sh
BIN="dist/ChatGPT Bar.app/Contents/MacOS/ChatGPTBar"
"$BIN" --settings                                   # 启动即打开设置窗口
"$BIN" --url "https://chatgpt.com/c/<id>"           # 指定初始页面
"$BIN" --dev-report /tmp/r.json --settle 10 --ab \
       --exit-after-report                          # 采样一次并写 JSON 报告
"$BIN" --dev-report /tmp/r.json --probe-composer    # 先输入探针文本再 dump（send 按钮只在有输入时存在）
"$BIN" --force-optimization 0|1                     # 覆盖长会话优化开关（不落盘）
```

报告里 `documentCommitSeconds` / `uiLoadSeconds` / `timeToFirstTurnSeconds` 分别是文档提交、load 事件、会话内容真正出现的耗时；`jank` 是一次确定性滚动扫描期间的 rAF 帧间隔统计（WebKit 没有 Long Tasks API）。

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

## 选择器校准（2026-09-05 实测）

内置选择器不是猜的，是用 `--dev-report --probe-composer` 在登录态的真实页面上逐条探测后写死的：

- `editor`：`#prompt-textarea` 命中。
- `send`：`button[data-testid="send-button"]` 命中，但**只有输入框非空时该按钮才存在**，空输入框时页面只有 `composer-plus-btn` / `Start dictation`。
- `newChat`：`[data-testid="create-new-chat-button"]`（标签是 `a`，不是 `button`）命中。
- `assistant`：`[data-message-author-role="assistant"]` 命中。
- `turn`：`[data-testid^="conversation-turn"]` 命中，元素是 `section`，不是 `article`。
- `tempChat`：`button[aria-label*="Temporary chat" i]` 只在新会话页存在，会话页里没有；回退到 `/?temporary-chat=true` 已实测有效（页面出现 `data-testid=temporary-chat-label`、按钮变为 `Turn off temporary chat`）。

schema 2 迁移会把原型写下的那批过期选择器当作“出厂默认”丢弃，只保留用户真正手写过的条目。

## 长会话卡顿：实测结论

在一条真实的重会话上测（滚动容器高 49160px、358 个 `<pre>` 代码块、约 6900 个 DOM 节点，只渲染 2 个轮次，说明站点自身做了轮次虚拟化）：

- 网络不是瓶颈：`documentCommit` 0.3-0.7s，load 事件 0.7-1.3s，主文档 105KB。
- 瓶颈在页面自身渲染：从导航开始到会话内容出现稳定需要 **5-7s**，四次采样都一样。
- 滚动期间 10s 窗口内有 6.8-8.3s 处于长帧，最长单帧约 **4s**。
- `content-visibility` 优化做了顺序对调的双向 A/B：关闭 7619ms / 8312ms 阻塞，开启 7817ms / 6809ms，最长帧两者都在 4s 附近 —— **没有稳定收益，假设被否掉**，因此该开关默认关闭并标注为实验性。
- 一次冷启动里 load 事件 60s 都没到达。因此就绪判定从 `didFinish` 改成 `didCommit`：重会话下 URL Scheme / Services 的插入不再被整页加载卡住。
- 环境因素同样显著：测试时机器 load average 8.8（8 核）、16G 内存已用 15G、压缩内存 7.7G、14.3G swap 用掉 13.8G（Chrome 系列约 7G）。这种内存压力下 WebKit 出现秒级停顿与具体 app 无关。

结论：这条链路上能在壳里修的部分已经修了（就绪判定），剩下的耗时属于站点渲染 + 机器资源，壳无法消除。真正有效的缓解是拆分超长的代码密集会话，或在系统内存压力高时先释放内存。

## 已验证 / 未验证

已在本机（macOS 15.7.1、Swift 6.0.3、仅 Command Line Tools）实测：

- `swift build` 通过，`swift run SelfTest` 57 项检查通过。
- 打包启动、面板加载 chatgpt.com、设置窗口渲染与滚动正常。
- 旧版设置迁移生效（原型保存的 toggle 快捷键与选择器被读入，随后按 schema 2 规则清掉过期选择器）。
- `chatgptbar://paste?...&mode=replace` 写入真实输入框；`--probe-composer` 的插入 + 清空往返成功。
- 失败路径可见：空会话下 `chatgptbar://copyLastResponse` 弹出橙色提示。
- 下载：页面内 `<a download>` 触发 `WKDownloadDelegate`，落到 `~/Downloads` 并按 `-1`、`-2` 去重命名。
- 附件上传：页面 `input[type=file]` 正常弹出 `NSOpenPanel`（由本 app 提供）。
- 外链：点击站外链接不在面板内跳转，交给默认浏览器打开。
- 加载失败层与“重新加载”按钮：断开本地测试服务器后出现，恢复后点击可重新载入。

尚未实测：

- Services 菜单项。`pbs -dump_pboard` 能看到服务已注册（`NSMessage = sendToChatGPT`），但 TextEdit 的服务菜单里不出现，`NSPerformService` 从脚本调用返回 false。原因是 Launch Services 把同 bundle id 的服务路由给了旧原型 bundle（见下），改 id 后条目独立注册，但仍需在系统设置里启用服务或给 app 正式签名，属于系统侧开关。
- OAuth 弹窗登录、麦克风授权。
- macOS 14+ 代理路径（本机 15.x，未接真实代理验证）。

## 已知限制

- bundle id 已从原型的 `com.local.chatgptbar` 改成 `dev.local.chatgptbar`：两个 bundle 声明同一个 id 时，Launch Services 会把 Services 和 URL Scheme 路由到它先解析到的那一个（实测路由到了旧 bundle）。设置读取会回退到旧域名，所以配置不丢。
- URL Scheme `chatgptbar` 仍与旧原型冲突，只要旧 app 还在，`open chatgptbar://...` 的落点就不确定，建议删掉旧 bundle。
- 没有应用图标（缺 `CFBundleIconFile` 资源），菜单栏用 SF Symbol。
- ad-hoc 签名、未启用 hardened runtime；分发需要自行配置签名与公证。
- `chatgpt.com` DOM 会变化，选择器仍然是需要人工维护的部分：先跑“检测选择器”，MISS 的用“导出 DOM 候选”更新。
