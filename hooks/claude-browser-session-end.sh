#!/usr/bin/env bash
# claude-browser-session-end.sh
# Claude Code SessionEnd hook: tear down this session's per-session Chrome
# instance, if any.
#
# A per-session browser that outlives its session is a leak (memory, and a
# stale device id in list_connected_browsers). Fails silently: this hook must
# never block a session from ending.

# Hooks may run with a minimal PATH: try it, then the usual install locations.
CB="${CLAUDE_BROWSER_BIN:-$(command -v claude-browser 2>/dev/null)}"
for c in /opt/homebrew/bin/claude-browser /usr/local/bin/claude-browser "$HOME/.local/bin/claude-browser"; do
  [ -n "$CB" ] && break
  [ -x "$c" ] && CB="$c"
done
[ -n "$CB" ] || exit 0
INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$SESSION_ID" ] || exit 0
# Only a plain id (Claude Code uses UUIDs) is passed on.
[[ "$SESSION_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || exit 0
CLAUDE_SESSION_ID="$SESSION_ID" "$CB" down "$SESSION_ID" >/dev/null 2>&1 || true
exit 0
