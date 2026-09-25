# Agent Computer Use

**macOS 上的静默 Computer Use —— 一个二进制，接进你用的任何 agent（DSH / OpenClaw / Hermes）。**

纯 Accessibility API + CoreGraphics，不用 Codex、不用 OpenAI、不依赖任何厂商服务。
核心特性是**静默**：动作直投目标进程，**绝不把 app 抢到前台**，不打断你正在做的事。

```
┌─────────────────────────────────────────┐
│ 你的 agent (DSH / OpenClaw / Hermes)     │
└───────────────┬─────────────────────────┘
                │ MCP over stdio
┌───────────────▼─────────────────────────┐
│  Agent Computer Use (.app, 签名)         │
│  16 个工具 · AX 树 · 截图 · 实时视频      │
└───────────────┬─────────────────────────┘
                │ 直投进程 (永不抢前台)
┌───────────────▼─────────────────────────┐
│  任意 macOS app：Electron / WebUI / 原生  │
└─────────────────────────────────────────┘
```

> English version: [README.en.md](README.en.md)

---

## 目录

- [它解决什么](#它解决什么)
- [安装](#安装)
- [三个宿主里的工具名](#三个宿主里的工具名)
- [核心：静默铁律](#核心静默铁律)
- [先 probe 再动手](#先-probe-再动手)
- [权限与 TCC 归因](#权限与-tcc-归因)
- [实测能力边界](#实测能力边界)
- [关于改名](#关于改名)
- [构建与开发](#构建与开发)
- [License](#license)

---

## 它解决什么

让 agent 真正*操作*你的 Mac：打开 app、填表、点按钮、读屏幕上的字 ——
**而你可以继续干自己的事**，它不会把窗口抢到前面来。

V3.0 攻破了此前最难的两类目标：**Electron** 和 **WebUI**。
根因曾被长期误判为"这些框架不暴露无障碍树"，实际不是 —— 见
[权限与 TCC 归因](#权限与-tcc-归因)。

---

## 安装

```sh
git clone https://github.com/Tristan747-d/Agent-Computer-Use.git
cd Agent-Computer-Use
./install.sh
```

交互式菜单，勾选要装进哪些 agent：

```
Where should Computer Use be installed?

▸ [x] DSH       sidebar panel + skill · mcp__computer__*
  [x] OpenClaw  MCP server + skill · mcp__…
  [x] Hermes    MCP server + skill · dsh-computer-use:<tool>

↑/↓ move · space toggle · a all · n none · enter install · q quit
```

机器上没装的宿主会**灰显且不可选**，而不是让你勾了却什么都没发生。

非交互场景（CI / 已知目标）保留 flags：

```sh
./install.sh --host openclaw --host hermes
./install.sh --all --yes
```

流程：构建签名 `.app` → 按宿主写 MCP 配置 → 装 skill → 跑 `doctor` 自证。

**为什么必须是签名的 `.app`**：TCC 记录代码签名需求。ad-hoc 签名绑的是 CDHash，
每次重编都会吊销辅助功能授权；Apple Development 证书绑 bundle id + 证书 CN，
重编后授权仍然有效。

### 三个宿主里的工具名

同一个二进制，工具名前缀随宿主而变 —— 这是各家的 MCP 命名约定，不是本项目能决定的：

| 宿主 | 工具名 | 配置文件 |
|---|---|---|
| DSH | `mcp__computer__<tool>` | `~/.dsh/` + 面板软链 |
| OpenClaw | `mcp__…`（认 `<tool>` 后缀） | `~/.openclaw/openclaw.json` |
| Hermes | `dsh-computer-use:<tool>` | `~/.hermes/config.yaml` |

16 个工具：`list_apps`、`probe_app`、`get_app_state`、`click`、`set_value`、
`select_text`、`press_key`、`type_text`、`scroll`、`drag`、
`perform_secondary_action`、`clipboard_copy`、`move_mouse`、`start_live_view`、
`stop_live_view`、`live_view_status`。

---

## 核心：静默铁律

**所有动作默认静默。** 直投目标进程（`AXUIElementPerformAction` /
`CGEvent.postToPid`），不在系统 HID 层合成。你的前台、焦点、光标、剪贴板都不受影响。

只有显式传 `allow_foreground: true` 才允许 HID 兜底（会抢前台），
返回值里 `delivery=hidTap` 就是它发生了。

少数动作 macOS 会对后台 app 静默丢弃，**不要依赖**：

- `postToPid` 的鼠标点击 / 滚轮 / ⌘ 组合键 → 全部不投递。
  改用：坐标点击走 AX 命中测试 → `AXPress`；滚动写 `AXScrollBar` 值；
  ⌘ 快捷键改用 `set_value` 或菜单 AX action。

唯一会强制抢前台的是**模态框**（如退出时弹「保存吗」）—— 那是 app 自己的行为，
静默方案挡不住。

---

## 先 probe 再动手

**别猜框架，先调一次 `probe_app`。** 它一次告诉你：什么框架、多少节点、
多少控件、有没有 AXWebArea、属于哪一层、该怎么开。比直接拉全树便宜得多。

| 层级 | 判定依据 | 策略 |
|---|---|---|
| `L1_full_tree` | 控件 ≥ 12 且节点 ≥ 60；或有 AXWebArea 且可见文本 ≥ 400 字符 | 走 `element_index` + `AXPress`，最精确 |
| `L2_shallow_tree` | 树浅，但窗口服务器看得见窗口 | 坐标点击 + **菜单栏**（永远可靠） |
| `L3_no_windows` | AX 和窗口服务器都没有窗口 | 菜单 + 键盘盲走。如实告知用户，别空转 |

**层级按树的内容判定，不按框架猜。** 旧版按"是不是 Electron"猜，结论是**反的** ——
Electron 和 WebUI 恰恰是树最丰富的那类。

两条经验：

- **Chromium 的树是懒加载的。** `probe_app` / `get_app_state` 遇到 Electron/Chromium
  且树很浅时会自动请求无障碍模式再重测，并在报告里写明 `tree grew X → Y` 或
  `did not grow`。**看到 did not grow 就别再试了**，直接按 L2 走。
- **AX 报 0 窗口不等于没有窗口。** 有的 app `AXWindows` 是空的，但整棵树在
  focused window 属性下。两个来源都看，别因为一次 0 就放弃。

---

## 权限与 TCC 归因

### 症状

系统设置里辅助功能**明明开着**，但每个 app 都只返回 1 个 `Unknown` 元素 ——
连 Finder 都是。

### 根因

macOS 按 **responsible process**（责任进程）判定权限，向上追溯**父进程**，
不是按直接可执行文件。`dsh-cua` 由宿主 agent 拉起，授权就被记在了**宿主**名下；
而宿主自己的 TCC 行可能是 denied，于是整条进程树的 AX 全废。

进程链示例：`DSH Launcher (pid 76422) → node → dsh-cua`，
TCC 认定责任进程是 Launcher。

### 修复（自动，无需你操作）

`TCCResponsibility.reexecIfNeeded()` 用 `responsibility_spawnattrs_setdisclaim`
以**自身**为责任进程重跑一遍。**你不需要去系统设置里改任何东西。**

自查：

```sh
~/Applications/Agent\ Computer\ Use.app/Contents/MacOS/agent-cua doctor
# TCC responsible process : self (this binary) — grants apply to this app
# Self-responsible        : yes
```

那行若是 `DSH Launcher` 之类，说明授权记在别人名下。
另有 `agent-cua responsibility` 可单独查看，以及对照用的 `--no-reexec`
（会复现故障态，复现后 `AXIsProcessTrusted` 应为 `false`）。

---

## 实测能力边界

**macOS 27 实测，全部静默：前台 app 全程不变，`AXPress` 直投目标进程。**

| App | 框架 | 节点 | 层级 | 按下的真实控件 |
|---|---|---|---|---|
| DSH Launcher | WebKit / WKWebView | 1542 | L1 | 新建会话 |
| ChatGPT | 原生 AppKit + WebArea | 509 | L1 | — |
| Notion | Electron | 354 | L1 | 关闭侧边栏 |
| Canva | Electron | 192 | L1 | 首页标签 |
| GenOffice | Electron | 181 | L1 | 新建标签页 |
| WorkBuddy AI | Electron | 175 | L1 | Collapse sidebar |
| QQ | 原生 AppKit | 126 | L1 | 关闭图片查看器 |
| 微信 | 原生（自绘） | 16 | L2 | — |
| Finder | 原生 AppKit | 26 | L2 | — |

一条命令复现：`agent-cua verify <app>`。

### 仍然不能做的（架构边界，不是 bug）

**自绘控件和画布内容永远不在 AX 树里。** 画布、游戏、微信这类自绘界面把内容
呈现为像素，不是控件 —— 任何 AX 方案都绕不过，只能截图 + 坐标。
这不是 Electron 的锅。

其余已知限制：

- 屏幕录制权限在部分 macOS 上对"从终端启动的 app"不可用（从
  Finder/LaunchServices 启动正常），除实时画面外功能不受影响。
- 用本工具时不要跑性能基准测试 —— UI 自动化持续占用 CPU/GPU，会污染测量。
- `type_text` 遇到 `\n` 会按下 Return（聊天框里意味着发送，不是换行）。

---

## 关于改名

本项目由 **DSH Computer Use** 更名为 **Agent Computer Use**（不再绑定单一宿主）。

**bundle id 保持 `com.tristan.dsh.computeruse` 不变**，这是刻意的：
macOS TCC 按 bundle 身份记录授权（designated requirement 里写死
`identifier "com.tristan.dsh.computeruse"`），改了就会静默吊销每个用户
已授予的辅助功能/屏幕录制权限，逼所有人手动重授权。

向下兼容的实际措施：

- 二进制新路径 `~/Applications/Agent Computer Use.app/Contents/MacOS/agent-cua`
- 保留 `~/Applications/dsh-cua.app` 别名（指向真身，不是第二份 bundle ——
  同 id 两份会让 LaunchServices 解析歧义并悄悄弄坏屏幕录制授权）
- bundle 内保留 `dsh-cua` 可执行文件别名，旧配置里的命令行照旧可用

---

## 构建与开发

```sh
swift build -c release
./build-app.sh --install      # 构建 + 签名 + 安装 + 兼容别名
swift run cua-selftest TextEdit
```

| 路径 | 作用 |
|---|---|
| `Sources/CUACore/` | 核心：AX 桥、MCP 服务器、`AppFramework`、`TCCResponsibility` |
| `Sources/dsh-cua/` | CLI 入口（`mcp` / `doctor` / `verify` / `probe-app` / `responsibility`） |
| `Sources/cua-selftest/` | 真实 app 端到端自检 |
| `plugin/` | DSH 侧边栏面板 |
| `skill/` | 三份 skill：`SKILL.md`(DSH)、`openclaw/`、`hermes/` |
| `install.sh` | 多宿主安装 |
| `build-app.sh` | 构建签名 `.app` |

设计取舍：**用 Swift 不用 JXA**（`System Events` 走 AppleEvent 往返，慢且有损）；
**手写 MCP 不用 SDK**（官方二进制会把整数 request id 回显成字符串，弄坏普通客户端）。

---

## License

MIT
