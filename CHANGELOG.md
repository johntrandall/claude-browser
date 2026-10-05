# Changelog

## 0.1.0 — 2026-10-05

First public release.

- `up` / `down`: one Chrome instance per Claude Code session, cloned from a shared base plus a per-account pairing overlay. Only the declared `--sites` cookies are copied in, and claude.* is refreshed from the account's own profile.
- `template init` / `pair` / `check` / `list`: one human click per Mac for the base, and one per account for pairing.
- `list`, `resolve`, `events`, `gc`, `config`, `app build` / `app check`.
- Per-instance Dock app whose icon shows the account badge, purpose and origin pane, plus an instance card as the first tab.
- SessionStart and SessionEnd hooks for Claude Code.
- Safety: session ids and account names are validated and teardown is confined to the root; `--sites` takes hostnames only (host + subdomains); `allowed_sites` / `denied_sites` config; processes matched by exact `--user-data-dir`.
