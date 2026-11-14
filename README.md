# Agent Computer Use

**macOS 上的静默 Computer Use —— 一个二进制，接进你用的任何 agent（DSH / OpenClaw / Hermes）。**

纯 Accessibility API + CoreGraphics，不用 Codex、不用 OpenAI、不依赖任何厂商服务。
**动作直投目标进程，绝不把 app 抢到前台** —— 你装完就能继续干自己的事。

```
┌─────────────────────────────────────────┐
│ 你的 agent (DSH / OpenClaw / Hermes)     │
└───────────────┬─────────────────────────┘
                │ MCP over stdio
┌───────────────▼─────────────────────────┐
│  Agent Computer Use (签名 .app)          │
│  20 个工具 · AX 树 · 截图 · 实时视频      │
└───────────────┬─────────────────────────┘
                │ 直投进程（永不抢前台）
┌───────────────▼─────────────────────────┐
│  Electron / WebUI / 原生 app             │
└─────────────────────────────────────────┘
```

> English version: [README.en.md](README.en.md)

---

## 目录

- [安装](#安装)
- [用起来](#用起来)
- [4.0 新增：截图、读字、挑窗口、录像](#40-新增截图读字挑窗口录像)
- [静默是什么意思](#静默是什么意思)
- [权限](#权限)
- [支持哪些 app](#支持哪些app)
- [常见问题](#常见问题)
- [开发](#开发)
- [License](#license)

---

## 安装

```sh
git clone https://github.com/Tristan747-d/Agent-Computer-Use.git
cd Agent-Computer-Use
./install.sh
```

勾一下要装进哪些 agent：

```
Where should Computer Use be installed?

▸ [x] DSH       sidebar panel + skill · mcp__computer__*
  [x] OpenClaw  MCP server + skill · mcp__…
  [x] Hermes    MCP server + skill · dsh-computer-use:<tool>

↑/↓ move · space toggle · a all · n none · enter install · q quit
```

没装的宿主灰显不可选。想跳过菜单：

```sh
./install.sh --host openclaw --host hermes
./install.sh --all --yes
```

要求：macOS 14+，Xcode 命令行工具（构建用）。

---

## 用起来

### 工具名

同一个二进制，三家宿主的前缀不同：

| 宿主 | 工具名 | 配置位置 |
|---|---|---|
| DSH | `mcp__computer__<tool>` | `~/.dsh/` + 面板软链 |
| OpenClaw | `mcp__…`（认 `<tool>` 后缀） | `~/.openclaw/openclaw.json` |
| Hermes | `dsh-computer-use:<tool>` | `~/.hermes/config.yaml` |

20 个工具：`list_apps`、`probe_app`、`get_app_state`、`click`、`set_value`、
`select_text`、`press_key`、`type_text`、`scroll`、`drag`、`move_mouse`、
`perform_secondary_action`、`clipboard_copy`、`start_live_view`、
`stop_live_view`、`live_view_status`，以及本版新增的
`pick_window`（系统共享选择器让用户亲手挑窗口）、
`start_recording` / `stop_recording`（SCRecordingOutput 录操作过程）、
`open_recording`（SCRECordingEditor 预览/分享录像）。

### 典型流程

```
probe_app("Notion")     → 什么框架、多少节点、能不能按索引点
get_app_state("Notion") → 完整 AX 树 + 截图
click(element_index=14) → 点
```

### 屏幕相关的四个工具（4.0）

```
pick_window()                       → 让用户亲手挑窗口（系统共享选择器）
start_recording(app:"Notion")       → 开始录这个窗口的操作过程
stop_recording()                    → 收尾，返回 .mov 路径 / 时长 / 大小
open_recording()                    → 系统录像编辑器预览（会弹窗，仅在用户要求时用）
```

## 4.0 新增：截图、读字、挑窗口、录像

这一版把屏幕相关的部分全部换成 ScreenCaptureKit 的现役 API，并补上视觉模型能读、AX 读不到的东西。

### 截图：`SCScreenshotManager`

`get_app_state` 的截图原先走 `CGWindowListCreateImage`（macOS 15 起废弃）。现在默认用
`SCScreenshotManager.captureImage(contentFilter:configuration:)`：不起流、不加线程，
拍的是**目标窗口**，窗口全程待在后台。

| 环节 | 实测（M5，访达 1710×1074 窗口） |
| --- | --- |
| `SCScreenshotManager` 单帧 | 150–650 ms |
| 画面编码（JPEG 0.8） | 20–60 ms |
| 发给模型的那张图 | JPEG，比 PNG 小一个量级、编码快 4–5 倍 |
| 落盘存档 | 仍写 PNG（`~/Library/Caches/dsh-cua/<pid>-<窗号>.png`） |

只有 ScreenCaptureKit 列不出该窗口时才回退到旧 API。

### 读字：`Vision.RecognizeTextRequest`

截图后顺手跑一次文字识别，把 AX 树看不到的字（canvas、Electron 自绘、图片里的字）
附在 `get_app_state` 结果的末尾，按阅读顺序给出「像素坐标 + 置信度」：

```
## OCR text (from the screenshot; AX may not expose these)
Working edge: 2400px · 134 lines · 937ms
[  21,  60 1426x 21  0.30] 最近使用 2026年西外体育节
[ 248, 149 1371x 20  1.00] Macintosh HD 2026-10-11 15:06 328.38 GB 启动宗卷
```

**一个必须知道的限制**：这版 macOS 的文本识别，**每换一种图片尺寸都要重新编译一次 ANE 图**。
实测冷态 30–150 s，同尺寸第二次 0.3–1 s。所以：

- 同尺寸热态：随 `get_app_state` 一起返回，整次调用 2.6–3.9 s；
- 首次遇到新尺寸：只等 1.2 s，识别任务留在后台继续编图，**不拖住工具调用**；
  下一次同尺寸调用就带上文字。

### 挑窗口：`pick_window`（`SCContentSharingPicker`）

一个 app 开了很多窗口时，让**用户**用系统共享选择器亲手点一个，比猜「最大的那个」可靠。
选择器里默认排除本程序和 DSH 面板本身，防止误选后一直拍自己。

### 录像：`start_recording` / `stop_recording` / `open_recording`

- `SCRecordingOutput` 把 agent 操作的窗口录成 `.mov`（默认 H.264，15 fps，最长边 ≤2400 px），
  落在 `~/Library/Caches/dsh-cua/recordings`；
- 录像时窗口同样不需要到前台；录自己（DSH 面板）会被拒绝；
- `open_recording` 用 `SCRECordingEditor`（macOS 27+）弹出系统预览/分享界面——
  **这会让一个窗口出现**，所以只在用户明确要求看录像时才调用。

### 一个没接的：`SCVideoEffectOutput`

它在头文件里是 `API_UNAVAILABLE(macos)`——iOS 27 的摄像头视频特效，与窗口截屏无关。

**先 `probe_app` 再动手。** 一次调用告诉你该走哪条路，比直接拉全树便宜得多：

| 层级 | 判定 | 策略 |
|---|---|---|
| `L1_full_tree` | 控件 ≥ 12 且节点 ≥ 60，或有 AXWebArea 且可见文本 ≥ 400 字符 | `element_index` + `AXPress` |
| `L2_shallow_tree` | 树浅，但有窗口 | 坐标点击 + 菜单栏 |
| `L3_no_windows` | 没有窗口 | 菜单 + 键盘盲走 |

---

## 静默是什么意思

所有动作直投目标进程（`AXUIElementPerformAction` / `CGEvent.postToPid`），
不在系统 HID 层合成。**你的前台、焦点、光标、剪贴板都不受影响**，想看画面就开
`start_live_view`（实时视频抓后台窗口），不要靠反复截图。

传 `allow_foreground: true` 才会允许抢前台（返回值 `delivery=hidTap` 即表示发生了）。

⚠️ macOS 会对后台 app 静默丢弃这几类动作，别依赖：
`postToPid` 的鼠标点击、滚轮、⌘ 组合键。改用坐标点击走 AX 命中测试 → `AXPress`、
滚动写 `AXScrollBar` 值、⌘ 快捷键走 `set_value` 或菜单 AX action。

唯一会强制抢前台的是**模态框**（如退出时弹「保存吗」）—— 那是 app 自己的行为。

---

## 权限

首次运行会申请**辅助功能**和**屏幕录制**。若 `doctor` 报未授权：

```sh
~/Applications/Agent\ Computer\ Use.app/Contents/MacOS/agent-cua doctor
```

macOS 按**责任进程**判定权限（向上追溯父进程），所以有时宿主 agent 的身份会顶替
本程序的身份导致授权不生效。本程序已自动处理（以自身为责任进程重跑），
无需你手动改任何设置。若那行 `TCC responsible process` 不是本程序，请重跑
`./install.sh`。

---

## 支持哪些 app

macOS 27 实测：

| App | 类型 | 节点 | 层级 |
|---|---|---|---|
| DSH Launcher | WebUI (WKWebView) | 1542 | L1 |
| ChatGPT | 原生 + WebArea | 509 | L1 |
| Notion / Canva / GenOffice / WorkBuddy AI | Electron | 175–354 | L1 |
| QQ / Clash | 原生 | 78–126 | L1 |
| 微信 | 原生（自绘） | 16 | L2 |
| Finder | 原生 | 26 | L2 |

复现：`agent-cua verify <app>`。

**自绘控件和画布内容不在 AX 树里**（画布、游戏、微信这类把内容画成像素，
不是控件），只能截图 + 坐标。这是任何 AX 方案的边界。

---

## 常见问题

**系统设置里权限开着，但每个 app 只返回 1 个元素？**
权限按责任进程判定，被记到了父进程名下。程序会自动修正；若未生效重跑 `./install.sh`。

**`probe_app` 说 `did not grow`？**
已请求 Chromium 无障碍模式但树没响应，直接按 L2 走，别重试。

**从 DSH Computer Use 升级会丢授权吗？**
不会。bundle id 未变，重装后授权保留。旧路径 `dsh-cua.app` 仍可用（软链）。

**屏幕录制不生效？**
部分 macOS 对"从终端启动的 app"不给屏幕录制。从 Finder 启动本程序即可。

**`type_text` 里的 `\n`？**
按下 Return —— 聊天框里是发送，不是换行。

---

## 开发

```sh
swift build -c release
./build-app.sh --install
swift run cua-selftest TextEdit
```

| 路径 | 作用 |
|---|---|
| `Sources/CUACore/` | AX 桥、MCP 服务器、`AppFramework`、`TCCResponsibility` |
| `Sources/CUACore/SnapshotCapture.swift` | 截图（SCScreenshotManager）+ OCR（Vision）+ 尺寸预热缓存 |
| `Sources/CUACore/WindowPicker.swift` | 系统共享选择器（SCContentSharingPicker） |
| `Sources/CUACore/SessionRecorder.swift` | 操作过程录像（SCRecordingOutput / SCRECordingEditor） |
| `Sources/dsh-cua/` | CLI 入口 |
| `Sources/cua-selftest/` | 端到端自检 |
| `plugin/` | DSH 侧边栏面板 |
| `skill/` | 三份 skill |
| `install.sh` | 多宿主安装 |
| `build-app.sh` | 构建签名 `.app` |

用 Swift 而非 JXA（`System Events` 走 AppleEvent 往返，慢且有损）；
手写 MCP 而非 SDK（官方二进制会把整数 request id 回显成字符串，弄坏普通客户端）。

---

## License

MIT
