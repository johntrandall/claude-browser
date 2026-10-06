# Changelog

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
