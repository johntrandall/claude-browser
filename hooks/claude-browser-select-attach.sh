#!/usr/bin/env bash
# claude-browser-select-attach.sh
# Claude Code PostToolUse hook on mcp__claude-in-chrome__select_browser.
#
# An agent can reach a shared agent browser without `claude-browser up`, by
# selecting its device id directly (a subagent handed the id, say). This hook
# attaches that session to the browser, so it shows on the browser's card and
# in `claude-browser list`, and the last-out teardown does not kill the browser
# under it. Selecting a browser that is not an agent browser is left alone.
# Fails silently: it must never break a successful tool call.

CB="${CLAUDE_BROWSER_BIN:-$(command -v claude-browser 2>/dev/null)}"
for c in /opt/homebrew/bin/claude-browser /usr/local/bin/claude-browser "$HOME/.local/bin/claude-browser"; do
  [ -n "$CB" ] && break
  [ -x "$c" ] && CB="$c"
done
[ -n "$CB" ] || exit 0
INPUT="$(cat)"
command -v jq >/dev/null 2>&1 || exit 0
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
DEVICE_ID="$(printf '%s' "$INPUT" | jq -r '.tool_input.deviceId // empty' 2>/dev/null)"
[[ "$SESSION_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || exit 0
[[ "$DEVICE_ID" =~ ^[0-9a-f-]{36}$ ]] || exit 0
CLAUDE_SESSION_ID="$SESSION_ID" "$CB" attach --device-id "$DEVICE_ID" --session "$SESSION_ID" 2>/dev/null || true
exit 0
