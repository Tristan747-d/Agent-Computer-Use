# DSH Computer Use

**为 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) 自研的 macOS Computer Use —— 不用 Codex，不用 OpenAI，不依赖任何厂商服务。**

给你的 DSH agent 装上眼睛和手：它能读取任意 app 的辅助功能树，点击、输入、滚动、拖拽；
而你在 DSH 侧边栏里**实时看着它干活**。

```
┌─────────────────────────────────────────────┐
│ ● Computer Use                    [暂停][刷新] │
│   运行中                                      │
├─────────────────────────────────────────────┤
│                                             │
│         < 实时窗口画面 >             1470×923 │
│                                             │
├─────────────────────────────────────────────┤
│ 目标 app: Finder          元素: 235          │
│ 窗口: 1470×923            更新于: 13:07:42   │
│ 最近动作                                     │
│   13:07:42  读取 Finder 的界面状态            │
│   13:07:40  列出运行中的 app                  │
└─────────────────────────────────────────────┘
```

> English version: [README.en.md](README.en.md)

---

## 目录

- [给使用者](#给使用者)
  - [为什么要有这个项目](#为什么要有这个项目)
  - [能做什么](#能做什么)
  - [实时视频](#实时视频)
  - [安装](#安装)
  - [权限](#权限)
  - [快速验证](#快速验证)
  - [已知限制](#已知限制)
- [给开发者](#给开发者)
  - [架构](#架构)
  - [版本记录](#版本记录)
  - [设计取舍](#设计取舍)
  - [构建](#构建)
  - [本仓库记录的坑](#本仓库记录的坑)
  - [数据契约](#数据契约)
  - [客户端插件说明](#客户端插件说明)
  - [仓库结构](#仓库结构)
- [参与贡献](#参与贡献)
- [License](#license)

---

## 给使用者

你想让 DSH agent 真正*操作*你的 Mac —— 打开一个 app、填表、点按钮、读屏幕上的字。
这个项目就是干这个的。

### 为什么要有这个项目

macOS 上唯一开箱即用的 Computer Use 是 Codex 的 `SkyComputerUseClient`。
它确实是一个真的 MCP server，也确实能在 Codex 之外完成握手 —— **但每个动作都会失败**：

```
Computer Use server error -10000: Sender process is not authenticated
```

那个二进制会通过 macOS audit token 校验调用方的**代码签名身份**，并要求 OpenAI 的 Team ID。
其他任何客户端都过不去。所以本项目干脆从零重写了一个干净实现。

### 能做什么

| 工具 | 作用 |
|---|---|
| `list_apps` | 列出正在运行的 app |
| `get_app_state` | 读取 app 界面（辅助功能树 + 截图） |
| `click` | 点按钮、链接、菜单项 |
| `set_value` | 直接填写文本框 |
| `select_text` | 选中文本或定位光标 |
| `press_key` | 键盘快捷键（`Cmd+S`、`Return`、方向键……） |
| `type_text` | 输入文本 —— 中文、emoji 都行 |
| `scroll` | 滚动列表或页面 |
| `drag` | 拖拽 |
| `move_mouse` | 悬停不点击 —— 下钻嵌套菜单全靠它 |
| `perform_secondary_action` | 触发菜单项等额外动作 |
| `clipboard_copy` | 读取选中的文本 |
| `start_live_view` | 开启 app 窗口的**实时视频**（不抢前台） |
| `stop_live_view` | 停止实时视频 |
| `live_view_status` | 查看推流状态和流地址 |

共 **15 个工具**。agent 遇到需要操作 GUI 的任务时会自动调用它们。
仓库里附带了一份 skill，教它*怎么用好*这些工具，其中最重要的一条铁律是：
**每次动作之后重新读一次界面状态** —— 界面一变，元素索引就失效了。

### 实时视频

侧边栏面板显示的是**连续视频**，不是幻灯片式的截图堆叠。

实现上：**ScreenCaptureKit** 抓取目标窗口（抓的是某个具体窗口，不是整块屏幕），
每帧 JPEG 编码一次，然后以 `multipart/x-mixed-replace` MJPEG 分发给所有观看者。
一个普通的 `<img>` 就能原生渲染 —— 不需要解码器、不需要 WebSocket、不需要 JS 库；
而且因为每帧只编码一次，十个观看者也只花一次编码的开销。

本机实测：**稳定 10 fps**，长边 1600 px 时每帧约 130 KB；更关键的是 ——
**被抓取的窗口永远不会被拉到前台**。ScreenCaptureKit 能抓取后台窗口，
所以"静默"这条契约依然成立：你可以在另一个 app 里继续干活，同时看着 agent 操作。

流只在**仅本机回环**的临时端口（`127.0.0.1`）上提供服务，机器外部永远访问不到。
会话结束或调用 `stop_live_view` 时停止。

**面板绝不会拍到自己。** 把流指向正在渲染面板的那个窗口，画面就会无限自我嵌套。
因此服务端会拒绝抓取正在显示 DSH 界面的窗口 —— 依据窗口标题、DSH webserver URL、
DSH bundle id，或 `com.apple.Safari.WebApp.*` 形式的 bundle id（DSH 桌面壳就是这么打包的），
并且拒绝时会明确说明理由。这个判断是**按窗口**而不是按 app 的，
所以抓取另一个 Safari 标签页仍然正常。两条路径都会执行该检查：
显式的 `start_live_view` 调用，以及 `get_app_state` 触发的自动跟随。

`get_app_state` 仍会随辅助功能树返回一张静态截图，供模型自己看；
实时流是给盯着面板的人看的。

### 安装

```sh
git clone https://github.com/Tristan747-d/DSH-Computer-Use.git
cd DSH-Computer-Use
./build-app.sh --install
```

然后往 `~/.dsh/profiles/web/cordis.patch.yml` 里加两条：

```yaml
- insert:
    - id: mcp-computer-use
      name: '@deepseek-ai/dsh-mcp-client'
      config:
        serverName: computer
        transport: stdio
        command: !!js process.env.HOME + '/Applications/dsh-cua.app/Contents/MacOS/dsh-cua'
        args: ['mcp']
        toolCallTimeoutMs: 120000
        failOnStartupError: false
        reconnect:
          enabled: true

    - id: computer-use-panel
      name: 'dsh-computer-use-panel'
```

再把面板插件装进 profile：

```sh
cd ~/.dsh/profiles/web
pnpm add link:$HOME/Desktop/DSH-Computer-Use/plugin
```

把 `skill/SKILL.md` 复制到 `~/.dsh/skills/computer-use/SKILL.md`，让 agent 知道怎么用这些工具。
然后重启 DSH。侧边栏会出现一个显示器图标，agent 会多出一批新工具。

### 权限

需要两项 macOS 权限。**辅助功能是必需的**，屏幕录制是可选的。

| 权限 | 用途 | 没有它时会怎样 |
|---|---|---|
| **辅助功能** | 所有工具 | 全都用不了 |
| **屏幕录制** | 只影响实时画面 | 其余功能照常工作 |

在 **系统设置 → 隐私与安全性** 里授予。也可以用内置的检查器：

```sh
~/Applications/dsh-cua.app/Contents/MacOS/dsh-cua doctor
```

> **重要：** 授权是绑定在签名后的 app 上的，而且**全机只能存在一份这个 app**。
> 如果你留了多余的副本，macOS 无法判断你授权的到底是哪一个，授权就会静默失效。
> `build-app.sh` 会自动清理竞争副本。

### 快速验证

```sh
swift run cua-selftest TextEdit
```

它会真的驱动一个 app，并逐层汇报：权限、app 解析、辅助功能树、diff 引擎、截图、按键映射。

### 已知限制

- **辅助功能树可能不完整。** 画布、游戏、部分 Electron app 暴露的元素很少甚至没有。
  这时只能靠截图 + 坐标点击，精度会下降。附带的 skill 会教 agent 识别这种情况并换策略，
  而不是原地乱试。
- **近期的 macOS 上，屏幕录制权限可能对"从终端启动的 app"不可用**（从
  Finder/LaunchServices 启动的才正常）。除实时画面外，其余功能不受影响。
- **用本工具时不要跑性能基准测试。** UI 自动化会持续占用 CPU 和 GPU，
  同一台机器上跑的任何性能测量都会被污染。
- **`type_text` 遇到 `\n` 会按下 Return。** 在聊天框或表单里，这意味着发送而不是换行。

---

## 给开发者

### 架构

```
DSH（web profile）
  ├─ @deepseek-ai/dsh-mcp-client             stdio
  │    └─ dsh-cua.app/Contents/MacOS/dsh-cua mcp
  │         ├─ AXBridge          AX 树遍历 · 元素注册表 · diff
  │         ├─ ActionBridge      CGEvent 输入 · AX 动作 · 截图
  │         ├─ StateBroadcaster  面板用的实时状态
  │         └─ MCPServer         stdio 上手写的 JSON-RPC 2.0
  │
  └─ dsh-computer-use-panel
       ├─ lib/index.js   宿主侧：/api/computer-use/* 路由
       └─ lib/client.js  客户端侧：侧边栏条目 + 中央面板
```

两半通过一个文件对接：

```
dsh-cua ──写入──> ~/.dsh-cua/<pid>.json + viewport.png
                              │
        宿主侧 ───────────────┘ 读取并供接口返回
                              │
        客户端侧 ─────────────┘ 每秒轮询并渲染
```

### 版本记录

**v2.1** —— 实时视频

- **面板里的实时视频。** `start_live_view` / `stop_live_view` / `live_view_status`
  以 10 fps 通过回环 MJPEG 推流目标窗口。ScreenCaptureKit 能抓取*后台*窗口，
  所以被观察的 app 永远不会被抬起。见上文"实时视频"。

**v2.0** —— 默认静默

- **再也不会抢焦点。** 动作被直接投递到目标进程 —— 走辅助功能 API 和
  `CGEvent.postToPid()` —— 而不是在系统 HID 层合成。旧代码每个动作前都要调
  `activate()`，因为那是合成一次*点击*的唯一办法；AX 命中测试消除了这个必要。
- **坐标点击改为 AX 命中测试 + `AXPress`**，**滚动改为写 `AXScrollBar` 的值**
  （写入后会回读校验）。实测（不是推测）表明：原始的 `postToPid` 鼠标点击、
  滚轮事件和 Command 组合键会被 macOS 对后台 app **静默丢弃**，所以代码不依赖它们。
- **`type_text` 不再碰剪贴板。** 它通过 `postToPid` 注入 Unicode：
  CJK 安全、不会覆盖粘贴板，1200 字符约 1.4 s。
- **`clipboard_copy` 不再发 Cmd+C。** 它读 `AXSelectedText`，用户的粘贴板永远不受打扰。
- **没有 `AXShowMenu` 时，右键/中键会明确报错**，而不是悄悄执行一次左键
  （那会触发完全不同的动作）。
- **`allow_foreground: true`** 是抢焦点 HID 兜底的显式开关；
  每个返回结果都会说明实际走的是哪条投递路径。
- **`cua-selftest` 现在会断言静默性**：它在每个动作前后记录最前台 app，
  一旦发生变化就判定失败。

**v0.2** —— 菜单、悬停、多窗口、降级阶梯

- **多窗口 `get_app_state`。** 一个 app 的所有 AX 窗口会渲染进同一棵树
  （索引跨窗口连续），所以非模态对话框也能看见并点击 —— 例如 Lightroom 聚焦
  Library 时的导入对话框。打开的**菜单栏**会作为额外的根节点，
  因此不在任何窗口内的菜单项（插件菜单）也能按元素索引寻址。
- **`move_mouse` 工具。** 悬停而不点击。macOS 在悬停时展开子菜单，
  但点击父级菜单项是"激活并关闭"它 —— 下钻嵌套菜单只有悬停这一条路。
- **`AGENT_PROMPT.md`。** 给任意 agent 的自包含简报：能力、启用方式、操作纪律。
  可作为首条消息粘贴，也可作为 skill 上下文注入。
- **实测的降级阶梯**（在 `skill/SKILL.md` 里），用于 AX 树很浅或缺失的 app，
  已在 macOS 27 上验证：

  | 层级 | 实测例子 | 策略 |
  |---|---|---|
  | 完整树 | Finder（631 节点）、QQ（1936） | 正常走 `element_index` |
  | 树很浅但窗口可见 | Notion（约 400）、微信（213 节点、0 个 AXWebArea，但有 5 个窗口 + 163 个菜单项） | 坐标 + **菜单栏**（永远可靠） |
  | 完全没有窗口 | 测过一个 debug 构建 | 菜单 + 盲打键盘导航；不如直接问用户，别空转 |

  macOS 27 实测：`AXManualAccessibility` 在 Notion 上设置成功但树不会变多；
  微信则两个解锁开关都拒绝（-25205）。永远别依赖它们 —— 试一次，立刻回退。

**v0.1** —— 首发：11 个工具、签名 `.app` 打包、实时侧边栏面板、
按进程的状态文件、agent skill。

### 设计取舍

**用 Swift，不用 JXA。** `System Events` 是通过 AppleEvent 往返读取 AX 树的：
慢、有损，而且拿不到所有属性。直接调 `AXUIElement` 才能拿到完整树和
`AXUIElementPerformAction`。

**手写 MCP，不用 SDK。** 需要的协议子集很小，而且自己写能保证正确回显 request id。
官方那个二进制会把整数请求（`1`）回显成**字符串** id（`"1"`），
这会弄坏普通的 MCP 客户端。

**以签名 `.app` 形式分发。** TCC 把授权绑定到代码签名需求上。
ad-hoc 签名绑定的是 CDHash，所以每次重新构建都会静默吊销授权。
Apple Development 证书绑定的是 bundle id + 证书 CN。

**按进程的状态文件。** DSH 持有一个长生命周期的 MCP 子进程，但也会派生短生命周期的。
每个发布者各写 `<pid>.json`；宿主侧负责合并并汇报最新的心跳。
一个正在死掉的会话永远无法把 `connected: false` 盖到活着的兄弟进程上。

**靠超时判死，不靠信号。** 被 kill 而没走清理逻辑的进程永远不会写 disconnect。
宿主侧把心跳超过 15 s 的视为已消失。

### 构建

```sh
./build-app.sh              # 构建 → 签名 → 校验
./build-app.sh --install    # ……并安装到 ~/Applications
```

`codesign --verify --deep --strict` 不通过时脚本会硬失败。
可用 `DSH_CUA_SIGN_ID=<hash>` 指定另一张证书。

### 本仓库记录的坑

下面每一条都花了真实的调试时间。记在这里，是为了让下一个人少花几小时、只花几分钟。

**签名与 TCC**

| 坑 | 现象 | 修法 |
|---|---|---|
| 用 JSON 写 `Info.plist` | `codesign` 报误导性的 `does not satisfy its Designated Requirement`；app 起来后报 "error 162" | Info.plist 必须是 XML |
| `CFBundleExecutable` 与二进制文件名不一致 | 静默启动失败 | 两者必须完全一致 |
| iCloud Drive + `codesign` | `resource fork, Finder information, or similar detritus not allowed` —— fileprovider 会在 `xattr -cr` 和 `codesign` *之间*重新贴上 `com.apple.FinderInfo` | 在 `/tmp` 里组装 `.app`，再安装 |
| 同一个 bundle id 存在多份 | 屏幕录制授权静默失效 | 全机只保留一份；`build-app.sh` 会强制这点 |

**DSH 插件系统**

| 坑 | 现象 | 修法 |
|---|---|---|
| 宿主侧和 `/client` 都声明成 loader 行 | `Error: plugin tree failed to load: window is not defined` —— Node 把浏览器 bundle 也 import 了 | 只声明一条；`dsh.client` 会把浏览器 bundle 放进 boot graph |
| 服务名大小写 | 路由注册静默失效 | 是 `ctx.webServer`（大写 S） |
| 拿 translator | `ctx.locale.resolve()` 不是这个 API | `const t = ctx.locale.bind(ns)`；通过 `inject: () => ({ t })` 传下去 |
| 用 `file:` 依赖 | 改插件源码没效果 —— pnpm 是*拷贝* | 用 `link:`，让 profile 直接读你的源码 |
| 改了客户端 bundle | 不生效 | 重启 DSH（boot graph 在启动时就固定了） |

**macOS API**

| 坑 | 现象 | 修法 |
|---|---|---|
| `CGWindowListCreateImage` | 在当前 SDK 里被标记为不可用 | 迁到 ScreenCaptureKit |
| 用 PID 存活性来清理文件 | PID 会被复用 —— 可能删掉活着兄弟进程的文件 | 按文件时间清理，绝不用 `kill(pid, 0)` |

### 数据契约

`~/.dsh-cua/<pid>.json`：

```jsonc
{
  "connected": true,
  "busy": false,              // 6 秒内有过动作
  "pid": 12345,
  "updatedAt": 1789794972786, // ms 时间戳；宿主侧判断存活的依据
  "accessibility": true,
  "screenRecording": false,
  "app": "TextEdit",
  "elementCount": 21,
  "window": { "x": 146, "y": 71, "width": 656, "height": 422 },
  "screenshotAt": 1789794972700,
  "screenshotUrl": "/api/computer-use/viewport.png?t=1789794972700",
  "recentActions": [
    { "at": 1789794972775, "tool": "get_app_state",
      "text": "读取 TextEdit 的界面状态", "error": false }
  ]
}
```

### 客户端插件说明

面板注册两个槽位：

| 槽位 | 类型 | 用途 |
|---|---|---|
| `sidebar.panellist` | list | 侧边栏条目；它的 `id` 同时是主槽位的 key |
| `main` | keyed | `computer-use` 键下的中央面板 |

文案走 thunk，所以切换语言不需要重新注册。宿主侧的设计是防御式的：
文件缺失、JSON 损坏、发布者死掉，都会退化成渲染一个"未连接"状态，
而不是整个挂载崩掉。

### 仓库结构

```
.
├── Package.swift
├── build-app.sh                  # 构建 → 签名 → 校验 → 安装
├── Sources/
│   ├── CUACore/
│   │   ├── AXBridge.swift        # AX 树、元素注册表、diff
│   │   ├── ActionBridge.swift    # CGEvent 输入、AX 动作、截图
│   │   ├── StateBroadcaster.swift# 面板用的实时状态
│   │   └── MCPServer.swift       # stdio JSON-RPC，工具 schema
│   ├── dsh-cua/main.swift        # mcp | doctor | request-perms
│   └── cua-selftest/main.swift   # 真实 app 验证
├── plugin/
│   ├── lib/index.js              # 宿主侧：路由
│   ├── lib/client.js             # 客户端侧：UI
│   └── package.json              # dsh.client 声明
└── skill/SKILL.md                # 教 agent 用好这些工具
```

---

## 参与贡献

上面的"坑"表格是本仓库最值钱的部分。如果你踩到新坑，请加一行 ——
带上**完整的报错原文**，这样别人才能 grep 到。

## License

MIT —— 见 [LICENSE](LICENSE)。
