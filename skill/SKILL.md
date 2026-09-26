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
| `mcp__computer__get_app_state` | ✅ | 取 app 关键窗口的 AX 树 + 截图（**不会抢前台**） |
| `mcp__computer__click` | | 按 element_index 或坐标点击 |
| `mcp__computer__set_value` | | 直接写 AXValue（表单首选） |
| `mcp__computer__select_text` | | 按文本匹配选中/定位光标 |
| `mcp__computer__press_key` | | xdotool 风格按键，如 `"Return"`、`"super+c"` |
| `mcp__computer__type_text` | | 输入文本（postToPid 直投，**不碰剪贴板**，支持中文） |
| `mcp__computer__scroll` | | 滚动 |
| `mcp__computer__drag` | | 拖拽 |
| `mcp__computer__perform_secondary_action` | | 执行 AX 树里列出的额外 action |
| `mcp__computer__clipboard_copy` | ✅ | 读 `AXSelectedText`（**不发 Cmd+C**，不动剪贴板） |
| `mcp__computer__start_live_view` | ✅ | 开启目标窗口**实时视频**（10fps MJPEG，不抢前台） |
| `mcp__computer__stop_live_view` | ✅ | 停止实时视频 |
| `mcp__computer__live_view_status` | ✅ | 查询实时视频状态与流地址 |
| `mcp__computer__probe_app` | ✅ | 先探测这个 app 是什么框架、多少节点、属于哪一层（**拉全树之前先调这个**） |

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
mcp__computer__get_app_state({ app: "TextEdit" })

// 2. 动作
mcp__computer__set_value({ app: "TextEdit", element_index: 2, value: "hello" })

// 3. 必须重新取状态确认
mcp__computer__get_app_state({ app: "TextEdit" })
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

## 自绘制画布：走键盘路径，不要死磕坐标点击

**AX 树里只有菜单栏（约 198 个节点，全是 menu bar）时，你面对的是自绘制画布**（Qt/自绘 UI，
典型：微信）。这时坐标点击**必然失败**——`click` 会直接报：

```
no accessibility element at (212,814) could be activated silently;
refusing to synthesize a focus-stealing HID click
```

这是**正确行为，不是 bug**：静默坐标点击靠 `AXUIElementCopyElementAtPosition→AXPress`，
画布区没有 AX 节点，命中测试返回空，工具拒绝回退到抢前台的 HID。别去求它放开。

**真正能走通的是键盘路径**，而且完全静默：

| 手段 | 效果 |
|---|---|
| `press_key` `down` / `up` | ✅ **既能切左侧导航栏（聊天/通讯录/收藏/朋友圈），也能在聊天列表里逐行移动选中会话** |
| `type_text` | ✅ 生效，文字落在消息输入框 |
| `press_key` `return` | ✅ 发送 |
| `click` 坐标 | ❌ 被拒（画布无 AX 节点） |
| `press_key` `super+…` | ❌ 不投递 |
| 菜单栏 `qt_itemFired` 项（窗口>聊天/收藏、编辑>搜索） | ⚠️ **会激活 app 抢前台，禁用** |

### 焦点在哪个面板，方向键就走哪个

同一个 `down` 键，行为取决于当前焦点面板——这是最容易卡住的地方：

- 焦点在**左侧导航栏** → `up`/`down` 在导航项之间移动（聊天 ↔ 通讯录 ↔ 收藏 ↔ 朋友圈）
- 焦点回到**聊天列表** → `up`/`down` 才逐行切换会话

**想切会话却只在导航项之间跳，说明焦点还在导航栏。** 先用 `up`/`down` 把导航栏挪到"聊天"，
进入列表后方向键才会走会话行。用 `left`/`right` 可以在两个面板间移动焦点。

### 用绿色高亮客观定位"选中了哪一行"

聊天列表里选中行的背景是**绿色 RGB≈(23,147,98)**，其余是灰。用像素采样比 OCR 猜标题可靠得多：

```bash
screencapture -x -l <winid> /tmp/w.png   # 取窗口图（被遮挡也能取到）
# 逐行求平均 RGB，找 G 显著高于 R/B 的连续行 → 选中行 y 区间
# 再把该 y 区间裁出来 OCR → 选中会话的名字
```

Retina 注意：截图是像素尺寸，坐标换算 `pt = px / 2`（窗口在 y=33 时 `screen_y = 33 + px_y/2`）。

### 验证：别用 live view 的帧

**MJPEG live view 会吐冻结帧**——连续多次拉同一帧，md5 完全相同，看起来"什么都没变"。
用它做 before/after 对比会得出**假阴性**，我曾据此误判"菜单和键盘全部无响应"。

要验证就取 ground truth：

```bash
screencapture -x -l <winid> /tmp/x.png    # 即使窗口被遮挡也能取到真实内容
```

另外：**自己用 swiftc 编的独立二进制没有 TCC 授权**（`AXIsProcessTrusted=false`），
它 post 出去的事件会被**静默丢弃**——用它测出来的"按键无效"同样是假证。只有本插件的通道能投递。

### 发送前必须三重确认

发消息是不可逆的外部副作用。按 Return 之前确认：

1. **选中行的绿色高亮**在你目标的那一行的 y 区间
2. 裁该行 OCR 出来的**会话名** == 目标名
3. 输入框里**只有**你要发的那句话（先 `delete` 清干净再打）

任一项不成立就不要按 Return。

## diff 模式

`get_app_state` 默认只回传**与上次快照相比有变化的行**，省 token。
遇到窗口切换、app 重启、或树结构变化看不懂时，用 `disableDiff: true` 取全量。

## 权限

- **辅助功能**：所有工具都需要
- **屏幕录制**：只有截图需要；没授权时其余工具照常工作

查看状态：`~/Applications/dsh-cua.app/Contents/MacOS/dsh-cua doctor`

`get_app_state` 返回的 text 里会有 `Note: screenshot unavailable: …` 说明截图缺失原因，此时不要假装看得到画面，改用 AX 树的信息。

## 局限（必须诚实承认）

- AX 树可能残缺：Canvas、游戏、部分 Electron app 只暴露少量节点。**若树里只剩菜单栏（自绘制画布），坐标点击会被拒——改走键盘路径**，见「自绘制画布」一节。
- 全屏或最小化的窗口可能取不到截图。
- **跑 CUA 期间不要做 benchmark**：持续占用 CPU/GPU，会污染本机冷态基线（M5 有可逆 GPU 功耗塌缩，这是已知最大测量混淆源）。
- 涉及删除数据、付款、发消息、装软件等有外部副作用的操作，**先跟用户确认再动手**。
