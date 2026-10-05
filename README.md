# claude-browser

One throwaway Chrome instance per Claude Code session on macOS. Each instance is already signed in to claude.ai and paired with the Claude in Chrome extension, and carries only the site logins the agent asked for.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## What it does

`claude-browser up` clones a prepared Chrome user-data-dir in milliseconds, using APFS copy-on-write. It copies cookies into the clone before Chrome opens it:

- the claude.ai session, from that Claude account's own profile in your main Chrome
- cookies for the hosts named in `--sites`, from your everyday profile

It then launches the clone as a separate Chrome process and prints the extension's device id. The agent selects that id with `select_browser`. When the Claude Code session ends, a hook kills the instance and deletes its directory.

Each instance is labeled with who is driving it:

- Its window and profile name are `<account> · <purpose> · <session>`.
- It gets its own Dock icon showing the account badge, the purpose word and the terminal pane of the driving agent.
- Its first tab is an "instance card" with the session id, resume command, origin pane, grafted sites and teardown command.

## Why it exists

The Claude in Chrome extension pairs per Chrome profile and per Claude account. The usual setup has two problems:

- **Cookies can't be refreshed.** With one profile per Claude account inside your everyday Chrome, those profiles stay loaded as long as Chrome runs. Nothing can safely write cookies into a loaded profile.
- **Sessions can't be told apart.** Several agent sessions share one profile, so nobody can tell which session is driving which window.

`claude-browser` puts each session in its own unloaded user-data-dir instead. Cookies can be written into it before launch. Its identity is visible in the window, the Dock and the first tab. It disappears with the session.

It wraps [`chrome-cookie-graft`](https://github.com/johntrandall/chrome-cookie-graft), the cookie copier, rather than reimplementing it.

## Requirements

- macOS on an APFS volume (instances are `cp -c` clones)
- Google Chrome, plus the [Claude in Chrome](https://chromewebstore.google.com/detail/fcoeoabgfenejglbffodgkkbkcdhcgfn) extension
- one or more Claude accounts, each signed in to claude.ai in a profile of your main Chrome
- `python3` (3.9 or later, standard library only)
- [`chrome-cookie-graft`](https://github.com/johntrandall/chrome-cookie-graft), installed by the formula
- optional: [`fileicon`](https://github.com/mklement0/fileicon), for per-instance Dock icons (installed by the formula)
- optional: `uv` or Pillow for python3, to render those icons (without either, instances use the stock Chrome icon)
- optional: `jq`, for the Claude Code hooks

## Install

```bash
brew install johntrandall/tap/claude-browser
```

Then register the two hooks in `~/.claude/settings.json`. The SessionStart hook exports `CLAUDE_SESSION_ID` into the session's shell. The SessionEnd hook tears the instance down.

```json
{
  "hooks": {
    "SessionStart": [{ "hooks": [{ "type": "command",
      "command": "/opt/homebrew/share/claude-browser/hooks/claude-browser-session-start.sh" }] }],
    "SessionEnd": [{ "hooks": [{ "type": "command",
      "command": "/opt/homebrew/share/claude-browser/hooks/claude-browser-session-end.sh" }] }]
  }
}
```

On Intel Macs the prefix is `/usr/local` instead of `/opt/homebrew`. Without the SessionStart hook, pass `--session <id>` to `up` and `down`.

## Quick start

**1. Map each Claude account to the main-Chrome profile signed in to it.** The profile directory names are listed in `chrome://version` ("Profile Path") or under `~/Library/Application Support/Google/Chrome/`.

```bash
mkdir -p ~/.config/claude-browser
cat > ~/.config/claude-browser/config.json <<'EOF'
{ "accounts": { "work": "Profile 3", "personal": "Profile 5" } }
EOF
```

**2. Build the shared base, once per Mac.** This step needs one human click. A fresh Chrome window opens on the Web Store page. Click **Add to Chrome**, sign in to nothing, then quit that window with Cmd-Q.

```bash
claude-browser template init
```

**3. Pair each account, once.** This step needs one human click per account. A clone of the base opens, signed in to claude.ai as that account. Click the Claude extension icon in its toolbar. The tool saves the resulting pairing as the account's overlay and closes the window.

```bash
claude-browser template pair work
claude-browser template list
```

```text
base       ext=True open=False extensions=1 stray_pairing=None  …/Chrome-Claude/templates/_base
work       ready=True  device=a1b2c3d4-…  paired=human click 2026-01-15 10:02  main_profile=Profile 3 session=True
```

**4. In an agent session, launch the browser.** The agent declares a purpose and the sites whose cookies it needs:

```bash
claude-browser up --account work --purpose tickets --sites example.com
```

```text
up: account=work purpose=tickets session=7f3e9a10-… from=tmux:%3 sites=example.com
  cloned  …/Chrome-Claude/sessions/7f3e9a10-…
  graft: …
  identity: from Profile 3: …
  dock app: WO tickets main:1.0 7f3e9a10.app
  launched pid 41733 window 'work · tickets · 7f3e9a10'
  device id a1b2c3d4-…
NEXT (in the agent): list_connected_browsers → select_browser deviceId=a1b2c3d4-…
```

The agent then calls `select_browser` with that id and works. When the session ends, the SessionEnd hook runs `claude-browser down <session>`.

## How it works

```text
templates/_base/          Chrome skeleton + Claude extension, no identity (shared, ~175 MB)
templates/<account>/      overlay: the extension's local storage after pairing (~500 KB)
        │  cp -Rc (APFS clone) + overlay
        ▼
sessions/<session-id>/    per-session user-data-dir
        │  1. graft claude.* cookies from the account's main-Chrome profile
        │  2. graft cookies for --sites hosts from the site-cookie source profile
        │  3. name the profile, write the instance card, build the Dock app
        │  4. open -na <Chrome copy> --args --user-data-dir=<dir>
        ▼
agent: list_connected_browsers → select_browser <device id>
        ⋮
SessionEnd hook → claude-browser down <session>  (kill + delete)
```

All state lives under the root, `~/Library/Application Support/Chrome-Claude/` by default. That includes `events.log`, an append-only JSONL record of every launch, refusal, pairing and teardown. Instances delete themselves, so the log is the durable trace. Other tools, such as a PreToolUse hook that guards browser tools, may append their own rows. `events` shows them, and it shortens a `whoami` field of the form `<label> : <email>  <uuid>` to the email.

The extension signs in off the claude.ai session cookie in its profile. Its pairing state lives in the account's overlay (see the security model). That cookie is re-copied at every launch from the account's main-Chrome profile, so a clone's session is as fresh as the one you use.

## Security model

- **What moves.** Two sets of cookies are copied into a clone, and nothing else. The first is the `claude.ai` / `claude.com` / `claudeusercontent.com` cookies from that account's own main-Chrome profile. `anthropic.com` is left out by default, because its Console session can create API keys. The second is cookies for each `--sites` host and its subdomains, from the site-cookie source profile (`Default` unless configured). A site must be a plain hostname such as `example.com`. Wildcards, Claude and Anthropic hosts, and a short list of public suffixes such as `com` or `co.uk` are refused. The suffix list is not complete, so use `allowed_sites` for a real fence. `up` refuses to launch without `--sites` unless you pass `--no-graft`.
- **What is kept at rest.** Each account's overlay (`templates/<account>/`) is the Claude extension's complete local storage after pairing. That includes its device id and its authorization state, which may include tokens. The overlay persists until you delete it, and it is copied into every instance of that account. It is protected only by the permissions of your user account's `~/Library`, the same as Chrome's own profiles.
- **Where it moves.** Only between directories on the same Mac. Nothing is uploaded. chrome-cookie-graft decrypts and re-encrypts with the same login-Keychain key Chrome uses ("Chrome Safe Storage").
- **How long it lives.** A clone is deleted, not trashed, when its session ends (`down`, the SessionEnd hook, `gc`, or the next `up` reaping dead instances).
- **What an agent can do.** A launched instance is a real signed-in browser for the declared sites. The agent chooses `--sites` itself, so this scoping protects against mistakes, not against a compromised or prompt-injected agent. To fence what any agent can request, set `allowed_sites` and/or `denied_sites` in the config. `up` enforces both. The fence holds only if the agent cannot edit the config file or set `CLAUDE_BROWSER_CONFIG`. The same file's `account_detector` and `origin_command` are shell commands.
- **What the CLI will delete.** Session ids and account names must be plain names (letters, digits, `.`, `_`, `-`; session ids lowercase). Teardown deletes a directory only after resolving it to a direct child of `sessions/`, and it stops only processes whose command line carries exactly that instance's `--user-data-dir`.
- **What stays untouched.** Your main Chrome's profiles are only read. The base template never holds an identity: `template list` reports `stray_pairing`, and that value must be `None`.

## Commands

| Command | What it does |
|---|---|
| `template init` | Create the shared base; needs one human click (Add to Chrome) |
| `template pair <account>` | Pair an account; needs one human click on the extension icon |
| `template check <account>` / `template list` | Report whether the base and overlays are ready |
| `up --purpose W --sites H[,H] [--account A] [--session S] [--origin T] [--no-graft] [--new-device-id] [--wait S]` | Launch this session's browser |
| `down [<session>] [--all]` | Kill the instance and delete it |
| `list [--json]` | List instances: session, account, purpose, running, age, origin, device id |
| `resolve <device-id>` | Answer "whose browser is this?" |
| `events [--since H] [--json]` | Print the event log |
| `gc [--older-than H]` | Remove dead or old instances and orphaned Dock apps |
| `app build [--account A \| --all]` / `app check` | Manage the icon-bearing Chrome copies; rebuild after a Chrome update |
| `config [--json]` | Print the effective configuration |
| `test device-id <account>` | Check whether a reset clone mints its own device id unattended |

Exit codes: `0` ok, `1` usage or precondition, `2` template not ready (a human step is needed), `3` instance failed to come up.

## Configuration

The config lives in `~/.config/claude-browser/config.json`, or wherever `$CLAUDE_BROWSER_CONFIG` points. Every key is optional. `claude-browser config` prints the effective values.

| Key | Default | Meaning |
|---|---|---|
| `accounts` | `{}` | Account name → main-Chrome profile dir, e.g. `{"work": "Profile 3"}`. The value can also be `{"profile": "Profile 3", "badge": "W"}`. |
| `registry` | none | For setups that already keep an account registry: a JSON file holding `accounts.<name>.chrome_profile_dir`. `accounts` wins on conflict. |
| `account_detector` | none | Shell command whose stdout's first word is this session's account. Used when neither `--account` nor `$CLAUDE_BROWSER_ACCOUNT` is given. |
| `origin_command` | none | Shell command whose first stdout line names where the agent runs. Overrides pane detection; `--origin` overrides it. |
| `root` | `~/Library/Application Support/Chrome-Claude` | Base, overlays, instances, icons, events.log |
| `main_chrome_dir` | `~/Library/Application Support/Google/Chrome` | Your main Chrome's user-data-dir (the cookie source) |
| `site_cookie_source` | `Default` | Profile dir in the main Chrome whose cookies `--sites` draws from |
| `extension_id` | `fcoeoabgfenejglbffodgkkbkcdhcgfn` | Claude in Chrome's Web Store id |
| `claude_hosts` | claude.ai, claude.com, claudeusercontent.com (+ subdomains) | Host globs treated as the Claude identity |
| `allowed_sites` | none | If set, every `--sites` host must be one of these or a subdomain of one |
| `denied_sites` | none | `--sites` hosts (and subdomains) that `up` always refuses, e.g. `["google.com", "mybank.com"]` |
| `chrome_app_src` | `/Applications/Google Chrome.app` | The Chrome that copies are cloned from |
| `apps_dir` | `~/Applications` | Where `Chrome Claude*.app` copies and per-instance Dock apps go |
| `native_messaging_hosts` | `<main_chrome_dir>/NativeMessagingHosts` | Linked into the base so instances can see native hosts |
| `grafter` | `chrome-cookie-graft` on `PATH` | Path to chrome-cookie-graft |

The account is resolved in this order:

1. `--account`
2. `$CLAUDE_BROWSER_ACCOUNT`
3. `account_detector`

If none of these yields an account, `up` refuses. The origin shown on the card and icon is resolved in this order:

1. `--origin`
2. `origin_command`
3. a herdr pane (`$HERDR_PANE_ID`)
4. a tmux pane (`$TMUX_PANE`)
5. the tty, shown as "bare"

## History and limits

`claude-browser` has been used with several Claude accounts on one Mac since October 2026. Known limits:

- **Pairing is one human click per account.** A clone whose extension storage has been reset did not mint a device id on its own in testing. The extension appears to need an interactive hand-off. So `up` reuses the account's saved pairing.
- **One live instance per account.** Instances of an account share the overlay's device id, and the relay keeps the last writer. `up` therefore refuses a second live instance of the same account. `--new-device-id` exists for the multi-instance case but is unreliable for the reason above.
- **Tab pinning is human-only.** Chrome keeps pinned tabs and startup pages in HMAC-tracked preferences and discards outside writes. The instance card is marked by its favicon and title instead.
- **Local native messaging fails from app copies.** An instance launched from a relocated copy of Chrome cannot find the user-level native messaging hosts, even with the symlink. The relay path that `list_connected_browsers` uses does not depend on them.
- **Two connected browsers block the tools until one is selected.** When two browsers are connected to the same account and none is selected, claude-in-chrome tools refuse until `select_browser` runs. Agents should select the id that `up` printed before doing anything else.

Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## Contributing

Issues and pull requests are welcome at https://github.com/johntrandall/claude-browser. Please include `claude-browser config` output (redact profile names if you like) and the relevant `claude-browser events --since 1` lines with a bug report.

Run `bash tests/test-mechanics.sh` before sending a change. It builds a throwaway base under a temporary root and runs clone, launch, list and teardown. It opens Chrome briefly and needs no login.

This project is not affiliated with Anthropic or Google.

## License

[MIT](LICENSE)
