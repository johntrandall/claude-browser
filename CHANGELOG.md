# Changelog

## 0.3.0 — 2026-10-06

- **Golden identity per account.** The claude.ai login now lives in `templates/<account>/identity/`, a user-data-dir owned by claude-browser. It is created fresh (an empty directory Chrome builds its own profile in, never a copy of the base), so it inherits no cookie or pairing. It is a full Chrome profile and may hold other sites' cookies from a human sign-in; only the `claude_hosts` cookies are ever copied out of it. It is never paired, attached or listed, and it runs only briefly. `up` and `template pair` copy the claude.* cookies from it, so the per-account main-Chrome profiles are no longer needed and can be removed. An account without an identity falls back to its main-Chrome profile, and `up` says which source it used.
- `template identity seed <account>|--all`: create the identity and copy the login from the account's main-Chrome profile (the one-time migration). Refused while the identity is open.
- `template identity refresh <account>|--all [--if-older-than H]`: open the identity hidden (stock Chrome, extensions disabled) on claude.ai for `identity_refresh_seconds` (default 90), quit it, and log `identity-refresh` with the `sessionKey` expiry before and after (`identity-stale` when there is none). Whether this extends the login is not assumed; the events record what happened.
- `template identity login <account>`: sign in to claude.ai in the identity's own window, the recovery path when a login lapses.
- `gc` refreshes at most one identity per run, the one longest past `identity_refresh_hours` (default 24, `0` disables). It decides and launches under the `up` lock and skips an account whose agent browser is mid-launch; the wait runs outside the lock.
- `template list` / `template check` show each identity: session present, expiry date, last refresh, source.
- `gc` quits an identity Chrome whose starter died (recorded in `identity.json` before launch) once it has been open longer than a refresh plus a minute.
- A session counts as live only for a `sessionKey` on exactly `claude.ai` / `.claude.ai` that has not expired.
- **The base must hold no Claude cookie.** `template list` / `check` report `stray_cookies` (Claude-host rows / sessionKey rows, counted from host and name only). A base with any is not ready, and `up` / `template pair` refuse it, because every clone starts with the base's cookies. A base built before 0.3.0 may hold a login this way; rebuild it.
- `template init --rebuild [--with <id> ...]`: build a new base from an empty directory, add the Claude extension and each `--with` extension in its window, verify it (extensions installed, no pairing, no Claude cookie), and swap it in under the lock, rolling back if the swap fails. The old base stays if verification fails.
- `template add-extension <id>`: add a Web Store extension (e.g. a password manager) to the shared base with one human click; the new base is built beside the old one, verified the same way, and swapped in under the lock. Only one `add-extension` / `init --rebuild` runs at a time, and a `_base.new` that is a symlink or a file is refused.
- `template pair` clones the base under the lock.
- An account in config `accounts` may map to `{}` (no main-Chrome profile).
- gc removes only Dock apps its own root created (recorded in `dock-apps.json`). Before, a second root sharing `apps_dir` (a test root, say) could delete another root's live Dock app. Dock apps created by 0.2.x are not in `dock-apps.json`, so gc no longer removes them; their browser's teardown still does, and an orphaned one can be deleted by hand from `~/Applications/Chrome Claude Instances/`.

- The base check refuses login cookies (claude.ai sessionKey and friends, Google sign-in cookies) and any site outside what a fresh install leaves (Web Store, Google consent, captcha, anonymous claude.ai), naming them.

## 0.2.3 — 2026-10-06

- `attach --device-id` and a PostToolUse hook on `select_browser` (`hooks/claude-browser-select-attach.sh`): a session that selects an agent browser without `up` is attached, so it appears on the card and in `list` and is counted by the last-out teardown. Hooks honor `CLAUDE_BROWSER_BIN`.

## 0.2.2 — 2026-10-06

- `up --hold <minutes>`: an agent waiting on a human (a sign-in, an approval) keeps the shared browser past the idle limit for that long (max 24 h). Re-run in the same session to extend. `list` shows the remaining hold.
- The teardown event's `age_s` is measured from launch, not from the directory's mtime (which every attach refreshes).

## 0.2.1 — 2026-10-06

- `up` tells the launching agent and every agent that attaches within the first 4 minutes that the browser is not on the relay yet: poll `list_connected_browsers` before deciding it is blocked (in a 4-agent run, 3 agents gave up on "No connected browser has deviceId" seconds after launch).

## 0.2.0 — 2026-10-06

- One browser per Claude account, shared by every agent on it (each agent in its own tab group). `up` attaches to the account's running browser, or launches it; `down` detaches, and the last agent out tears the browser down. Concurrent `up` calls are serialized by a lock, so they end with one browser and all callers attached (0.1.0 could launch duplicates that fought over the relay).
- `up` is idempotent per session and reports the browser before any account detection.
- Reaping: `up` and `gc` detach agents whose process has exited (`owner_process_names`), and remove browsers whose Chrome is gone, that have no agent, whose agents are all gone, or that have been idle for `idle_minutes` (default 120). The formula adds a `gc` service every 15 minutes.
- The browser's card lists every attached agent and is rewritten on attach/detach. `list` shows browsers with their agents, owner alive/GONE and idle minutes. `chrome-exited` event when a browser dies without a teardown.
- A browser started by 0.1.x is adopted as the account's shared browser, not duplicated.
- Removed: `--new-device-id`, `test device-id` (a reset clone never paired unattended).

## 0.1.0 — 2026-10-05

First public release.

- `up` / `down`: one Chrome instance per Claude Code session, cloned from a shared base plus a per-account pairing overlay. Only the declared `--sites` cookies are copied in, and claude.* is refreshed from the account's own profile.
- `template init` / `pair` / `check` / `list`: one human click per Mac for the base, and one per account for pairing.
- `list`, `resolve`, `events`, `gc`, `config`, `app build` / `app check`.
- Per-instance Dock app whose icon shows the account badge, purpose and origin pane, plus an instance card as the first tab.
- SessionStart and SessionEnd hooks for Claude Code.
- Safety: session ids and account names are validated and teardown is confined to the root; `--sites` takes hostnames only (host + subdomains); `allowed_sites` / `denied_sites` config; processes matched by exact `--user-data-dir`.
