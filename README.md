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
│  16 个工具 · AX 树 · 截图 · 实时视频      │
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

16 个工具：`list_apps`、`probe_app`、`get_app_state`、`click`、`set_value`、
`select_text`、`press_key`、`type_text`、`scroll`、`drag`、`move_mouse`、
`perform_secondary_action`、`clipboard_copy`、`start_live_view`、
`stop_live_view`、`live_view_status`。

### 典型流程

```
probe_app("Notion")     → 什么框架、多少节点、能不能按索引点
get_app_state("Notion") → 完整 AX 树 + 截图
click(element_index=14) → 点
```

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
