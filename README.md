# claude-browser

One throwaway Chrome per Claude account on macOS, shared by every Claude Code agent on that account, each agent in its own tab group. It starts on demand, already signed in to claude.ai and paired with the Claude in Chrome extension, carries only the site logins agents asked for, and is deleted when the last agent is done.

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

## What it does

`claude-browser up` clones a prepared Chrome user-data-dir in milliseconds, using APFS copy-on-write. It copies cookies into the clone before Chrome opens it:

- the claude.ai session, from that Claude account's own profile in your main Chrome
- cookies for the hosts named in `--sites`, from your everyday profile

It then launches the clone as a separate Chrome process and prints the extension's device id. The agent selects that id with `select_browser`. A second agent on the same account runs the same `up` and attaches to the running browser; the Claude in Chrome extension gives each agent its own tab group, which keeps their tabs apart (an organizational split, not a security boundary: see the security model). When a Claude Code session ends, a hook detaches it; the last agent out kills the browser and deletes its directory.

Each browser says who is using it:

- Its window and profile name are `<account> · agents`, and it has its own Dock icon with the account badge.
- Its first tab is a card listing every attached agent: purpose, session id, resume command, origin pane and the sites it asked for. The card is rewritten on every attach and detach.
- `claude-browser list` shows each browser with its agents and whether each agent's process is still alive.

## Why it exists

The Claude in Chrome extension pairs per Chrome profile and per Claude account. The usual setup has two problems:

- **Cookies can't be refreshed.** With one profile per Claude account inside your everyday Chrome, those profiles stay loaded as long as Chrome runs. Nothing can safely write cookies into a loaded profile.
- **Sessions can't be told apart.** Several agent sessions share one profile, so nobody can tell which session is driving which window.

`claude-browser` gives each account its own unloaded user-data-dir instead, outside your everyday Chrome. Cookies can be written into it before launch. Who is using it is visible in the window, the Dock, the card and `list`. It disappears when its last agent does.

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

**3. Pair each account, once.** This needs one human click per account. A clone of the base opens, signed in to claude.ai as that account. Click the Claude extension icon in its toolbar. The tool saves the resulting pairing and closes the window.

```bash
claude-browser template pair work
claude-browser template list
```

```text
base       ext=True open=False extensions=1 stray_pairing=None  …/Chrome-Claude/templates/_base
work       ready=True  slots=1 [1=a1b2c3d4]  main_profile=Profile 3 session=True
```

**4. In an agent session, launch the browser.** The agent declares a purpose and the sites whose cookies it needs:

```bash
claude-browser up --account work --purpose tickets --sites example.com
```

```text
up: account=work purpose=tickets session=7f3e9a10-… from=tmux:%3 sites=example.com
  cloned  …/Chrome-Claude/sessions/acct-work
  graft: …
  identity: from Profile 3: …
  dock app: WO agents work acct-wor.app
  launched pid 41733 window 'work · agents'
  device id a1b2c3d4-…
NEXT (in the agent): list_connected_browsers → select_browser deviceId=a1b2c3d4-…
```

The agent then calls `select_browser` with that id and works in its own tabs, closing them when done. A second agent on `work` gets `attached to the running work browser` and the same device id. When a session ends, the SessionEnd hook runs `claude-browser down <session>`, which detaches it; the last one out tears the browser down.

**One limit of sharing:** Chrome cannot take new cookies while it runs. An agent that attaches gets the sites grafted at launch; for any of its `--sites` not covered, `up` prints a note, and the agent (or you) logs in to that site in the window. That login then lasts for the browser's lifetime.

## How it works

```text
templates/_base/          Chrome skeleton + Claude extension, no identity (shared, ~175 MB)
templates/<account>/      the account's pairing: the extension's local storage (~500 KB)
        │  cp -Rc (APFS clone) + pairing, under a lock (a concurrent up waits, then attaches)
        ▼
sessions/acct-<account>/  the account's shared user-data-dir; instance.json lists attached agents
        │  1. graft claude.* cookies from the account's main-Chrome profile
        │  2. graft cookies for --sites hosts from the site-cookie source profile
        │  3. name the profile, write the instance card, build the Dock app
        │  4. open -na <Chrome copy> --args --user-data-dir=<dir>
        ▼
agent: list_connected_browsers → select_browser <device id>
        ⋮
SessionEnd hook → claude-browser down <session>  (detach; last one out: kill + delete)
```

All state lives under the root, `~/Library/Application Support/Chrome-Claude/` by default. That includes `events.log`, an append-only JSONL record of every launch, attach, detach, refusal, pairing and teardown. Instances delete themselves, so the log is the durable trace. Other tools, such as a PreToolUse hook that guards browser tools, may append their own rows. `events` shows them, and it shortens a `whoami` field of the form `<label> : <email>  <uuid>` to the email.

The extension signs in off the claude.ai session cookie in its profile. Its pairing state lives in the account's saved pairing (see the security model). That cookie is re-copied at every launch from the account's main-Chrome profile, so a clone's session is as fresh as the one you use.

## Security model

- **What moves.** Two sets of cookies are copied into a clone, and nothing else. The first is the `claude.ai` / `claude.com` / `claudeusercontent.com` cookies from that account's own main-Chrome profile. `anthropic.com` is left out by default, because its Console session can create API keys. The second is cookies for each `--sites` host and its subdomains, from the site-cookie source profile (`Default` unless configured). A site is a plain hostname such as `example.com` (it covers its subdomains too) or a single host name such as `nas` (that exact host only). Wildcards, Claude and Anthropic hosts, and a short list of public suffixes such as `com` or `co.uk` are refused. The suffix list is not complete, so use `allowed_sites` for a real fence. `up` refuses to launch without `--sites` unless you pass `--no-graft`.
- **What is kept at rest.** Each account's saved pairing (`templates/<account>/`) is the Claude extension's complete local storage after pairing. That includes its device id and its authorization state, which may include tokens. It persists until you delete it, and it is copied into every browser of that account. It is protected only by the permissions of your user account's `~/Library`, the same as Chrome's own profiles.
- **Where it moves.** Only between directories on the same Mac. Nothing is uploaded. chrome-cookie-graft decrypts and re-encrypts with the same login-Keychain key Chrome uses ("Chrome Safe Storage").
- **How long it lives.** A browser is deleted, not trashed, when its last agent detaches through `down` or the SessionEnd hook. Failing those, `gc` or the next `up` detaches agents whose process has exited, and reaps a browser when its Chrome is gone, every agent's process has exited (`owner-gone`), no agent is attached, or it has been idle for `idle_minutes` (default 120). `brew services start claude-browser` runs `gc` every 15 minutes.
- **Agents on one account share one browser profile.** Cookies, localStorage, IndexedDB and history are shared by every agent attached to an account's browser. One agent can use a site another agent asked for, or one you logged in to in that window, and can open `chrome://history` or another agent's logged-in site. Tab groups keep tabs apart for tidiness; they are not a security boundary. If agents need isolation from each other, run them under different Claude accounts.
- **What an agent can do.** A launched browser is a real signed-in browser for the grafted sites. The agent chooses `--sites` itself, so this scoping protects against mistakes, not against a compromised or prompt-injected agent. To fence what any agent can request, set `allowed_sites` and/or `denied_sites` in the config. `up` enforces both. The fence holds only if the agent cannot edit the config file or set `CLAUDE_BROWSER_CONFIG`. The same file's `account_detector` and `origin_command` are shell commands.
- **What the CLI will delete.** Session ids and account names must be plain names (letters, digits, `.`, `_`, `-`; session ids lowercase). Teardown deletes a directory only after resolving it to a direct child of `sessions/`, and it stops only processes whose command line carries exactly that instance's `--user-data-dir`.
- **What stays untouched.** Your main Chrome's profiles are only read. The base template never holds an identity: `template list` reports `stray_pairing`, and that value must be `None`.

## Commands

| Command | What it does |
|---|---|
| `template init` | Create the shared base; needs one human click (Add to Chrome) |
| `template pair <account>` | Pair (or re-pair) an account; one human click on the extension icon |
| `template check <account>` / `template list` | Report whether the base and the pairing are ready |
| `up --purpose W --sites H[,H] [--account A] [--session S] [--origin T] [--no-graft] [--wait S]` | Attach this session to its account's browser, launching it if needed |
| `down [<session>] [--all]` | Detach a session; the last one out kills the browser and deletes it. `down acct-<account>` or `--all` kills a browser no matter how many agents are attached |
| `list [--json]` | List browsers and their attached agents: purpose, owner alive, origin, sites; idle minutes, device id |
| `resolve <device-id>` | Answer "whose browser is this?" |
| `events [--since H] [--json]` | Print the event log |
| `gc [--older-than H]` | Detach dead agents; remove dead, abandoned, idle or old browsers and orphaned Dock apps |
| `app build [--account A \| --all]` / `app check` | Manage the icon-bearing Chrome copies; rebuild after a Chrome update |
| `config [--json]` | Print the effective configuration |

Exit codes: `0` ok, `1` usage or precondition, `2` template not ready (a human step is needed), `3` instance failed to come up.

## Configuration

The config lives in `~/.config/claude-browser/config.json`, or wherever `$CLAUDE_BROWSER_CONFIG` points. Every key is optional. `claude-browser config` prints the effective values.

| Key | Default | Meaning |
|---|---|---|
| `accounts` | `{}` | Account name → main-Chrome profile dir, e.g. `{"work": "Profile 3"}`. The value can also be `{"profile": "Profile 3", "badge": "W"}`. |
| `registry` | none | For setups that already keep an account registry: a JSON file holding `accounts.<name>.chrome_profile_dir`. `accounts` wins on conflict. |
| `account_detector` | none | Shell command whose stdout's first word is this session's account. Used when neither `--account` nor `$CLAUDE_BROWSER_ACCOUNT` is given. |
| `origin_command` | none | Shell command whose first stdout line names where the agent runs. Overrides pane detection; `--origin` overrides it. |
| `root` | `~/Library/Application Support/Chrome-Claude` | Base, pairings, browsers, icons, events.log |
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
| `idle_minutes` | `120` | Reap an instance after this long with no tab activity (History or session writes); `0` disables |
| `owner_process_names` | `["claude"]` | Process names that count as the owning agent; an instance whose owner has exited is reaped |

The account is resolved in this order:

1. `--account`
2. `$CLAUDE_BROWSER_ACCOUNT`
3. `account_detector`

If none of these yields an account, `up` refuses. Once a session has a running instance, re-running `up` in that session reports the instance and exits 0 without detecting the account again. So switching the machine's default Claude login mid-session does not re-identify a live session. Switch accounts per terminal (for example with `--account` or `CLAUDE_BROWSER_ACCOUNT`), not by changing the machine-wide default while browser sessions are live. The origin shown on the card and icon is resolved in this order:

1. `--origin`
2. `origin_command`
3. a herdr pane (`$HERDR_PANE_ID`)
4. a tmux pane (`$TMUX_PANE`)
5. the tty, shown as "bare"

## History and limits

`claude-browser` has been used with several Claude accounts on one Mac since October 2026. Known limits:

- **Pairing is one human click per account.** A clone whose extension storage has been reset did not mint a device id on its own in testing. The extension appears to need an interactive hand-off. So `up` reuses the saved pairing.
- **One browser per account, shared.** Two browsers with the same device id fight over the relay (last writer wins), so an account never runs two. `up` takes a lock, so concurrent `up` calls on one account end with one browser and every caller attached. Agents share its cookie jar (see the security model).
- **Tab pinning is human-only.** Chrome keeps pinned tabs and startup pages in HMAC-tracked preferences and discards outside writes. The instance card is marked by its favicon and title instead.
- **Local native messaging fails from app copies.** An instance launched from a relocated copy of Chrome cannot find the user-level native messaging hosts, even with the symlink. The relay path that `list_connected_browsers` uses does not depend on them.
- **Two connected browsers block the tools until one is selected.** When two browsers are connected to the same account (for example the agent browser and that account's profile in your main Chrome) and none is selected, claude-in-chrome tools refuse until `select_browser` runs. Agents should select the id that `up` printed before doing anything else.
- **Agents close their own tabs.** The tool cannot close another agent's tab group from outside Chrome, so a detaching agent should close its tabs first; its leftover tabs go away with the browser.

Changes are recorded in [CHANGELOG.md](CHANGELOG.md).

## Contributing

Issues and pull requests are welcome at https://github.com/johntrandall/claude-browser. Please include `claude-browser config` output (redact profile names if you like) and the relevant `claude-browser events --since 1` lines with a bug report.

Run `bash tests/test-mechanics.sh` before sending a change. It builds a throwaway base under a temporary root and runs clone, launch, list and teardown. It opens Chrome briefly and needs no login.

This project is not affiliated with Anthropic or Google.

## License

[MIT](LICENSE)
