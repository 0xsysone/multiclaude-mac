# How MultiClaude works

Everything here was checked against Claude Desktop 4.23118.1 on macOS 26.6 (reading the app bundle, its
logs, and live tests). Claude Desktop is not documented at this level and changes often: treat version
numbers as "last verified".

## Layout

```
/Applications/Claude.app                                        untouched, first account
/Applications/Claude B.app                                      launcher (tinted icon): starts Claude B, then quits
~/Library/Application Support/MultiClaude/Claude B/Claude.app   untouched copy, tinted icon, second account
~/Library/Application Support/MultiClaude/Claude B/icon.icns    the icon, for the router to put back
~/Library/Application Support/MultiClaude/Claude Router.app     claude:// link router, no interface
~/Library/Application Support/Claude B                          the second account's data
~/Library/LaunchAgents/app.multiclaude.router.plist             starts the router at login
~/Library/Logs/MultiClaude.log                                  what the router and launchers did
```

One Swift file (`src/MultiClaude.swift`) is built once and plays two roles, chosen by a key in the
bundle's Info.plist: `launcher` and `router`. `src/hue.swift` tints the icon.

## Why a copy, and not the same app twice

Claude's updater (Squirrel/ShipIt) refuses to install while an instance of the **same path** is running,
and an idle instance with a downloaded update quits itself to install it, stopping its sessions. Two
instances of one bundle block and kill each other in turn. With one bundle per account, each only waits
for itself.

The copy is started with `--user-data-dir=<folder>`, which the signed build honours. (Since 4.x the
`CLAUDE_USER_DATA_DIR` environment variable works too, and also moves the logs.) Neither applies when
the copy is opened directly, which is what the router is for.

The app takes no single-instance lock: two instances on the **same** data folder corrupt each other's
SQLite stores and invalidate each other's tokens. Nothing in MultiClaude ever starts two on one folder.

## What is shared, what is separate

| | First account (Claude.app) | Another account (Claude B) |
|---|---|---|
| App binary, updates | `/Applications/Claude.app` | its own copy, updated independently |
| claude.ai session, cookies, app preferences, Code session list | `~/Library/Application Support/Claude` | `~/Library/Application Support/Claude B` |
| Token used by Claude Code sessions | first account (`CLAUDE_CODE_OAUTH_TOKEN`, injected by the app) | that account (injected by its app) |
| Claude Code configuration (`~/.claude`: skills, plugins, hooks, settings, CLAUDE.md, transcripts) | shared | shared |
| App log `~/Library/Logs/Claude/main.log` | shared (all instances write to it) | shared |

Sharing `~/.claude` is deliberate: nothing to configure twice, and Code sessions of different accounts
can see and message each other (they all register in `~/.claude/sessions/`).

## The link router

Whatever comes back from the browser arrives as a `claude://` link: an account sign-in
(`claude://login/google-auth?code=…&state=…`), an MCP server's OAuth sign-in started from a Code session
(`claude://claude.ai/mcp-auth-callback/sdk?state=…&code=…`), deep links. macOS delivers a link to **one**
registered app, and every Claude re-registers itself for the scheme each time it starts
(`setAsDefaultProtocolClient`, regardless of who holds it). Left alone, a return lands in an arbitrary
instance, and the one waiting for it times out.

`Claude Router` holds the scheme (and `msauth.com.anthropic.claudefordesktop`), takes it back 2 to 12
seconds after any Claude starts, and re-checks every 10 seconds. For each link:

1. **MCP sign-in return** → the instance that started it. When a Code session opens the browser, Claude
   Desktop logs `mcpAuthenticate…: sessionId="local_…"`; that session's file exists only under the data
   folder of its own instance (`claude-code-sessions/<account>/<org>/local_….json`). Valid for 15 minutes.
   An instance only accepts this link if its `state` is the one it is waiting for.
2. **Account sign-in return** → offered to every instance. Each ignores a code that does not answer a
   sign-in it started ("Google sign-in code does not answer a sign-in this app started; ignoring").
3. **Anything else** → the Claude that was last brought to the front (the router follows app
   activations), else the one with the frontmost window, else Claude.app.

Links are forwarded as a `GetURL` Apple Event addressed to the instance's process. The log line carries
the decision and its reason, never the query string.

## The safety net

A copy started without `--user-data-dir` opens the first account's profile. It happens in two cases:
a click on the copy's own Dock tile, and Squirrel relaunching the copy after an update. The router
watches `NSWorkspace` launch notifications, reads the new process's arguments, kills a bare copy and
starts the account properly. This is what makes it safe to keep the copy itself in the Dock — one tile
that shows the running dot — and why the router runs as a login agent. Without the agent
(`--no-agent`), the router only lives while a copy does, and you open accounts through their launcher.

## The icon

The colour is a custom Finder icon: an `Icon\r` file at the bundle root plus a Finder flag. It is not
covered by the code signature (`codesign --verify --deep` still passes; `spctl -a -vv` still answers
"accepted, Notarized Developer ID"), the app launches normally, and the icon macOS reports for the
running app is the tinted one.

An update replaces the whole bundle, icon included. macOS App Management protection lets an app modify
another developer's app only when the user allowed it (System Settings › Privacy & Security › App
Management). Allowed, the router restores the icon before relaunching; not allowed, it logs the refusal
once and `./install.sh` restores it.

## macOS permissions (Files and Folders, screen, microphone…)

macOS attributes these to the "responsible process". An app started by another one inherits the
starter's responsibility, so a naively launched copy would be judged as the launcher — an ad hoc signed
helper with none of Claude's permissions. Launchers and the router start Claude with `posix_spawn` and
`responsibility_spawnattrs_setdisclaim` (what Chromium and Electron do themselves): the copy is its own
responsible process, identity `com.anthropic.claudefordesktop`, and **shares Claude.app's permissions**.

Unrelated to MultiClaude but easy to trip on: Code sessions are started through the app's `disclaimer`
helper, so the client that reads your Downloads folder from a session is "Claude Code"
(`com.anthropic.claude-code`), not "Claude". A denial recorded for it blocks every session of every
account without asking again. To be asked again:

```bash
tccutil reset SystemPolicyDownloadsFolder com.anthropic.claude-code
```

## Claude in Chrome

The extension's account is the claude.ai session of the Chrome profile it lives in, not the desktop
app's. Each desktop instance pairs with one extension and remembers it in its own
`claude_desktop_config.json`. For another account, use a Chrome profile signed in to claude.ai with that
account; at the first browser tool call, its Claude asks which connected browser to use. To choose
again, quit that Claude and remove the `chromeExtension` key from its `claude_desktop_config.json`.

## Known limits

- The MCP rule reads Claude Desktop's log format; if it changes, MCP returns fall back to rule 3.
- A real MCP OAuth round trip was not replayed end to end during development: the link delivery, the
  owner lookup on a real log, and the app's `state` check were each verified separately.
- The Dock keeps a pinned app by its path; a Claude update replaces the copy at the same path. If a tile
  ever goes stale, `./install.sh` re-pins it.
- Tested with two and three accounts.
