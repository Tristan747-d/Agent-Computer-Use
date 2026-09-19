# dsh-computer-use-panel

The DSH sidebar panel for Computer Use: a live view of what the agent is doing
on screen — the last window frame, the target app, window geometry, element
count, and a timestamped action log.

This is the UI half of `dsh-computer-use`. The Swift MCP server does the actual
work; this plugin only *shows* it.

## What you see

A **sidebar entry** (monitor glyph, order 50) that opens a **centre panel**:

```
┌─────────────────────────────────────────────┐
│ ● Computer Use                    [暂停][刷新] │
│   运行中 / 空闲 / 未连接 / 缺少辅助功能权限      │
├─────────────────────────────────────────────┤
│                                             │
│         < live window frame >      1470×923 │
│                                             │
├─────────────────────────────────────────────┤
│ 目标 app: Finder          元素: 235          │
│ 窗口: 1470×923            更新于: 13:07:42   │
│ 最近动作                                    │
│   13:07:42  读取 Finder 的界面状态           │
│   13:07:40  列出运行中的 app                 │
└─────────────────────────────────────────────┘
```

The header dot encodes state: grey (disconnected), green pulsing (working),
red (Accessibility permission missing). It polls once per second and can be
paused.

## Architecture

Two halves in one package, joined by a file:

```
dsh-cua (Swift, MCP)                 this plugin
  ├─ records every tool call   ──┐
  └─ writes get_app_state frames │
                                 ▼
                    ~/.dsh-cua/state.json
                    ~/.dsh-cua/viewport.png
                                 │
        host half  ──────────────┘
        GET /api/computer-use/state
        GET /api/computer-use/viewport.png
                                 │
        client half ─────────────┘  polls, renders
```

**Why a file and not a socket.** The MCP server owns stdout for JSON-RPC, so it
cannot also serve HTTP. Writing two files is the least invasive bridge and keeps
the two halves independently restartable. Writes are atomic (temp + rename), so
the reader never sees a half-written document.

**Why the panel detects death by staleness.** A process killed mid-session never
gets to write `connected: false`. The host half treats a heartbeat older than
15 s as disconnected, which is what actually catches a crashed publisher.

## Slots used

| Slot | Kind | Purpose |
|---|---|---|
| `sidebar.panellist` | list | The sidebar entry. Its `id` is also the main-slot key. |
| `main` | keyed | The centre panel, registered under key `computer-use`. |

Selecting the sidebar row navigates to the panel via `ctx.layout.selectPanel`,
which the sidebar shell does itself from the shared `id`.

## Two traps this package documents

**Declare ONE loader row, not two.** The `dsh.client` declaration in
`package.json` is what puts the browser bundle into the boot graph. Also
declaring `dsh-computer-use-panel/client` as a loader row makes Node import it,
where `window` is undefined, and the whole plugin tree fails to boot:

```
Error: plugin tree failed to load: window is not defined
```

**`ctx.webServer`, not `ctx.webserver`.** The service name is capital-S; the
inject list must match `["webServer"]`.

## Configuration

Registered in `~/.dsh/profiles/web/cordis.patch.yml`:

```yaml
- insert:
    - id: computer-use-panel
      name: 'dsh-computer-use-panel'
```

Installed into the profile as a `file:` dependency, so local edits are picked up
on the next boot — no publishing needed.

## Failure behavior

The panel is defensive by design. Missing file, malformed JSON, or a dead
publisher all degrade to a rendered "未连接" state rather than a broken mount.
A missing viewport returns 404 and the panel shows the permission hint instead
of a broken image.

## Rebuild

```sh
cd ~/.dsh/profiles/web && pnpm install     # after changing package.json
# then restart DSH (the client bundle is served from the profile's node_modules)
```

Client-bundle changes need a DSH restart unless `pnpm run dev:web` is watching
from the DSH source checkout.
