#!/usr/bin/env bash
# Mechanics test that needs NO human login: builds a throwaway template with a
# fake claude.ai sessionKey row, clones it, launches, lists, tears down.
# Proves clone / name / launch / pid / teardown. Does NOT prove pairing or the
# device-id reset (those need a real signed-in template: `claude-browser test device-id`).
set -euo pipefail
CB="$(cd "$(dirname "$0")/.." && pwd)/bin/claude-browser"
# Isolated root so the test never touches the real base/overlays.
TMPROOT="$(mktemp -d /tmp/claude-browser-test.XXXXXX)"
ROOT="$TMPROOT/Chrome-Claude"
export CLAUDE_BROWSER_CONFIG="$TMPROOT/config.json"
# Root AND the Dock-app directory are isolated: nothing lands in the real
# events.log or ~/Applications.
printf '{"root": "%s", "apps_dir": "%s"}\n' "$ROOT" "$TMPROOT/Applications" > "$CLAUDE_BROWSER_CONFIG"
export CLAUDE_BROWSER_ACCOUNT=""
ACC="zz-test"
SESS="mechanics-test-$$"
B="$ROOT/templates/_base"
EXT="fcoeoabgfenejglbffodgkkbkcdhcgfn"

cleanup() { "$CB" down "$SESS" >/dev/null 2>&1 || true; pkill -f -- "--user-data-dir=$B" 2>/dev/null || true; sleep 1; rm -rf "$TMPROOT"; }
trap cleanup EXIT

echo "1. build a fake base (Chrome creates the profile skeleton) + a fake overlay"
mkdir -p "$B/Default"
open -na "Google Chrome" --args --user-data-dir="$B" --profile-directory=Default --no-first-run --no-default-browser-check "about:blank"
for i in $(seq 1 20); do [ -f "$B/Default/Cookies" ] && break; sleep 1; done
pkill -f -- "--user-data-dir=$B"; sleep 3
[ -f "$B/Default/Cookies" ] || { echo "FAIL: no Cookies DB in fake base"; exit 1; }
mkdir -p "$B/Default/Extensions/$EXT/0.1_0"
echo '{"kind":"base","fake":true}' > "$B/template.json"
# overlay: a fake extension LevelDB log carrying a bridgeDeviceId
OV="$ROOT/templates/$ACC/Local Extension Settings/$EXT"; mkdir -p "$OV"
printf 'junk bridgeDeviceId\x00\x01"00000000-1111-2222-3333-444444444444" tail' > "$OV/000003.log"
echo '{"account":"'$ACC'","device_id":"00000000-1111-2222-3333-444444444444","paired":"fake"}' > "$ROOT/templates/$ACC/overlay.json"
"$CB" template list

echo "2. template check"
"$CB" template check "$ACC" | tail -1 | grep -q READY && echo "check: READY" || { echo "FAIL: not READY"; exit 1; }

echo "3. up (no graft, no device-id wait beyond 3s — no real extension here)"
# refusal paths: no purpose, then no sites without --no-graft
"$CB" up --account "$ACC" --session "$SESS" --no-graft --wait 3 >/dev/null 2>&1 && { echo "FAIL: up launched without --purpose"; exit 1; }
"$CB" up --account "$ACC" --session "$SESS" --purpose mechanics --wait 3 >/dev/null 2>&1 && { echo "FAIL: up launched without --sites"; exit 1; }
echo "refuses without purpose/sites: yes"
"$CB" up --account "$ACC" --session "$SESS" --purpose mechanics --no-graft --wait 3 || true
[ -f "$ROOT/sessions/$SESS/instance-card.html" ] && echo "instance card: yes" || { echo "FAIL: no instance card"; exit 1; }

echo "4. list"
"$CB" list
pgrep -f -- "--user-data-dir=$ROOT/sessions/$SESS" >/dev/null && echo "running: yes" || { echo "FAIL: instance not running"; exit 1; }
grep -q "\"name\"" "$ROOT/sessions/$SESS/Default/Preferences" && echo "profile name set: yes"

echo "5. down"
"$CB" down "$SESS"
sleep 1
pgrep -f -- "--user-data-dir=$ROOT/sessions/$SESS" >/dev/null && { echo "FAIL: still running"; exit 1; } || echo "stopped: yes"
[ -d "$ROOT/sessions/$SESS" ] && { echo "FAIL: dir remains"; exit 1; } || echo "dir removed: yes"
echo "6. events: every row names its CLI session; guard-block whoami is the email, not the account uuid"
printf '{"ts":"%s","event":"guard-block","cli_session":"guard-selftest-%s","tool":"mcp__claude-in-chrome__navigate","cwd":"/tmp","whoami":"CLI session : who@example.com  00000000-0000-0000-0000-000000000000"}\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$$" >> "$ROOT/events.log"
"$CB" events --since 1 | grep -q "guard-block   guard-selftest-$$ .* whoami=who@example.com$" && echo "guard-block row shows session + email: yes" || { echo "FAIL: guard-block row lacks session/email"; "$CB" events --since 1 | grep guard-selftest; exit 1; }
"$CB" events --since 1 | grep -q "refused .* session=$SESS" && echo "refusal row shows session: yes" || { echo "FAIL: refusal row missing"; exit 1; }
echo "7. refusals: path-like session ids and non-hostname sites"
mkdir -p "$TMPROOT/canary"
"$CB" down "../../canary" >/dev/null 2>&1 && { echo "FAIL: down accepted a path"; exit 1; }
"$CB" down "$TMPROOT/canary" >/dev/null 2>&1 && { echo "FAIL: down accepted an absolute path"; exit 1; }
[ -d "$TMPROOT/canary" ] || { echo "FAIL: canary deleted"; exit 1; }
"$CB" up --account "$ACC" --session "../x" --purpose t --no-graft --wait 1 >/dev/null 2>&1 && { echo "FAIL: up accepted ../x"; exit 1; }
"$CB" down "ABC" >/dev/null 2>&1 && { echo "FAIL: down accepted an uppercase id"; exit 1; }
for bad in com '*' 'co.uk' '*.example.com' claude.ai console.anthropic.com; do
  "$CB" up --account "$ACC" --session "$SESS-s" --purpose t --sites "$bad" --wait 1 >/dev/null 2>&1 && { echo "FAIL: --sites $bad accepted"; exit 1; }
done
[ -d "$ROOT/sessions/$SESS-s" ] && { echo "FAIL: refused up left a dir"; exit 1; }
echo "path-like ids and bad sites refused, canary intact: yes"
echo "PASS mechanics"
