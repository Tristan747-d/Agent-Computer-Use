#!/bin/bash
# Install Agent Computer Use into one or more agent hosts.
#
# The binary is host-agnostic: it speaks MCP over stdio. What differs per host
# is only *where the config lives* and *how tools are named*, so this script
# builds once and then wires the same binary into whatever you pick.
#
# Interactive (default, when stdin is a terminal):
#   ./install.sh
#
# Non-interactive (CI, pipes, or when you already know what you want):
#   ./install.sh --host dsh
#   ./install.sh --host openclaw --host hermes
#   ./install.sh --all --yes
#
# Keys in the TUI: ↑/↓ move · space toggle · a all · n none · enter install · q quit

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_PATH="${HOME}/Applications/Agent Computer Use.app"
# Prefer the canonical new path; fall back to the legacy alias so an older
# checkout still installs cleanly.
if [ -x "${APP_PATH}/Contents/MacOS/agent-cua" ]; then
    BIN="${APP_PATH}/Contents/MacOS/agent-cua"
else
    BIN="${HOME}/Applications/dsh-cua.app/Contents/MacOS/dsh-cua"
fi

# --- Name migration (backward compatibility) -------------------------------
# Renamed to Agent-Computer-Use, but the *bundle id* deliberately stays
# com.tristan.dsh.computeruse: macOS TCC keys Accessibility and Screen
# Recording grants by bundle identity (it is pinned in the designated
# requirement), so changing it would silently revoke every user's existing
# grant and force manual re-authorization. The name changes; the identity
# macOS already trusts does not.
BUNDLE_ID="com.tristan.dsh.computeruse"

WANT_DSH=0
WANT_OPENCLAW=0
WANT_HERMES=0
FORCE_ALL=0
ASSUME_YES=0
NO_TUI=0

# --- Output helpers ---------------------------------------------------------
if [ -t 1 ]; then
    B=$'\033[1m'; DIM=$'\033[2m'; GRN=$'\033[32m'; YEL=$'\033[33m'
    RED=$'\033[31m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
    B=""; DIM=""; GRN=""; YEL=""; RED=""; CYN=""; RST=""
fi
log()  { printf '%s==>%s %s\n' "${B}" "${RST}" "$*"; }
ok()   { printf '  %s✓%s %s\n' "${GRN}" "${RST}" "$*"; }
skip() { printf '  %s-%s %s\n' "${YEL}" "${RST}" "$*"; }
die()  { printf '  %s✗%s %s\n' "${RED}" "${RST}" "$*" >&2; exit 1; }

# --- Args -------------------------------------------------------------------
NONINTERACTIVE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --host)
            NONINTERACTIVE=1
            case "${2:-}" in
                dsh)      WANT_DSH=1 ;;
                openclaw) WANT_OPENCLAW=1 ;;
                hermes)   WANT_HERMES=1 ;;
                *) die "unknown host '${2:-}'. Use dsh, openclaw or hermes." ;;
            esac
            shift 2 ;;
        --all)      FORCE_ALL=1; NONINTERACTIVE=1; shift ;;
        --yes|-y)   ASSUME_YES=1; shift ;;
        --no-tui)   NO_TUI=1; NONINTERACTIVE=1; shift ;;
        -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown option '$1'" ;;
    esac
done

# --- Host discovery ---------------------------------------------------------
# Detect (is the host installed?) separately from status (is it already wired?).
# The TUI shows both, because "already configured" should be a visible default
# rather than a silent skip.
HOSTS=(DSH OpenClaw Hermes)
AVAIL=(0 0 0)
CONFIGURED=(0 0 0)
NOTES=("" "" "")

[ -d "${HOME}/.dsh" ] && AVAIL[0]=1
command -v openclaw >/dev/null 2>&1 && AVAIL[1]=1
command -v hermes   >/dev/null 2>&1 && AVAIL[2]=1

if [ "${AVAIL[0]}" = "1" ]; then
    [ -e "${HOME}/.dsh/profiles/web/node_modules/dsh-computer-use-panel" ] && CONFIGURED[0]=1
    NOTES[0]="sidebar panel + skill · mcp__computer__*"
fi
if [ "${AVAIL[1]}" = "1" ]; then
    openclaw mcp show dsh-computer-use >/dev/null 2>&1 && CONFIGURED[1]=1
    NOTES[1]="MCP server + skill · mcp__…"
fi
if [ "${AVAIL[2]}" = "1" ]; then
    hermes mcp list 2>/dev/null | grep -q "dsh-computer-use" && CONFIGURED[2]=1
    NOTES[2]="MCP server + skill · dsh-computer-use:<tool>"
fi

# --- TUI --------------------------------------------------------------------
# A checkbox menu is worth the code here because the whole point of this
# script is *choice*: which agents on this machine should get Computer Use.
# Defaults are honest — available hosts start checked, absent ones are shown
# dimmed and unselectable so nobody wonders why nothing happened.
SEL=(0 0 0)
for i in 0 1 2; do
    if [ "${AVAIL[$i]}" = "1" ]; then SEL[$i]=1; fi
done
CURSOR=0
MENU_LINES=7

paint_menu() {
    printf '%sWhere should Computer Use be installed?%s\n\n' "${B}" "${RST}"
    local i
    for i in 0 1 2; do
        local box mark line
        if [ "${SEL[$i]}" = "1" ]; then box="${GRN}[x]${RST}"; else box="[ ]"; fi
        if [ "${CURSOR}" = "$i" ]; then mark="${CYN}▸${RST}"; else mark=" "; fi
        if [ "${AVAIL[$i]}" = "1" ]; then
            local tag=""
            [ "${CONFIGURED[$i]}" = "1" ] && tag=" ${DIM}(already configured — will refresh)${RST}"
            line=$(printf '%s %s %-9s %s%s%s' "${mark}" "${box}" "${HOSTS[$i]}" \
                   "${DIM}" "${NOTES[$i]}" "${RST}")
            printf '%b%s\n' "${line}" "${tag}"
        else
            printf '%s %s %-9s %snot found on this machine%s\n' \
                "${mark}" "${DIM}[ ]${RST}" "${HOSTS[$i]}" "${DIM}" "${RST}"
        fi
    done
    printf '\n%s↑/↓ move · space toggle · a all · n none · enter install · q quit%s\n' "${DIM}" "${RST}"
}

run_tui() {
    # Hide the cursor and repaint in place; restore on every exit path.
    printf '\033[?25l'
    trap 'printf "\033[?25h"; exit 130' INT
    paint_menu
    while true; do
        local k
        if ! IFS= read -rsn1 k; then k=""; fi
        if [ "$k" = $'\033' ]; then
            local rest=""
            IFS= read -rsn2 -t 1 rest || true
            case "$rest" in
                '[A') [ "${CURSOR}" -gt 0 ] && CURSOR=$((CURSOR-1)) ;;
                '[B') [ "${CURSOR}" -lt 2 ] && CURSOR=$((CURSOR+1)) ;;
            esac
        else
            case "$k" in
                "") break ;;
                " ")
                    if [ "${AVAIL[$CURSOR]}" = "1" ]; then
                        if [ "${SEL[$CURSOR]}" = "1" ]; then SEL[$CURSOR]=0; else SEL[$CURSOR]=1; fi
                    fi ;;
                a|A) local i; for i in 0 1 2; do [ "${AVAIL[$i]}" = "1" ] && SEL[$i]=1; done ;;
                n|N) local i; for i in 0 1 2; do SEL[$i]=0; done ;;
                q|Q) printf '\033[%dA' "${MENU_LINES}"; printf '\033[?25h'; echo "Aborted."; exit 0 ;;
                "") break ;;
            esac
        fi
        printf '\033[%dA' "${MENU_LINES}"
        paint_menu
    done
    printf '\033[%dA' "${MENU_LINES}"
    local i; for i in $(seq 1 "${MENU_LINES}"); do printf '\033[2K\033[1B'; done
    printf '\033[%dA' "${MENU_LINES}"
    printf '\033[?25h'
    trap - INT

    WANT_DSH=${SEL[0]}; WANT_OPENCLAW=${SEL[1]}; WANT_HERMES=${SEL[2]}
}

if [ "${NONINTERACTIVE}" = "0" ]; then
    if [ "${NO_TUI}" = "1" ] || [ ! -t 0 ]; then
        NONINTERACTIVE=1   # no terminal to draw on; keep the old behaviour
    else
        printf '%sAgent Computer Use%s — installer\n\n' "${B}" "${RST}"
        run_tui
        if [ "${WANT_DSH}${WANT_OPENCLAW}${WANT_HERMES}" = "000" ]; then
            echo "Nothing selected — nothing to do."
            exit 0
        fi
    fi
fi
# Non-interactive with no --host: keep the historical behaviour of installing
# into every host that is present. Losing that would make `./install.sh </dev/null`
# silently do nothing, which is worse than useless.
if [ "${NONINTERACTIVE}" = "1" ] && [ "${WANT_DSH}${WANT_OPENCLAW}${WANT_HERMES}" = "000" ]; then
    WANT_DSH=${AVAIL[0]}; WANT_OPENCLAW=${AVAIL[1]}; WANT_HERMES=${AVAIL[2]}
fi

# --- Build -----------------------------------------------------------------
BUILD_LOG="$(mktemp -t agent-cua-build)"
log "Building signed .app ${DIM}(${BUNDLE_ID})${RST}"
cd "${PROJECT_DIR}"
if ./build-app.sh --install >"${BUILD_LOG}" 2>&1; then
    ok "built and installed"
else
    printf '%s\n' "${RED}build failed${RST} — last 20 lines of ${BUILD_LOG}:"
    tail -20 "${BUILD_LOG}"
    exit 1
fi
[ -x "${BIN}" ] || die "build produced no binary at ${BIN}"
ok "binary: ${BIN}"

# --- Installers -------------------------------------------------------------
install_dsh() {
    # DSH loads the sidebar panel as a pnpm-linked plugin; its MCP side finds
    # the binary by absolute path.
    local target="${HOME}/.dsh/profiles/web/node_modules/dsh-computer-use-panel"
    mkdir -p "$(dirname "${target}")"
    ln -sfn "${PROJECT_DIR}/plugin" "${target}"
    ok "panel linked -> ${target}"
    local skill="${HOME}/.dsh/skills/computer-use/SKILL.md"
    mkdir -p "$(dirname "${skill}")"
    cp "${PROJECT_DIR}/skill/SKILL.md" "${skill}"
    ok "skill -> ${skill}"
}

install_openclaw() {
    # `openclaw mcp add` probes before saving, so a broken binary fails here
    # rather than at first use.
    if openclaw mcp show dsh-computer-use >/dev/null 2>&1; then
        if openclaw mcp set dsh-computer-use --command "${BIN}" --arg mcp >/dev/null 2>&1; then
            ok "MCP server updated"
        else
            openclaw mcp add dsh-computer-use --command "${BIN}" --arg mcp --connect-timeout 30 >/dev/null 2>&1 \
                && ok "MCP server added" || die "openclaw mcp add failed"
        fi
    else
        openclaw mcp add dsh-computer-use --command "${BIN}" --arg mcp --connect-timeout 30 >/dev/null 2>&1 \
            && ok "MCP server added" || die "openclaw mcp add failed"
    fi
    local tools
    tools=$(openclaw mcp probe dsh-computer-use 2>/dev/null | grep -o '[0-9]* tools' | head -1)
    [ -n "${tools}" ] && ok "probe: ${tools}"
    local skill="${HOME}/.openclaw/skills/computer-use/SKILL.md"
    mkdir -p "$(dirname "${skill}")"
    cp "${PROJECT_DIR}/skill/openclaw/SKILL.md" "${skill}"
    ok "skill -> ${skill}"
}

install_hermes() {
    # `hermes mcp add` asks "Enable all N tools?" — feed it a yes.
    # Re-add rather than skip, so the recorded command path is refreshed after
    # a rename. Both subcommands prompt ("Enable all N tools?" / a confirm), so
    # both need a yes — feeding only the add is what made this hang forever on
    # a machine where the server was already configured.
    # `yes` dies of SIGPIPE (141) the moment the consumer stops reading, so
    # under `pipefail` a successful remove looks like a failure. Answer the
    # prompt with a single "y" instead of an endless stream.
    if hermes mcp list 2>/dev/null | grep -q "dsh-computer-use"; then
        printf 'y\n' | hermes mcp remove dsh-computer-use >/dev/null 2>&1 || true
    fi
    # `yes` is killed by SIGPIPE (141) as soon as hermes stops reading, and
    # under `set -o pipefail` that makes a *successful* add report failure.
    # So: drive the prompt from a here-string, and judge the outcome by what
    # the config now says, not by the pipeline's exit status.
    printf 'y\n' | hermes mcp add dsh-computer-use --command "${BIN}" --args mcp --connect-timeout 30 >/dev/null 2>&1
    if hermes mcp list 2>/dev/null | grep -q "dsh-computer-use"; then
        ok "MCP server registered (16 tools)"
    else
        die "hermes mcp add failed — server not registered"
    fi
    local skill="${HOME}/.hermes/skills/computer-use/SKILL.md"
    mkdir -p "$(dirname "${skill}")"
    cp "${PROJECT_DIR}/skill/hermes/SKILL.md" "${skill}"
    ok "skill -> ${skill}"
}

# --- Dispatch --------------------------------------------------------------
installed=0
try() { # try <name> <installer> <available>
    if [ "$3" != "1" ]; then
        skip "$1 not installed — skipped"
        return
    fi
    log "Installing into $1"
    "$2"; installed=$((installed+1))
}

[ "${WANT_DSH}" = "1" ]      && try "DSH"      install_dsh      "${AVAIL[0]}"
[ "${WANT_OPENCLAW}" = "1" ] && try "OpenClaw" install_openclaw "${AVAIL[1]}"
[ "${WANT_HERMES}" = "1" ]   && try "Hermes"   install_hermes   "${AVAIL[2]}"
:

# --- Verify ----------------------------------------------------------------
echo
log "Verification"
"${BIN}" doctor 2>&1 | grep -iE "accessibility|screen recording|self-responsible" | sed 's/^/  /'
echo
if "${BIN}" doctor 2>&1 | grep -q "Self-responsible *: *no"; then
    skip "TCC attribution is not self-owned; grants may not apply. See README."
fi
ok "installed into ${installed} host(s)"
