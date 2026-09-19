---
name: computer-use
description: 通过 mcp__computer__* 工具读取和操作 macOS 本机 app 的界面（AX 树 + 截图 + 鼠标键盘）。当任务需要操作没有 CLI/API 的 GUI app 时使用。
whenToUse: 需要点击/输入/读取某个 Mac app 的界面时；或用户让你"操作某个软件""帮我点一下""看看那个窗口里写了什么"时。有专用 CLI 或 API 能完成时优先用它们，不要用本技能。
---

# Computer Use（macOS 桌面控制）

本机自研的 DSH 插件，工具名一律为 `mcp__computer__<tool>`。
不是 Codex/OpenAI 的东西——纯 Accessibility API + CoreGraphics，无任何外部依赖。

## 可用工具

| 工具 | 只读 | 用途 |
|---|---|---|
| `mcp__computer__list_apps` | ✅ | 列出正在运行的正规 app |
| `mcp__computer__get_app_state` | ✅ | 取 app 关键窗口的 AX 树 + 截图 |
| `mcp__computer__click` | | 按 element_index 或坐标点击 |
| `mcp__computer__set_value` | | 直接写 AXValue（表单首选） |
| `mcp__computer__select_text` | | 按文本匹配选中/定位光标 |
| `mcp__computer__press_key` | | xdotool 风格按键，如 `"Return"`、`"super+c"` |
| `mcp__computer__type_text` | | 输入文本（走剪贴板，支持中文） |
| `mcp__computer__scroll` | | 滚动 |
| `mcp__computer__drag` | | 拖拽 |
| `mcp__computer__perform_secondary_action` | | 执行 AX 树里列出的额外 action |
| `mcp__computer__clipboard_copy` | ✅ | Cmd+C 后读剪贴板 |

`app` 参数可用**显示名、完整路径或 bundle id**。app 没运行时会自动后台拉起。

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
mcp__computer__get_app_state({ app: "TextEdit" })

// 2. 动作
mcp__computer__set_value({ app: "TextEdit", element_index: 2, value: "hello" })

// 3. 必须重新取状态确认
mcp__computer__get_app_state({ app: "TextEdit" })
```

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
