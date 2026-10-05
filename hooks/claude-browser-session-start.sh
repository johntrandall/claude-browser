#!/usr/bin/env bash
# claude-browser-session-start.sh
# Claude Code SessionStart hook: export CLAUDE_SESSION_ID into the session's
# shell environment, so `claude-browser up` and `down` know which session they
# belong to without --session. Claude Code sources the file named by
# $CLAUDE_ENV_FILE into every Bash tool call of the session.

INPUT="$(cat)"
[ -n "$CLAUDE_ENV_FILE" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0
SESSION_ID="$(printf '%s' "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)"
[ -n "$SESSION_ID" ] || exit 0
# Only a plain id (Claude Code uses UUIDs) is passed on.
[[ "$SESSION_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || exit 0
printf 'export CLAUDE_SESSION_ID=%s\n' "$SESSION_ID" >> "$CLAUDE_ENV_FILE"
exit 0
