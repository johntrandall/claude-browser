#!/usr/bin/env bash
# Mechanics test that needs NO human login: builds a throwaway template with a
# fake claude.ai sessionKey row, clones it, launches, lists, tears down.
# Proves clone / name / launch / pid / teardown, and the golden identity's seed,
# use, hidden refresh and gc selection against a fake main-Chrome profile. Does NOT
# prove pairing or a real claude.ai login (those need a human).
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
COLS="creation_utc,host_key,top_frame_site_key,name,value,encrypted_value,path,expires_utc,is_secure,is_httponly,last_access_utc,has_expires,is_persistent,priority,samesite,source_scheme,source_port,last_update_utc,source_type,has_cross_site_ancestor"
NOW_C=$(python3 -c 'import time; print(int((time.time() + 11644473600) * 1e6))'); EXP_C=$((NOW_C + 30 * 86400 * 1000000))

cleanup() { "$CB" down --all >/dev/null 2>&1 || true; pkill -f -- "--user-data-dir=$ROOT/templates/" 2>/dev/null || true; sleep 1; rm -rf "$TMPROOT"; }
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
echo "12. gc never removes a Dock app another root created"
mkdir -p "$TMPROOT/Applications/Chrome Claude Instances/XX foreign root.app"
touch -t 202001010000 "$TMPROOT/Applications/Chrome Claude Instances/XX foreign root.app"
"$CB" gc >/dev/null
[ -d "$TMPROOT/Applications/Chrome Claude Instances/XX foreign root.app" ] && echo "foreign Dock app left alone: yes" || { echo "FAIL: gc removed a foreign Dock app"; exit 1; }
echo "13. template add-extension: a new base is built beside the old one and swapped in"
FAKEEXT=abcdefghijklmnopabcdefghijklmnop
"$CB" template add-extension "$FAKEEXT" --wait 60 > "$TMPROOT/addext.log" 2>&1 &
AE=$!
for i in $(seq 1 30); do pgrep -f -- "--user-data-dir=$B.new" >/dev/null && break; sleep 1; done
mkdir -p "$B.new/Default/Extensions/$FAKEEXT/1.0_0"          # stands in for the human's Add to Chrome
pkill -f -- "--user-data-dir=$B.new"; wait $AE
grep -q "base now has extension $FAKEEXT" "$TMPROOT/addext.log" && [ -d "$B/Default/Extensions/$FAKEEXT" ] && [ ! -d "$B.new" ] \
  && echo "extension added to the base by swap: yes" || { echo "FAIL: add-extension"; cat "$TMPROOT/addext.log"; exit 1; }
"$CB" template add-extension "not-an-id" >/dev/null 2>&1 && { echo "FAIL: bad extension id accepted"; exit 1; }
echo "13c. a base holding a Claude cookie (a login every clone would inherit) is NOT ready"
# Test fixtures only (fake base, isolated root): an anonymous claude.ai row is acceptable
# (the extension may open claude.ai on install); a foreign site's cookie is not.
sqlite3 "$B/Default/Cookies" "insert into cookies ($COLS) values
  ($NOW_C,'.claude.ai','','anthropic-device-id','',x'763130deadbeef','/',$EXP_C,1,1,$NOW_C,1,1,1,-1,2,443,$NOW_C,0,0);"
"$CB" template check "$ACC" >/dev/null 2>&1 && echo "anonymous claude.ai cookie in the base is accepted: yes" || { echo "FAIL: anonymous claude row refused"; "$CB" template check "$ACC"; exit 1; }
sqlite3 "$B/Default/Cookies" "insert into cookies ($COLS) values
  ($NOW_C,'.example.org','','sid','',x'763130deadbeef','/',$EXP_C,1,1,$NOW_C,1,1,1,-1,2,443,$NOW_C,0,0);"
OUTF="$("$CB" template check "$ACC" 2>&1 || true)"
echo "$OUTF" | grep -q "cookies for .example.org" && echo "a foreign site's cookie in the base is refused and named: yes" || { echo "FAIL: foreign cookie not refused"; "$CB" template check "$ACC"; exit 1; }
sqlite3 "$B/Default/Cookies" "insert into cookies ($COLS) values
  ($NOW_C,'.claude.ai','','sessionKey','',x'763130deadbeef','/',$EXP_C,1,1,$NOW_C,1,1,1,-1,2,443,$NOW_C,0,0);"
"$CB" template check "$ACC" > "$TMPROOT/check-stray.out" 2>&1 && { echo "FAIL: a base with a Claude cookie passed check"; exit 1; }
grep -q "rebuild the base: claude-browser template init --rebuild" "$TMPROOT/check-stray.out" \
  && "$CB" template list | grep -q "stray_cookies=" && echo "stray Claude cookie in the base: NOT ready, rebuild named: yes" \
  || { echo "FAIL: stray-cookie report"; cat "$TMPROOT/check-stray.out"; exit 1; }
"$CB" up --account "$ACC" --session "$SESS-stray" --purpose t --no-graft --wait 1 > "$TMPROOT/up-stray.out" 2>&1 && { echo "FAIL: up cloned a dirty base"; exit 1; }
grep -q "template init --rebuild" "$TMPROOT/up-stray.out" && echo "up refuses a dirty base: yes" || { echo "FAIL: up refusal text"; cat "$TMPROOT/up-stray.out"; exit 1; }
echo "13b. template init --rebuild: a fresh base (not a clone) is built, verified and swapped in"
FAKEEXT2=ponmlkjihgfedcbaponmlkjihgfedcba
"$CB" template init --rebuild --with "$FAKEEXT2" --wait 90 > "$TMPROOT/rebuild.log" 2>&1 &
RB=$!
for i in $(seq 1 30); do pgrep -f -- "--user-data-dir=$B.new" >/dev/null && break; sleep 1; done
"$CB" template init --rebuild --wait 5 > "$TMPROOT/rebuild2.log" 2>&1 && { echo "FAIL: a second rebuild ran"; exit 1; }
grep -q "is running" "$TMPROOT/rebuild2.log" && echo "a second base build is refused while one runs: yes" || { echo "FAIL: concurrent base build"; cat "$TMPROOT/rebuild2.log"; exit 1; }
for i in $(seq 1 20); do [ -f "$B.new/Default/Cookies" ] && break; sleep 1; done
mkdir -p "$B.new/Default/Extensions/$EXT/0.1_0" "$B.new/Default/Extensions/$FAKEEXT2/1.0_0"   # stands in for the human's two Add to Chrome clicks
sleep 2; pkill -f -- "--user-data-dir=$B.new"; wait $RB || true
cat "$TMPROOT/rebuild.log" | tail -2
grep -q "base rebuilt with 2 extension" "$TMPROOT/rebuild.log" && [ ! -e "$B.new" ] && [ -d "$B/Default/Extensions/$FAKEEXT2" ] \
  && python3 -c "import json; t=json.load(open('$B/template.json')); assert sorted(t['extensions'])==sorted(['$EXT','$FAKEEXT2']), t" \
  && "$CB" template check "$ACC" | tail -1 | grep -q READY && echo "rebuilt base swapped in, clean and READY, template.json lists the extensions: yes" \
  || { echo "FAIL: rebuild"; cat "$TMPROOT/rebuild.log"; "$CB" template list; exit 1; }
ls -d "$B".old-* >/dev/null 2>&1 && { echo "FAIL: old base left beside the new one"; exit 1; }
ln -s /tmp "$B.new"; "$CB" template init --rebuild --wait 5 > "$TMPROOT/rebuild-link.out" 2>&1 && { echo "FAIL: rebuild followed a _base.new symlink"; exit 1; }
grep -q "not a plain directory" "$TMPROOT/rebuild-link.out" && [ -d /tmp ] && rm "$B.new" && echo "a symlinked _base.new is refused: yes" || { echo "FAIL: symlink refusal"; exit 1; }
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

echo "12. golden identity: seed from a fake main-Chrome profile; up and list use it; refresh launches hidden and quits; gc picks one"
MAIN="$TMPROOT/MainChrome"; ACC2="zz-test2"; mkdir -p "$MAIN/Fake"
# Chrome's own schema, copied from the fake base's Cookies DB; one fake claude.ai
# sessionKey row (an undecryptable placeholder value) and one unrelated row.
sqlite3 "$B/Default/Cookies" .schema | sqlite3 "$MAIN/Fake/Cookies"
sqlite3 "$MAIN/Fake/Cookies" "insert into cookies ($COLS) values
  ($NOW_C,'.claude.ai','','sessionKey','',x'763130deadbeef','/',$EXP_C,1,1,$NOW_C,1,1,1,-1,2,443,$NOW_C,0,0),
  ($NOW_C,'.example.com','','sid','',x'763130deadbeef','/',$EXP_C,1,1,$NOW_C,1,1,1,-1,2,443,$NOW_C,0,0);"
idcfg() { printf '{"root": "%s", "apps_dir": "%s", "main_chrome_dir": "%s", "accounts": {"%s": "Fake", "%s": "Fake"}, "identity_refresh_seconds": 4, "identity_refresh_hours": %s}\n' \
  "$ROOT" "$TMPROOT/Applications" "$MAIN" "$ACC" "$ACC2" "$1" > "$CLAUDE_BROWSER_CONFIG"; }
idcfg 24
"$CB" config > "$TMPROOT/config.out"; grep -q "identity_refresh_seconds *4" "$TMPROOT/config.out" && echo "identity config keys shown: yes" || { echo "FAIL: config keys"; exit 1; }
"$CB" template identity seed --all > "$TMPROOT/seed.out" || true
[ "$(grep -c "seeded from Fake" "$TMPROOT/seed.out")" = 2 ] && echo "seed --all seeded both accounts: yes" || { echo "FAIL: seed"; exit 1; }
ID="$ROOT/templates/$ACC/identity"
"$CB" events --since 1 --json | python3 -c "
import json,sys; r=[json.loads(l) for l in sys.stdin if '\"identity-create\"' in l]
acc=[x for x in r if x.get('account')=='$ACC']; assert acc and acc[-1]['cookie_rows']==0, acc
print('identity created fresh: 0 cookie rows before grafting: yes')" || { echo "FAIL: identity not created empty"; exit 1; }
[ ! -e "$ID/Default/Extensions/$EXT" ] && [ ! -e "$ID/Default/Local Extension Settings/$EXT" ] && [ ! -e "$ID/template.json" ] \
  && [ "$(stat -f %Lp "$ID")" = 700 ] && echo "identity is not a base clone (no Claude extension, no pairing, no template.json), dir 0700: yes" || { echo "FAIL: identity looks like a base clone"; ls "$ID" "$ID/Default"; exit 1; }
python3 - "$ID" <<'PY' || { echo "FAIL: identity contents"; exit 1; }
import json, os, sqlite3, sys
d = sys.argv[1]; m = json.load(open(os.path.join(d, "identity.json")))
assert m["session_present"] and m["expires_utc"] and m["seeded_at"] and m["source"] == "main-chrome:Fake", m
hosts = {h for (h,) in sqlite3.connect(os.path.join(d, "Default", "Cookies")).execute("select host_key from cookies")}
assert hosts == {".claude.ai"}, hosts
assert not os.path.exists(os.path.join(d, "Default", "Local Extension Settings", "fcoeoabgfenejglbffodgkkbkcdhcgfn"))
print("identity holds only claude.ai cookies, no pairing, identity.json recorded: yes")
PY
"$CB" template list > "$TMPROOT/tlist.out"
grep -A1 "^$ACC " "$TMPROOT/tlist.out" | grep -q "identity: session=True expires=20" && echo "template list shows the identity: yes" || { echo "FAIL: list"; "$CB" template list; exit 1; }
"$CB" up --account "$ACC" --session "$SESS-g" --purpose ident --no-graft --wait 2 > "$TMPROOT/up.out" 2>&1 || true
grep "identity:" "$TMPROOT/up.out"
grep "identity:" "$TMPROOT/up.out" | grep -q "from golden identity.*wrote 1 rows" \
  && echo "up grafts claude.* from the golden identity: yes" || { echo "FAIL: up did not use the golden identity"; exit 1; }
"$CB" down --all >/dev/null
open -na "Google Chrome" --args --user-data-dir="$ID" --profile-directory=Default --no-first-run --disable-extensions about:blank
for i in $(seq 1 20); do pgrep -f -- "--user-data-dir=$ID" >/dev/null && break; sleep 0.5; done; sleep 2
"$CB" template identity seed "$ACC" > "$TMPROOT/seed2.out" || true
grep -q "REFUSED" "$TMPROOT/seed2.out" && echo "seed refuses while the identity is open: yes" || { echo "FAIL: seed into an open identity"; exit 1; }
pkill -f -- "--user-data-dir=$ID"; sleep 3
"$CB" template identity refresh "$ACC2" > "$TMPROOT/refresh.out" || true
cat "$TMPROOT/refresh.out"
grep -q "launched hidden" "$TMPROOT/refresh.out" || { echo "FAIL: refresh did not launch"; exit 1; }
pgrep -f -- "--user-data-dir=$ROOT/templates/$ACC2/identity" >/dev/null && { echo "FAIL: identity Chrome still running"; exit 1; }
python3 -c "import json,sys; m=json.load(open('$ROOT/templates/$ACC2/identity/identity.json')); assert m.get('refreshed_at'), m" \
  && "$CB" events --since 1 > "$TMPROOT/ev.out" && grep -q "identity-refresh .*account=$ACC2" "$TMPROOT/ev.out" && echo "refresh launched, quit Chrome, recorded refreshed_at + event: yes" || { echo "FAIL: refresh record"; exit 1; }
"$CB" template identity refresh "$ACC2" --if-older-than 1 > "$TMPROOT/refresh2.out" || true
grep -q "fresh" "$TMPROOT/refresh2.out" && echo "--if-older-than skips a fresh identity: yes" || { echo "FAIL: --if-older-than"; exit 1; }
"$CB" template identity seed --all >/dev/null      # Chrome may drop the placeholder sessionKey; restore it
echo "12b. gc: nothing due at 24 h; at most one per run, oldest first, never an account mid-launch"
"$CB" gc > "$TMPROOT/gc0.out"; grep -q "gc: identity" "$TMPROOT/gc0.out" && { echo "FAIL: gc refreshed an identity that was not due"; exit 1; }
idcfg 0.00001
# zz-test2 (refreshed above) is the oldest; fake its agent browser as claimed-not-launched.
mkdir -p "$ROOT/sessions/acct-$ACC2"; echo '{"session":"acct-'$ACC2'","account":"'$ACC2'","attached":[]}' > "$ROOT/sessions/acct-$ACC2/instance.json"
"$CB" gc > "$TMPROOT/gc1.out"; cat "$TMPROOT/gc1.out"
grep -q "gc: identity $ACC2 skipped (its agent browser is being launched)" "$TMPROOT/gc1.out" \
  && [ "$(grep -c 'refreshed;' "$TMPROOT/gc1.out")" = 1 ] && grep -q "gc: identity $ACC refreshed" "$TMPROOT/gc1.out" \
  && echo "gc skips an account mid-launch, refreshes exactly one other: yes" || { echo "FAIL: gc selection 1"; exit 1; }
"$CB" down "acct-$ACC2" >/dev/null
"$CB" gc > "$TMPROOT/gc2.out"
[ "$(grep -c 'refreshed;' "$TMPROOT/gc2.out")" = 1 ] && grep -q "gc: identity $ACC2 refreshed" "$TMPROOT/gc2.out" \
  && echo "next gc refreshes the now-oldest one: yes" || { echo "FAIL: gc selection 2"; cat "$TMPROOT/gc2.out"; exit 1; }
pgrep -f -- "--user-data-dir=$ROOT/templates/" >/dev/null && { echo "FAIL: an identity Chrome is left running"; exit 1; }
echo "12c. gc quits an identity Chrome whose starter died"
idcfg 24
sh -c 'exit 0' & DEAD=$!; wait $DEAD
python3 - "$ID/identity.json" "$DEAD" <<'PY'
import json, sys, time
p, pid = sys.argv[1], int(sys.argv[2]); m = json.load(open(p))
m.update(chrome_owner_pid=pid, chrome_started_ts=time.time() - 3600, chrome_purpose="refresh"); json.dump(m, open(p, "w"))
PY
open -g -j -na "Google Chrome" --args --user-data-dir="$ID" --profile-directory=Default --no-first-run --disable-extensions about:blank
for i in $(seq 1 20); do pgrep -f -- "--user-data-dir=$ID" >/dev/null && break; sleep 0.5; done; sleep 2
"$CB" gc > "$TMPROOT/gc-orphan.out"
grep -q "quit an orphaned refresh Chrome" "$TMPROOT/gc-orphan.out" && ! pgrep -f -- "--user-data-dir=$ID" >/dev/null \
  && python3 -c "import json; assert 'chrome_owner_pid' not in json.load(open('$ID/identity.json'))" \
  && echo "orphaned identity Chrome quit and its mark cleared: yes" || { echo "FAIL: orphan"; cat "$TMPROOT/gc-orphan.out"; exit 1; }
"$CB" events --since 1 --json | python3 -c "
import json,sys; r=[json.loads(l) for l in sys.stdin if '\"identity-refresh\"' in l]
print('identity-refresh events (before -> after, claude rows before -> after):')
for x in r: print('  ', x['account'], x.get('before'), '->', x.get('after'), x.get('claude_rows_before'), '->', x.get('claude_rows_after'), 'quit_clean', x.get('quit_clean'))"
printf '{"root": "%s", "apps_dir": "%s"}\n' "$ROOT" "$TMPROOT/Applications" > "$CLAUDE_BROWSER_CONFIG"
echo "PASS mechanics"
