# DSH Computer Use

**Self-built macOS Computer Use for [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness) — no Codex, no OpenAI, no vendor service.**

Give your DSH agent eyes and hands on your Mac: it reads any app's accessibility
tree, clicks, types, scrolls, and drags — and you watch it happen in a live
sidebar panel inside DSH.

> 中文版（Chinese version）：[README.md](README.md)

```
┌─────────────────────────────────────────────┐
│ ● Computer Use                    [暂停][刷新] │
│   运行中                                      │
├─────────────────────────────────────────────┤
│                                             │
│         < live window frame >      1470×923 │
│                                             │
├─────────────────────────────────────────────┤
│ 目标 app: Finder          元素: 235          │
│ 窗口: 1470×923            更新于: 13:07:42   │
│ 最近动作                                     │
│   13:07:42  读取 Finder 的界面状态            │
│   13:07:40  列出运行中的 app                  │
└─────────────────────────────────────────────┘
```

---

## For Customers

You want your DSH agent to actually *operate* your Mac — open an app, fill a
form, click a button, read what's on screen. This gives it that.

### Why this exists

macOS's only turnkey Computer Use was Codex's `SkyComputerUseClient`. It is a
real MCP server and it *does* handshake outside Codex — but every action fails:

```
Computer Use server error -10000: Sender process is not authenticated
```

That binary validates the caller's **code-signing identity** through the macOS
audit token and requires OpenAI's Team ID. No other client can pass. So this
project replaces it outright with a clean-room implementation.

### What it can do

| Tool | What it does |
|---|---|
| `list_apps` | List running apps |
| `get_app_state` | Read the app's UI (accessibility tree + screenshot) |
| `click` | Click a button, link, or menu item |
| `set_value` | Fill a text field directly |
| `select_text` | Select or position the cursor in text |
| `press_key` | Keyboard shortcuts (`Cmd+S`, `Return`, arrows…) |
| `type_text` | Type text — Chinese, emoji, anything |
| `scroll` | Scroll a list or page |
| `drag` | Drag and drop |
| `move_mouse` | Hover without clicking — how you get down a nested menu |
| `perform_secondary_action` | Trigger menu items and other extra actions |
| `clipboard_copy` | Copy and read the selection |
| `start_live_view` | Start a **live video** of an app's window (background-safe) |
| `stop_live_view` | Stop the live video |
| `live_view_status` | Report streaming stats and the stream URL |

Your agent calls these automatically when a task needs GUI work. There is a
skill bundled that teaches it *how* to use them well, including the one rule
that matters most: **re-read the app state after every action**, because
element indices go stale the moment anything changes.

### Live video

The sidebar panel shows a **continuous video** of whatever window the agent is
working on — not a slideshow of stills.

Under the hood: **ScreenCaptureKit** captures the target window (a specific
window, not the whole display), frames are JPEG-encoded once, and they are
fanned out to every viewer as `multipart/x-mixed-replace` MJPEG. A plain
`<img>` renders that natively — no decoder, no WebSocket, no JS library — and
because the encode happens once per frame, ten viewers cost exactly one encode.

Measured on this machine: **10 fps sustained**, ~130 KB per frame at 1600 px on
the long edge, and — the part that matters — **the captured window is never
brought to the front**. ScreenCaptureKit can capture a background window, so the
silence contract survives: you can keep working in another app while watching
the agent work.

The stream is served on an ephemeral **loopback-only** port (`127.0.0.1`), so it
is never reachable off the machine. It stops when the session ends, or on
`stop_live_view`.

**The panel never films itself.** Pointing the stream at the surface that renders
the panel would nest the image inside itself forever. The server refuses to
capture a window that is showing the DSH interface — detected from the window
title, the DSH webserver URL, the DSH bundle id, or a `com.apple.Safari.WebApp.*`
bundle (which is how the DSH desktop wrapper is packaged), and the refusal names
the reason. The check is per *window*, not per app, so streaming a different
Safari tab still works. It is enforced on both paths: the explicit
`start_live_view` call and the automatic follow that `get_app_state` triggers.

`get_app_state` still returns a single still alongside the accessibility tree for
the model's own use; the live stream is for the human watching the panel.

### Install

```sh
git clone https://github.com/Tristan747-d/DSH-Computer-Use.git
cd DSH-Computer-Use
./build-app.sh --install
```

Then add two rows to `~/.dsh/profiles/web/cordis.patch.yml`:

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

And install the panel plugin into the profile:

```sh
cd ~/.dsh/profiles/web
pnpm add link:$HOME/Desktop/DSH-Computer-Use/plugin
```

Copy `skill/SKILL.md` into `~/.dsh/skills/computer-use/SKILL.md` so the agent
knows how to use the tools. Then restart DSH. The sidebar gets a monitor icon;
the agent gets 11 new tools.

### Permissions

Two macOS permissions. **Accessibility is required**; Screen Recording is
optional.

| Permission | Needed for | Status without it |
|---|---|---|
| **Accessibility** | Every tool | Nothing works |
| **Screen Recording** | The live screen image only | Everything else still works |

Grant in **System Settings → Privacy & Security**. Use the built-in checker:

```sh
~/Applications/dsh-cua.app/Contents/MacOS/dsh-cua doctor
```

> **Important:** grants attach to the signed app, and **only one copy of the
> app may exist**. If you keep extra copies around, macOS cannot decide which
> one you authorized and the grant silently fails to apply. `build-app.sh`
> removes competing copies automatically.

### Quick test

**Ask whether an app is drivable first** — one cheap command, far cheaper than
a full tree dump:

```sh
~/Applications/dsh-cua.app/Contents/MacOS/dsh-cua probe-app "Notion"
# Framework: Electron (Chromium)    Elements: 353
# STRATEGY TIER: L1_full_tree

~/Applications/dsh-cua.app/Contents/MacOS/dsh-cua verify Notion
# 🟩 V3 PASS — Notion: Electron, tier L1_full_tree, 354 nodes, silent actuation OK
```

`verify` is the end-to-end self-check: it presses a real control and proves the
target app was **never brought to the front**.

**Permissions are on but nothing works?** Check TCC attribution first:

```sh
~/Applications/dsh-cua.app/Contents/MacOS/dsh-cua doctor
# TCC responsible process : self (this binary) — grants apply to this app
# Self-responsible        : yes
```

If that line names a parent process such as `DSH Launcher`, the grant is being
recorded against someone else. `dsh-cua` fixes this itself (see "v3.0" in the
changelog) — you do not need to change anything in System Settings.

The older self-test still works: `swift run cua-selftest TextEdit`.

### Known limitations

- **Self-drawn controls and canvas content are never in the AX tree.** Canvas
  surfaces, games, and self-drawn UIs (WeChat, measured at 16 nodes) expose
  their content as pixels, not controls. No AX-based approach can reach them;
  screenshots plus coordinate clicks are the only route. That is an
  architectural boundary, not a bug.
- **Electron and WebUI are no longer a limitation** (since v3.0), but some apps
  still land in L2: the tree is thin and only coordinates plus the menu bar
  work. Ask `probe_app` first — don't guess.
- **When `probe_app` says "did not grow", stop retrying.** It means Chromium
  accessibility mode was requested and the tree did not respond; go to L2.
- **Screen Recording may be unavailable on recent macOS** for apps launched
  from a terminal rather than from Finder/LaunchServices. Everything except
  the live image keeps working.
- **Don't benchmark while using this.** UI automation holds CPU and GPU
  continuously, which will corrupt any performance measurement you run on the
  same machine.
- **`type_text` presses Return on `\n`.** In a chat box or form, that sends
  rather than inserting a newline.

---

## For Developers

### Architecture

```
DSH (web profile)
  ├─ @deepseek-ai/dsh-mcp-client             stdio
  │    └─ dsh-cua.app/Contents/MacOS/dsh-cua mcp
  │         ├─ AXBridge         AX tree walk · element registry · diffing
  │         ├─ ActionBridge     CGEvent input · AX actions · capture
  │         ├─ StateBroadcaster live state for the panel
  │         └─ MCPServer        hand-written JSON-RPC 2.0 over stdio
  │
  └─ dsh-computer-use-panel
       ├─ lib/index.js   host half: /api/computer-use/* routes
       └─ lib/client.js  client half: sidebar entry + centre panel
```

Two halves joined by a file:

```
dsh-cua ──writes──> ~/.dsh-cua/<pid>.json + viewport.png
                              │
        host half ────────────┘ reads, serves
                              │
        client half ──────────┘ polls 1s, renders
```

### Changelog

**v2.1** — live video

- **Live video in the panel.** `start_live_view` / `stop_live_view` /
  `live_view_status` stream the target window at 10 fps over loopback MJPEG.
  ScreenCaptureKit captures a *background* window, so the app under observation
  is never raised. See "Live video" above.

**v2.0** — silent by default

- **Nothing steals focus any more.** Actions are delivered straight to the
  target process — Accessibility API calls and `CGEvent.postToPid()` — instead
  of being synthesized at the system HID tap. The old code called `activate()`
  before every action because that was the only way to synthesize a *click*;
  the AX hit test removed that need.
- **Coordinate clicks are now AX hit-test + `AXPress`**, and **scrolling writes
  the `AXScrollBar` value** (verified after the write). Raw `postToPid` mouse
  clicks, wheel events and Command shortcuts are silently *dropped* by macOS for
  background apps — measured, not assumed — so the code does not rely on them.
- **`type_text` no longer touches the clipboard.** It injects Unicode via
  `postToPid`: CJK-safe, no pasteboard clobbering, ~1.4 s for 1200 characters.
- **`clipboard_copy` no longer sends Cmd+C.** It reads `AXSelectedText`, so the
  user's pasteboard is never disturbed.
- **Right/middle clicks fail loudly** when no `AXShowMenu` exists, instead of
  quietly performing a left click (which would run a different action).
- **`allow_foreground: true`** is the explicit opt-in for a focus-stealing HID
  fallback; every result reports which delivery path was used.
- **`cua-selftest` now asserts silence**: it records the frontmost app before
  and after each action and fails if it ever changed.

**v0.2** — menus, hover, multi-window, and the degradation ladder

- **Multi-window `get_app_state`.** All of an app's AX windows are rendered
  into one tree (indices are continuous across windows), so non-modal dialogs
  are visible and clickable — e.g. Lightroom's import dialog while the Library
  is focused. The open **menu bar** becomes an extra root, so menu items
  outside any window (plug-in menus) are addressable by element index.
- **`move_mouse` tool.** Hover without clicking. macOS opens a submenu on
  hover, but clicking the parent item activates-and-closes it — hover is the
  only way down a nested menu.
- **`AGENT_PROMPT.md`.** A self-contained briefing for any agent:
  capabilities, enablement, and operating discipline. Paste it as a first
  message or inject it as skill context.
- **Strategy tiers decided by tree content, not by framework.** `probe_app`
  tells you which tier an app is in before you decide how to drive it:

  | Tier | Decided by | Strategy |
  |---|---|---|
  | `L1_full_tree` | ≥12 controls and ≥60 nodes, or an AXWebArea with ≥400 chars of visible text | Normal `element_index` + `AXPress` |
  | `L2_shallow_tree` | Thin tree, but the window server sees a window | Coordinates + **menu bar** (always reliable) |
  | `L3_no_windows` | No window from either source | Menus + blind keyboard nav; ask the user rather than spin |

  **Why content and not framework.** The earlier ladder guessed from "is this
  Electron", and the guess was backwards: Electron and WebUI surfaces are the
  *richest* trees here (DSH Launcher 1542 nodes, Notion 354). What decides
  drivability is what is in the tree, not what the app was written in.

- **`probe_app` tool.** One cheap call answers "what is this app, and can I use
  `element_index` on it?" before you spend a full `get_app_state`.

**v3.0** — Electron and WebUI broken through. The root cause was never the
framework; it was TCC attribution. `dsh-cua` is spawned by DSH Launcher, and
macOS records the whole process tree's Accessibility grant against the
**parent**, whose own TCC row was `denied` — so AX was dead everywhere (it
looked like "permission is on but every app returns one `Unknown` element").
The fix is `TCCResponsibility.reexecIfNeeded()`, which re-execs via
`responsibility_spawnattrs_setdisclaim` so the process is its own responsible
process. Adds `TCC responsible process` / `Self-responsible` to
`dsh-cua doctor`, plus `dsh-cua responsibility` and `dsh-cua verify <app>`.

  **Measured (macOS 27; all silent — frontmost app never changed, `AXPress`
  delivered straight to the target process):**

  | App | Framework | Nodes | Tier | Control pressed |
  |---|---|---|---|---|
  | DSH Launcher | WebKit / WKWebView | 1542 | L1 | 新建会话 |
  | Notion | Electron | 354 | L1 | 关闭侧边栏 |
  | Canva | Electron | 192 | L1 | 首页标签 |
  | GenOffice | Electron | 181 | L1 | 新建标签页 |
  | WorkBuddy AI | Electron | 175 | L1 | Collapse sidebar |
  | QQ | Native AppKit | 126 | L1 | 关闭图片查看器 |
  | Finder | Native AppKit | 26 | L2 | — |

  Reproduce with one command: `dsh-cua verify <app>`.

**v0.1** — initial release: 11 tools, signed `.app` packaging, live sidebar
panel, per-process state files, agent skill.

### Design decisions

**Swift, not JXA.** `System Events` reads the AX tree through an AppleEvent
round-trip: slow, lossy, and it cannot reach every attribute. Direct
`AXUIElement` calls give the complete tree and `AXUIElementPerformAction`.

**Hand-written MCP, no SDK.** The needed protocol subset is small, and it
guarantees correct request-id echo. The official binary returns **string** ids
(`"1"`) for integer requests (`1`), which breaks ordinary MCP clients.

**Shipped as a signed `.app`.** TCC binds grants to the code-signing
requirement. Ad-hoc signing binds the CDHash, so every rebuild silently revokes
the grant. An Apple Development certificate binds bundle id + cert CN.

**Per-process state files.** DSH holds one long-lived MCP child but also spawns
short-lived ones. Each publisher owns `<pid>.json`; the host half merges and
reports the freshest heartbeat. A dying session can never stamp
`connected: false` over a live sibling.

**Death by staleness, not by signal.** A process killed without cleanup never
writes a disconnect. The host half treats a heartbeat older than 15 s as gone.

### Building

```sh
./build-app.sh              # build, sign, verify
./build-app.sh --install    # ...and install to ~/Applications
```

The script hard-fails if `codesign --verify --deep --strict` does not pass.
Set `DSH_CUA_SIGN_ID=<hash>` to use a different certificate.

### Traps this codebase documents

Every one of these cost real debugging time. They are recorded here so the next
person loses minutes instead of hours.

**Signing and TCC**

| Trap | Symptom | Fix |
|---|---|---|
| JSON `Info.plist` | `codesign` reports the misleading `does not satisfy its Designated Requirement`; app dies with "error 162" | Info.plist must be XML |
| `CFBundleExecutable` ≠ binary filename | Silent launch failure | Keep them identical |
| iCloud Drive + `codesign` | `resource fork, Finder information, or similar detritus not allowed` — fileprovider re-applies `com.apple.FinderInfo` *between* `xattr -cr` and `codesign` | Assemble the `.app` in `/tmp`, then install |
| Multiple copies of one bundle id | Screen Recording grant silently fails to attach | Ship exactly one; `build-app.sh` enforces it |

**DSH plugin system**

| Trap | Symptom | Fix |
|---|---|---|
| Declaring both host and `/client` as loader rows | `Error: plugin tree failed to load: window is not defined` — Node imports the browser bundle | Declare ONE row; `dsh.client` puts the browser bundle in the boot graph |
| Service name casing | Route registration silently absent | It is `ctx.webServer` (capital S) |
| Getting a translator | `ctx.locale.resolve()` is not the API | `const t = ctx.locale.bind(ns)`; pass it via `inject: () => ({ t })` |
| `file:` dependency | Edits to plugin source have no effect — pnpm *copies* | Use `link:` so the profile reads your source directly |
| Client bundle changes | Not picked up | Restart DSH (boot graph is fixed at startup) |

**macOS APIs**

| Trap | Symptom | Fix |
|---|---|---|
| `CGWindowListCreateImage` | Marked unavailable in current SDKs | Migrate to ScreenCaptureKit |
| PID-based liveness for file cleanup | PIDs are recycled — a live sibling's file can be deleted | Prune by file age, never by `kill(pid, 0)` |

### Data contract

`~/.dsh-cua/<pid>.json`:

```jsonc
{
  "connected": true,
  "busy": false,              // an action within the last 6s
  "pid": 12345,
  "updatedAt": 1789794972786, // ms epoch; the host half's staleness signal
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

### Client plugin notes

The panel registers two slots:

| Slot | Kind | Purpose |
|---|---|---|
| `sidebar.panellist` | list | The sidebar entry; its `id` is also the main-slot key |
| `main` | keyed | The centre panel under key `computer-use` |

Copy is thunked so a language change needs no re-registration. The host half is
defensive by design: a missing file, malformed JSON, or a dead publisher all
degrade to a rendered "disconnected" state rather than a broken mount.

### Repository layout

```
.
├── Package.swift
├── build-app.sh                  # build → sign → verify → install
├── Sources/
│   ├── CUACore/
│   │   ├── AXBridge.swift        # AX tree, element registry, diffing
│   │   ├── ActionBridge.swift    # CGEvent input, AX actions, capture
│   │   ├── StateBroadcaster.swift# live state for the panel
│   │   └── MCPServer.swift       # JSON-RPC over stdio, 11 tool schemas
│   ├── dsh-cua/main.swift        # mcp | doctor | request-perms
│   └── cua-selftest/main.swift   # live-app verification
├── plugin/
│   ├── lib/index.js              # host half: routes
│   ├── lib/client.js             # client half: UI
│   └── package.json              # dsh.client declaration
└── skill/SKILL.md                # teaches the agent to use the tools well
```

### Contributing

The traps tables above are the most valuable part of this repo. If you hit a
new one, add a row — with the exact symptom text, so it is greppable.

## License

MIT — see [LICENSE](LICENSE).
