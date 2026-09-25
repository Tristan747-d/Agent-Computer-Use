---
name: computer-use-openclaw
description: 通过 OpenClaw 接入的 dsh-computer-use MCP 服务器读取和操作 macOS 本机 app 的界面（AX 树 + 截图 + 鼠标键盘）。当任务需要操作没有 CLI/API 的 GUI app 时使用。
whenToUse: 需要点击/输入/读取某个 Mac app 的界面时；或用户让你"操作某个软件""帮我点一下""看看那个窗口里写了什么"时。有专用 CLI 或 API 能完成时优先用它们，不要用本技能。
---

# Computer Use（macOS 桌面控制）

OpenClaw 接入的 MCP 服务器 `dsh-computer-use`，16 个工具。工具名在 OpenClaw
里带 `mcp__` 前缀（前缀模板以你实际看到的为准，认 `<tool>` 后缀即可，
如 `list_apps` / `probe_app` / `get_app_state`）。
不是 Codex/OpenAI 的东西——纯 Accessibility API + CoreGraphics，无任何外部依赖。

## 可用工具

| 工具 | 只读 | 用途 |
|---|---|---|
| `list_apps` | ✅ | 列出正在运行的正规 app |
| `get_app_state` | ✅ | 取 app 关键窗口的 AX 树 + 截图（**不会抢前台**） |
| `click` | | 按 element_index 或坐标点击 |
| `set_value` | | 直接写 AXValue（表单首选） |
| `select_text` | | 按文本匹配选中/定位光标 |
| `press_key` | | xdotool 风格按键，如 `"Return"`、`"super+c"` |
| `type_text` | | 输入文本（postToPid 直投，**不碰剪贴板**，支持中文） |
| `scroll` | | 滚动 |
| `drag` | | 拖拽 |
| `perform_secondary_action` | | 执行 AX 树里列出的额外 action |
| `clipboard_copy` | ✅ | 读 `AXSelectedText`（**不发 Cmd+C**，不动剪贴板） |
| `start_live_view` | ✅ | 开启目标窗口**实时视频**（10fps MJPEG，不抢前台） |
| `stop_live_view` | ✅ | 停止实时视频 |
| `live_view_status` | ✅ | 查询实时视频状态与流地址 |
| `probe_app` | ✅ | 先探测这个 app 是什么框架、多少节点、属于哪一层（**拉全树之前先调这个**） |

`app` 参数可用**显示名、完整路径或 bundle id**。app 没运行时会自动后台拉起。

命令行等价物（同一套判定，报告逐字相同）：
`dsh-cua probe-app <app>`、`dsh-cua verify <app>`、`dsh-cua doctor`。

## 静默铁律（v2.0 起，v3.0 实测覆盖 Electron 与 WebUI）

**所有动作默认静默**：直投目标进程（AX API / `CGEvent.postToPid`），**绝不把 app 抢到前台**，
用户的前台、焦点、光标、剪贴板都不受影响。想看画面就开 `start_live_view`（实时视频，
ScreenCaptureKit 抓后台窗口），不要靠反复截图。

少数动作 macOS 会静默丢弃（对后台 app 无效），**不要依赖**：
- `postToPid` 的**鼠标点击 / 滚轮 / ⌘ 组合键** → 全部不投递。
  改用：坐标点击走 AX 命中测试→`AXPress`；滚动写 `AXScrollBar` 值；⌘ 快捷键改用 `set_value`/菜单 AX action。
- 只有显式传 `allow_foreground: true` 才允许 HID 兜底（会抢前台），返回值里 `delivery=hidTap` 就是它发生了。

**唯一会强制抢前台的是模态框**（如改完文档正常退出弹「保存吗」）——那是 app 自己的行为，
静默方案挡不住，测试时请用 `kill -9` 避免遗留此类状态。

## 铁律

**1. 每次动作后必须重新 `get_app_state`。**
`element_index` 只对**最近一次快照**有效，任何动作都会让它失效。
拿着旧索引去点，就是在点错误的东西——这是本技能最容易犯的错。

**2. element_index 优先于坐标。**
AX 树里有 `actions=[…]` 的节点优先用 `click`（走 AXPress，更可靠）。
只有 AX 不完整（Canvas / 游戏 / 自绘 UI / 部分 Electron）才退回截图 + 坐标点击。

**3. 表单字段用 `set_value`，不要用 `type_text`。**
`set_value` 直接写 AXValue，不需要焦点、不受输入法干扰。
`type_text` 走剪贴板，适合 AX 写不进去的场合。

**4. `type_text` 里的 `\n` 等于按 Return。**
在聊天框/表单里那是**发送/提交**，不是换行。要换行请想别的办法。

**5. `perform_secondary_action` 的 action 名只能从 AX 树里抄。**
不要猜。树里 `actions=[AXShowMenu,AXZoomWindow]` 写什么就用什么。

## 典型流程

```js
// 1. 先看状态，拿 element_index
get_app_state({ app: "TextEdit" })

// 2. 动作
set_value({ app: "TextEdit", element_index: 2, value: "hello" })

// 3. 必须重新取状态确认
get_app_state({ app: "TextEdit" })
```

## 先 probe，再决定怎么开

**别猜，先问一次。** `probe_app` 一次调用就告诉你这个 app 是什么框架、
有多少节点、属于哪一层、该怎么开。比直接拉全树便宜得多。

**层级是按树的内容判定的，不是按框架猜的。** 旧版按"是不是 Electron"猜，
结论是错的：Electron 和 WebUI 恰恰是树最丰富的那类。

| 层级 | 判定依据 | 策略 |
|---|---|---|
| `L1_full_tree` | 控件 ≥ 12 且节点 ≥ 60，或有 AXWebArea 且可见文本 ≥ 400 字符 | 正常走 element_index + AXPress |
| `L2_shallow_tree` | 树浅，但窗口服务器看得见窗口 | 坐标点击；结构化操作走**菜单栏**（永远可靠） |
| `L3_no_windows` | AX 和窗口服务器都没有窗口 | 菜单 + 键盘盲走。如实告知用户，不要空转 |

`get_app_state` 头部也会打出 `Framework:` 和 `Strategy tier:`，同一套判定。

- **Chromium 的树是懒加载的**：`probe_app` / `get_app_state` 遇到 Electron/Chromium
  且树很浅时会自动请求无障碍模式（`AXEnhancedUserInterface` +
  `AXManualAccessibility`）再重测，并在报告里写明树有没有变大。
  报告说"did not grow"就别再试了，直接按 L2 走。
- **AX 报 0 窗口不等于没有窗口**：有的 app（DSH Launcher 就是一个）
  `AXWindows` 是空的，但整棵树在 focused window 属性下。两个来源都看，
  别因为一次 0 就放弃。
- 无画面时坐标按窗口 frame 相对位置估算，点完必须 get_app_state 验证。
- 连续 3 次操作验证失败才向上求助，并附上已试坐标和现象。

## diff 模式

`get_app_state` 默认只回传**与上次快照相比有变化的行**，省 token。
遇到窗口切换、app 重启、或树结构变化看不懂时，用 `disableDiff: true` 取全量。

## 权限

- **辅助功能**：所有工具都需要
- **屏幕录制**：只有截图需要；没授权时其余工具照常工作

查看状态：`~/Applications/dsh-cua.app/Contents/MacOS/dsh-cua doctor`

`get_app_state` 返回的 text 里会有 `Note: screenshot unavailable: …` 说明截图缺失原因，此时不要假装看得到画面，改用 AX 树的信息。

## 局限（必须诚实承认）

- AX 树可能残缺：Canvas、游戏、部分 Electron app 只暴露少量节点。这时截图 + 坐标点击是唯一出路，且精度不如原生 AX。
- 全屏或最小化的窗口可能取不到截图。
- **跑 CUA 期间不要做 benchmark**：持续占用 CPU/GPU，会污染本机冷态基线（M5 有可逆 GPU 功耗塌缩，这是已知最大测量混淆源）。
- 涉及删除数据、付款、发消息、装软件等有外部副作用的操作，**先跟用户确认再动手**。
