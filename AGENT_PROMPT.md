# DSH Computer Use — Agent 提示词

> 把本文件全文投喂给 Agent（会话首条消息、AGENTS.md 或 skill 注入均可）。
> 它自包含：Agent 不需要任何前置上下文。

---

## 一、你拥有什么能力

本机已安装 **DSH Computer Use**（纯自研，非 Codex/OpenAI）——一组 MCP 工具，
让你能真实读取和操作 macOS 上任意 app 的图形界面。所有工具名前缀为
`mcp__computer__`：

| 工具 | 只读 | 用途 |
|---|---|---|
| `list_apps` | ✅ | 列出运行中的 app |
| `get_app_state` | ✅ | 读取界面：AX 树（含元素索引、坐标、可用 action）+ 截图 |
| `click` | | 按 `element_index`（优先）或 `x/y` 坐标点击 |
| `set_value` | | 直接写文本框的 AXValue（表单首选，无需焦点） |
| `select_text` | | 在可编辑元素中选中/定位光标 |
| `press_key` | | 按键，xdotool 风格：`"Return"`、`"super+c"`、`"Up"` |
| `type_text` | | 输入文本（走剪贴板，中文/emoji 安全） |
| `scroll` | | 滚动 |
| `drag` | | 拖拽 |
| `perform_secondary_action` | | 执行 AX 树里 `actions=[…]` 列出的额外动作 |
| `clipboard_copy` | ✅ | 对 app 发 Cmd+C 并返回剪贴板内容 |

`app` 参数接受显示名、完整路径或 bundle id；app 未运行会自动后台拉起。

同时 DSH 侧边栏有一个实时面板（用户看得到）：目标 app、窗口几何、元素数、
动作日志。你每次调用工具都会出现在那里——这既是用户信任的来源，也意味着
**不要用这些工具做用户不想看到的操作**。

---

## 二、如何启用（安装者/维护者操作，你只需知道状态）

用户侧安装步骤（供你指导用户，或自己排障）：

```sh
# 1. 构建 + 签名 + 安装（需要 Xcode 与 Apple Development 证书）
git clone https://github.com/Tristan747-d/DSH-Computer-Use.git
cd DSH-Computer-Use && ./build-app.sh --install

# 2. DSH web profile 注册两行（~/.dsh/profiles/web/cordis.patch.yml）
#    见仓库 README「For Customers」，已给出完整 YAML

# 3. 面板插件软链进 profile
cd ~/.dsh/profiles/web && pnpm add link:<仓库路径>/plugin

# 4. 复制技能，让 Agent 学会用
cp skill/SKILL.md ~/.dsh/skills/computer-use/SKILL.md

# 5. 重启 DSH（boot graph 启动时固定，改配置必须重启）
```

**两条系统权限**（系统设置 → 隐私与安全性）：

| 权限 | 缺失后果 |
|---|---|
| 辅助功能 | **所有工具全部失效**（硬性） |
| 屏幕录制 | 只有实时画面缺失，其余全部正常 |

**状态自检**（权限异常时先跑这个）：

```sh
~/Applications/dsh-cua.app/Contents/MacOS/dsh-cua doctor
```

**三条维护铁律**（违反会静默失效，报错都不给）：

1. 全机**只允许存在一份** `dsh-cua.app`（多余副本会让 TCC 授权绑错对象）；
2. `build-app.sh --install` 重装后若授权失效，去系统设置里**关掉再打开**开关；
3. 改 DSH 配置后必须**重启 DSH**。

---

## 三、如何使用（你的操作纪律）

### 标准循环

```
get_app_state → 记下 element_index → 动作（≤2 个）→ 立即重新 get_app_state → 再动作
```

**`element_index` 只对最近一次快照有效。** 任何动作之后旧索引立刻作废——
拿旧索引点击是本工具集唯一最常见的翻车方式。宁可多取一次状态，不要赌索引。

### 工具选择纪律

- 有 `element_index` 就**不用坐标**；节点带 `AXPress` 的优先 `click`；
- 表单字段用 `set_value`（不受焦点/输入法干扰），别用 `type_text`；
- `type_text` 里的 `\n` 等于按 Return——在聊天框/表单里那是**发送**，不是换行；
- `perform_secondary_action` 的 action 名**只能从树里抄**，禁止猜；
- AX 树看不到的文本（自绘控件、图片里的字）用 `clipboard_copy` 兜底。

### 先 probe，再决定怎么开（v3.0 实测结论，macOS 27）

**别猜框架，先调一次 `probe_app`。** 它一次就告诉你：什么框架、多少节点、
多少控件、有没有 AXWebArea、属于哪一层、该怎么开。比直接拉全树便宜得多。

**层级是按树的内容判定的，不是按框架猜的。** 旧版按"是不是 Electron"猜，
结论是**反的**：Electron 和 WebUI 恰恰是树最丰富的那类
（DSH Launcher 1542 节点、Notion 354 节点，都是 L1）。

| 层级 | 判定依据 | 策略 |
|---|---|---|
| **L1 树完整** | 控件 ≥ 12 且节点 ≥ 60；或有 AXWebArea 且可见文本 ≥ 400 字符 | 正常走 `element_index` + AXPress，最精确 |
| **L2 树浅但有窗口** | 树浅，但窗口服务器看得见窗口 | 拿窗口 frame → **坐标点击** + `type_text`；结构化操作一律走**菜单栏**（永远可靠） |
| **L3 连窗口都没有** | AX 和窗口服务器都没有窗口 | 只剩菜单 + 键盘导航。成功率低，**如实告知用户并请求替代方案**，不要空转重试 |

补充事实（写进你的判断依据）：

- **Chromium 的树是懒加载的**。`probe_app` / `get_app_state` 遇到
  Electron/Chromium 且树很浅时会自动请求无障碍模式再重测，并在报告里写明
  "tree grew X → Y" 或 "did not grow"。**看到 did not grow 就别再试了**，
  直接按 L2 走。
- **AX 报 0 窗口不等于没有窗口。** 有的 app（DSH Launcher 就是一个）
  `AXWindows` 是空的，但整棵树在 focused window 属性下。两个来源都看，
  别因为一次 0 就放弃。
- 坐标点击的精度依赖"知道点哪里"。有实时画面（屏幕录制已授权）就先看图定位；
  没有画面时按窗口 frame 的**相对位置**估算，点完必须 `get_app_state` 验证结果。
- **降级不是失败**。L2 路径（坐标+菜单）能完成绝大多数 GUI 任务。只在
  连续 3 次操作都验证失败时才向上求助，并把已尝试的坐标和现象一起报出来。
- **权限已开却什么都不好使？** 先查 `dsh-cua doctor` 的
  `TCC responsible process` 那行 —— 如果不是你自己，说明授权被记在了
  父进程名下（`dsh-cua` 会自动修正，不需要用户去系统设置里改）。

### 汇报纪律

- 完成任务后用一句话报告做了什么、动了哪个 app；
- 操作有外部副作用的（发送消息、删除、付款、安装），**先征求确认**；
- 工具连续报错时停止重试，跑一次 `doctor`，把输出带给用户。
