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

cleanup() { "$CB" down --all >/dev/null 2>&1 || true; pkill -f -- "--user-data-dir=$B" 2>/dev/null || true; sleep 1; rm -rf "$TMPROOT"; }
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

INST="$ROOT/sessions/acct-$ACC"
echo "3. up (no graft, no device-id wait beyond 3s — no real extension here)"
"$CB" up --account "$ACC" --session "$SESS" --no-graft --wait 3 >/dev/null 2>&1 && { echo "FAIL: up launched without --purpose"; exit 1; }
"$CB" up --account "$ACC" --session "$SESS" --purpose mechanics --wait 3 >/dev/null 2>&1 && { echo "FAIL: up launched without --sites"; exit 1; }
echo "refuses without purpose/sites: yes"
"$CB" up --account "$ACC" --session "$SESS" --purpose mechanics --no-graft --wait 3 || true
[ -f "$INST/instance-card.html" ] && echo "instance card: yes" || { echo "FAIL: no instance card"; exit 1; }
pgrep -f -- "--user-data-dir=$INST" >/dev/null && echo "running: yes" || { echo "FAIL: browser not running"; exit 1; }
grep -q "\"name\"" "$INST/Default/Preferences" && echo "profile name set: yes"
"$CB" up --session "$SESS" --purpose other --no-graft 2>&1 | grep -q "already attached to the $ACC browser" \
  && echo "re-run up is idempotent: yes" || { echo "FAIL: re-run up was not idempotent"; exit 1; }

echo "4. a second and third agent on the same account attach to the SAME browser"
"$CB" up --account "$ACC" --session "$SESS-b" --purpose two --sites example.com --wait 2 2>&1 | grep -q "attached to the $ACC browser" \
  && echo "second agent attached: yes" || { echo "FAIL: second agent did not attach"; "$CB" list; exit 1; }
"$CB" up --account "$ACC" --session "$SESS-c" --purpose three --no-graft --wait 2 2>&1 | grep -q "Poll list_connected_browsers" \
  && echo "early attacher told to poll the relay: yes" || { echo "FAIL: no relay hint for an early attacher"; exit 1; }
"$CB" list --json | python3 -c "
import json,sys; rows=json.load(sys.stdin); acct=[m for m in rows if m['session']=='acct-$ACC']
assert len(rows)==1 and len(acct)==1, [m['session'] for m in rows]
s={a['session'] for a in acct[0]['attachments']}; assert s=={'$SESS','$SESS-b','$SESS-c'}, s
print('one browser, three agents attached: yes')" || { echo "FAIL: attach bookkeeping"; "$CB" list; exit 1; }
grep -q "$SESS-b" "$INST/instance-card.html" && echo "card lists the agents: yes" || { echo "FAIL: card not rewritten"; exit 1; }
"$CB" list

echo "4b. an agent that selects the browser without up is attached by the select_browser hook"
DEV=$("$CB" list --json | python3 -c "import json,sys; print(json.load(sys.stdin)[0]['device_id'])")
printf '{"session_id":"%s","tool_input":{"deviceId":"%s"}}' "$SESS-sel" "$DEV" | CLAUDE_BROWSER_BIN="$CB" bash "$(dirname "$CB")/../hooks/claude-browser-select-attach.sh" | grep -q "attached this session" \
  && "$CB" list | grep -q "$SESS-sel" && echo "select_browser hook attaches: yes" || { echo "FAIL: select hook"; "$CB" list; exit 1; }
"$CB" down "$SESS-sel" >/dev/null
echo "5. down detaches; the last one out tears down"
"$CB" down "$SESS-b" | grep -q "2 agent(s) remain" && echo "detach keeps the browser: yes" || { echo "FAIL: detach"; exit 1; }
pgrep -f -- "--user-data-dir=$INST" >/dev/null || { echo "FAIL: browser died on a detach"; exit 1; }
"$CB" down "$SESS-c" >/dev/null; "$CB" down "$SESS" | grep -q "last agent" && echo "last detach tears down: yes" || { echo "FAIL: last detach"; exit 1; }
sleep 1
pgrep -f -- "--user-data-dir=$INST" >/dev/null && { echo "FAIL: still running"; exit 1; } || echo "stopped: yes"
[ -d "$INST" ] && { echo "FAIL: dir remains"; exit 1; } || echo "dir removed: yes"

echo "6. events: every row names its CLI session; guard-block whoami is the email, not the account uuid"
printf '{"ts":"%s","event":"guard-block","cli_session":"guard-selftest-%s","tool":"mcp__claude-in-chrome__navigate","cwd":"/tmp","whoami":"CLI session : who@example.com  00000000-0000-0000-0000-000000000000"}\n' "$(date +%Y-%m-%dT%H:%M:%S)" "$$" >> "$ROOT/events.log"
"$CB" events --since 1 | grep -q "guard-block   guard-selftest-$$ .* whoami=who@example.com$" && echo "guard-block row shows session + email: yes" || { echo "FAIL: guard-block row lacks session/email"; exit 1; }
"$CB" events --since 1 | grep -q "refused .* session=$SESS" && echo "refusal row shows session: yes" || { echo "FAIL: refusal row missing"; exit 1; }

echo "7. concurrent up: three agents launched at once get ONE browser"
for x in p q r; do "$CB" up --account "$ACC" --session "$SESS-$x" --purpose race --no-graft --wait 2 >/dev/null 2>&1 & done; wait
N=$(ps -axww -o command= | grep -c -- "--user-data-dir=$INST --profile" || true)
"$CB" list --json | python3 -c "
import json,sys; rows=json.load(sys.stdin); assert len(rows)==1, len(rows)
assert len(rows[0]['attachments'])==3, len(rows[0]['attachments']); print('three concurrent ups, one browser, three agents: yes')" || { echo "FAIL: race"; "$CB" list; exit 1; }
"$CB" down --all >/dev/null

echo "8. idle reaping (idle_minutes tiny for this step)"
# An untouched tab stops writing History/Sessions ~20 s after launch (observed): idle = 0.5 min, poll gc up to 2 min.
"$CB" up --account "$ACC" --session "$SESS-i" --purpose idle --no-graft --wait 2 >/dev/null 2>&1 || true
printf '{"root": "%s", "apps_dir": "%s", "idle_minutes": 0.5}\n' "$ROOT" "$TMPROOT/Applications" > "$CLAUDE_BROWSER_CONFIG"
reaped=no; for i in $(seq 1 24); do "$CB" gc | grep -q "acct-$ACC (idle)" && { reaped=yes; break; }; sleep 5; done
[ $reaped = yes ] && echo "idle browser reaped by gc: yes" || { echo "FAIL: idle not reaped"; "$CB" list; exit 1; }

echo "8b. --hold: a held browser survives the idle limit"
printf '{"root": "%s", "apps_dir": "%s"}\n' "$ROOT" "$TMPROOT/Applications" > "$CLAUDE_BROWSER_CONFIG"
"$CB" up --account "$ACC" --session "$SESS-h1" --purpose wait --no-graft --hold 60 --wait 2 >/dev/null 2>&1 || true
printf '{"root": "%s", "apps_dir": "%s", "idle_minutes": 0.5}\n' "$ROOT" "$TMPROOT/Applications" > "$CLAUDE_BROWSER_CONFIG"
sleep 50
"$CB" gc | grep -q "acct-$ACC" && { echo "FAIL: held browser reaped"; exit 1; }
"$CB" list | grep -q "hold 5[0-9]m" && echo "held browser kept past idle, hold shown in list: yes" || { echo "FAIL: hold not shown"; "$CB" list; exit 1; }
"$CB" down --all >/dev/null

echo "9. owner-gone: a dead agent is detached; when every agent is gone the browser goes"
printf '{"root": "%s", "apps_dir": "%s", "owner_process_names": ["fakeowner"]}\n' "$ROOT" "$TMPROOT/Applications" > "$CLAUDE_BROWSER_CONFIG"
ln -sf /bin/bash "$TMPROOT/fakeowner"
"$TMPROOT/fakeowner" -c "\"$CB\" up --account $ACC --session $SESS-o1 --purpose owner --no-graft --wait 2 >/dev/null 2>&1; sleep 120" & F1=$!
sleep 8
"$TMPROOT/fakeowner" -c "\"$CB\" up --account $ACC --session $SESS-o2 --purpose owner --no-graft --wait 2 >/dev/null 2>&1; sleep 120" & F2=$!
for i in $(seq 1 20); do [ "$("$CB" list | grep -c 'owner alive')" = 2 ] && break; sleep 1; done
[ "$("$CB" list | grep -c 'owner alive')" = 2 ] || { echo "FAIL: owners not recorded"; "$CB" list; exit 1; }
kill $F1; sleep 1; "$CB" gc >/dev/null
"$CB" list --json | python3 -c "
import json,sys; r=json.load(sys.stdin); a=[x['session'] for x in r[0]['attachments']]; assert a==['$SESS-o2'], a
print('dead agent detached, browser kept for the live one: yes')" || { echo "FAIL: prune"; "$CB" list; exit 1; }
kill $F2; sleep 1
"$CB" gc | grep -q "acct-$ACC (owner-gone)" && echo "all agents gone, browser reaped: yes" || { echo "FAIL: owner-gone not reaped"; "$CB" list; exit 1; }
printf '{"root": "%s", "apps_dir": "%s"}\n' "$ROOT" "$TMPROOT/Applications" > "$CLAUDE_BROWSER_CONFIG"

echo "11. upgrade: a running 0.1.x per-session browser is adopted, not duplicated"
"$CB" up --account "$ACC" --session "$SESS-legacy" --purpose old --no-graft --wait 2 >/dev/null 2>&1
mv "$INST" "$ROOT/sessions/$SESS-legacy"   # make it look like a 0.1.x per-session browser
pkill -f -- "--user-data-dir=$INST" 2>/dev/null; sleep 1
python3 - "$ROOT/sessions/$SESS-legacy/instance.json" "$SESS-legacy" <<'EOF'
import json,sys; p,s=sys.argv[1],sys.argv[2]; m=json.load(open(p)); a=m.pop("attached")[0]
m.update(session=s, purpose=a["purpose"], identity=a["identity"], owner_pid=a["owner_pid"]); json.dump(m,open(p,"w"))
EOF
open -na "Google Chrome" --args --user-data-dir="$ROOT/sessions/$SESS-legacy" --profile-directory=Default --no-first-run about:blank; sleep 3
"$CB" up --account "$ACC" --session "$SESS-new" --purpose new --no-graft --wait 2 2>&1 | grep -q "attached to the $ACC browser"   && [ ! -d "$INST" ] && echo "legacy browser adopted, no duplicate: yes" || { echo "FAIL: legacy not adopted"; "$CB" list; exit 1; }
"$CB" down --all >/dev/null
echo "11b. a 0.1.x browser with a reset (unpaired) device id is NOT adopted"
mkdir -p "$ROOT/sessions/$SESS-unpaired/Default"
echo '{"session":"'$SESS-unpaired'","account":"'$ACC'","purpose":"old"}' > "$ROOT/sessions/$SESS-unpaired/instance.json"
open -na "Google Chrome" --args --user-data-dir="$ROOT/sessions/$SESS-unpaired" --profile-directory=Default --no-first-run about:blank; sleep 3
"$CB" up --account "$ACC" --session "$SESS-n2" --purpose new --no-graft --wait 2 >/dev/null 2>&1
[ -d "$INST" ] && echo "unpaired legacy browser not adopted, fresh browser launched: yes" || { echo "FAIL: unpaired legacy adopted"; "$CB" list; exit 1; }
"$CB" down --all >/dev/null
echo "10. refusals: path-like session ids and non-hostname sites"
mkdir -p "$TMPROOT/canary"
"$CB" down "../../canary" >/dev/null 2>&1 && { echo "FAIL: down accepted a path"; exit 1; }
"$CB" down "$TMPROOT/canary" >/dev/null 2>&1 && { echo "FAIL: down accepted an absolute path"; exit 1; }
[ -d "$TMPROOT/canary" ] || { echo "FAIL: canary deleted"; exit 1; }
"$CB" up --account "$ACC" --session "../x" --purpose t --no-graft --wait 1 >/dev/null 2>&1 && { echo "FAIL: up accepted ../x"; exit 1; }
"$CB" down "ABC" >/dev/null 2>&1 && { echo "FAIL: down accepted an uppercase id"; exit 1; }
for bad in com '*' 'co.uk' '*.example.com' claude.ai console.anthropic.com; do
  "$CB" up --account "$ACC" --session "$SESS-s" --purpose t --sites "$bad" --wait 1 >/dev/null 2>&1 && { echo "FAIL: --sites $bad accepted"; exit 1; }
done
[ -d "$INST" ] && { echo "FAIL: refused up left a dir"; exit 1; }
"$CB" up --account "$ACC" --session "$SESS-h" --purpose nas --sites nas --wait 1 2>&1 | grep -q "is not a hostname" && { echo "FAIL: single-label host refused"; exit 1; }
"$CB" down --all >/dev/null
echo "path-like ids and bad sites refused, single-label host accepted; canary intact: yes"
echo "PASS mechanics"
