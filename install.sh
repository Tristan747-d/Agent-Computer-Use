#!/bin/bash
# Install Agent Computer Use into one or more agent hosts.
#
# The binary is host-agnostic: it speaks MCP over stdio. What differs per host
# is only *where the config lives* and *how tools are named*, so this script
# builds once and then wires the same binary into whatever you ask for.
#
# Usage:
#   ./install.sh                       # install into every host found
#   ./install.sh --host dsh            # just DSH
#   ./install.sh --host openclaw --host hermes
#   ./install.sh --rebuild             # force swift rebuild
#
# Hosts are skipped (not failed) when they are not installed.

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
# This project is being renamed to Agent-Computer-Use. The *bundle id* is
# deliberately NOT changing: macOS TCC keys Accessibility and Screen Recording
# grants by bundle id, so renaming it would silently revoke every user's
# existing grant and force a manual re-authorization. The product name changes;
# the identity macOS has already trusted does not.
LEGACY_BUNDLE_ID="com.tristan.dsh.computeruse"
BUNDLE_ID="${LEGACY_BUNDLE_ID}"

WANT_DSH=0
WANT_OPENCLAW=0
WANT_HERMES=0
REBUILD=0

log()  { printf '\033[1m==>\033[0m %s\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
skip() { printf '  \033[33m-\033[0m %s\n' "$*"; }
die()  { printf '  \033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

if [ $# -eq 0 ]; then
    # No flags: install everywhere that is actually present.
    ALL=1
else
    ALL=0
fi
while [ $# -gt 0 ]; do
    case "$1" in
        --host)
            case "${2:-}" in
                dsh)      WANT_DSH=1 ;;
                openclaw) WANT_OPENCLAW=1 ;;
                hermes)   WANT_HERMES=1 ;;
                *) die "unknown host '${2:-}'. Use dsh, openclaw or hermes." ;;
            esac
            shift 2 ;;
        --rebuild) REBUILD=1; shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) die "unknown option '$1'" ;;
    esac
done

# --- Build -----------------------------------------------------------------
log "Building signed .app (bundle id ${BUNDLE_ID})"
cd "${PROJECT_DIR}"
if [ "${REBUILD}" = "1" ] || [ ! -x "${BIN}" ]; then
    ./build-app.sh --install
else
    ./build-app.sh --install
fi
[ -x "${BIN}" ] || die "build produced no binary at ${BIN}"
ok "binary: ${BIN}"

# --- DSH -------------------------------------------------------------------
install_dsh() {
    # DSH loads the sidebar panel as a pnpm-linked plugin, and its MCP config
    # finds the binary by absolute path.
    local target="${HOME}/.dsh/profiles/web/node_modules/dsh-computer-use-panel"
    mkdir -p "$(dirname "${target}")"
    ln -sfn "${PROJECT_DIR}/plugin" "${target}"
    ok "panel linked -> ${target}"

    local skill="${HOME}/.dsh/skills/computer-use/SKILL.md"
    mkdir -p "$(dirname "${skill}")"
    cp "${PROJECT_DIR}/skill/SKILL.md" "${skill}"
    ok "skill -> ${skill}  (tools: mcp__computer__*)"
}

# --- OpenClaw --------------------------------------------------------------
install_openclaw() {
    # `openclaw mcp add` probes the server before saving, so a broken binary
    # fails here rather than at first use.
    if openclaw mcp show dsh-computer-use >/dev/null 2>&1; then
        openclaw mcp set dsh-computer-use \
            --command "${BIN}" --arg mcp >/dev/null 2>&1 \
            && ok "MCP server updated" \
            || { openclaw mcp add dsh-computer-use --command "${BIN}" --arg mcp --connect-timeout 30 >/dev/null 2>&1 && ok "MCP server added"; }
    else
        openclaw mcp add dsh-computer-use --command "${BIN}" --arg mcp --connect-timeout 30 >/dev/null 2>&1 \
            && ok "MCP server added" || die "openclaw mcp add failed"
    fi
    openclaw mcp probe dsh-computer-use 2>&1 | sed 's/^/  /'

    local skill="${HOME}/.openclaw/skills/computer-use/SKILL.md"
    mkdir -p "$(dirname "${skill}")"
    cp "${PROJECT_DIR}/skill/openclaw/SKILL.md" "${skill}"
    ok "skill -> ${skill}"
}

# --- Hermes ----------------------------------------------------------------
install_hermes() {
    # `hermes mcp add` is interactive ("Enable all N tools?") — feed it a yes.
    if hermes mcp list 2>/dev/null | grep -q "dsh-computer-use"; then
        skip "MCP server already configured (run: hermes mcp test dsh-computer-use)"
    else
        yes | hermes mcp add dsh-computer-use \
            --command "${BIN}" --args mcp --connect-timeout 30 >/dev/null 2>&1 \
            && ok "MCP server added (16 tools)" \
            || die "hermes mcp add failed"
    fi
    local skill="${HOME}/.hermes/skills/computer-use/SKILL.md"
    mkdir -p "$(dirname "${skill}")"
    cp "${PROJECT_DIR}/skill/hermes/SKILL.md" "${skill}"
    ok "skill -> ${skill}  (tools: dsh-computer-use:<tool>)"
}

# --- Dispatch --------------------------------------------------------------
installed=0
try() { # try <name> <installer> <detect>
    if [ "${ALL}" = "1" ] && ! eval "$3" >/dev/null 2>&1; then
        skip "$1 not installed — skipped"; return
    fi
    log "Installing into $1"
    "$2"; installed=$((installed+1))
}

if [ "${ALL}" = "1" ] || [ "${WANT_DSH}" = "1" ]; then
    try "DSH" install_dsh '[ -d "${HOME}/.dsh" ]'
fi
if [ "${ALL}" = "1" ] || [ "${WANT_OPENCLAW}" = "1" ]; then
    try "OpenClaw" install_openclaw 'command -v openclaw'
fi
if [ "${ALL}" = "1" ] || [ "${WANT_HERMES}" = "1" ]; then
    try "Hermes" install_hermes 'command -v hermes'
fi

# --- Verify ----------------------------------------------------------------
echo
log "Verification"
"${BIN}" doctor 2>&1 | grep -iE "accessibility|screen recording|self-responsible" | sed 's/^/  /'
echo
if "${BIN}" doctor 2>&1 | grep -q "Self-responsible *: *no"; then
    skip "TCC attribution is not self-owned; grants may not apply. See README."
fi
ok "installed into ${installed} host(s)"
