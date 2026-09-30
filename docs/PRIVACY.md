# Privacy and network behaviour

Brim is local-first. With the default settings it opens **no network connections**:
it reads a few files in your home folder and draws a notch. This page lists every
file it reads, every program it runs, every address it may contact and every file it
writes. `scripts/privacy-audit.sh` and `scripts/netcheck.sh` check these claims
against the source, the built binary and the running app.

## Never

- No backend, proxy, cloud sync, analytics, telemetry, crash-report upload, remote
  configuration, third-party tracking or automatic update check.
- No keychain access by default. The one exception is the optional Claude fallback (below):
  once you switch it on, and only when you click, it reads Claude Code's sign-in with
  `SecItemCopyMatching` and nothing else. The audit fails if any other keychain call
  appears, or if anything could write, renew or go around macOS's prompt.
- No credential files, browser cookies or other apps' private storage. Brim never asks
  you to paste an API key or export anything.
- Prompts, replies, message text, source files and raw provider output are never
  stored, logged, displayed or sent anywhere. Parsers name only the fields they need,
  so message content is skipped rather than decoded.

## Network

| When | What | Where |
|---|---|---|
| Default | Nothing | Nothing |
| Ollama switched on | `GET /api/ps`, `GET /api/version` | `http://127.0.0.1:<port>` (default 11434) |
| LM Studio switched on | `GET /api/v0/models` | `http://127.0.0.1:<port>` (default 1234) |
| Claude Code › "Ask claude /usage" switched on | Brim runs your installed `claude`; Claude Code contacts `api.anthropic.com` with its own login | Anthropic, via Claude Code |
| Claude Code › "Refresh while Claude Code is closed" switched on, and nothing local has reported for 10 minutes | `GET /api/oauth/usage` with `Authorization: Bearer <Claude Code's access token>`, `anthropic-beta: oauth-2025-04-20`, `User-Agent: Brim`. No body, at most every 5 minutes (10 by default) | `https://api.anthropic.com` only |
| You choose "Open usage page" | Your browser opens `https://claude.ai/settings/usage` or `https://chatgpt.com/codex/settings/usage` | Your browser |

Loopback HTTP goes through one client (`Sources/BrimCore/Networking/LoopbackHTTPClient.swift`).
It is pinned to `127.0.0.1`, accepts only each adapter's allowlisted paths, and uses an
ephemeral session with no cookies, cache, proxy or redirects. The app's ATS exception is
`NSAllowsLocalNetworking` only. Loopback requests never leave the Mac.

The only request that leaves the Mac is the opt-in Claude fallback, made by
`Sources/BrimCore/Networking/AnthropicUsageClient.swift`. It is pinned to
`https://api.anthropic.com/api/oauth/usage`, uses a fresh ephemeral session per
request (no cookies, cache, credential store or proxy), and refuses every redirect,
so the token can't be carried to any other address. It uses TLS with the system's
certificate checks. The answer is parsed for its percentages and reset times, then
dropped. Neither the token nor the response is logged or stored.

## Keychain (optional, off by default)

Only with Claude Code › "Refresh while Claude Code is closed" switched on:

- **What is read:** the newest generic-password item with the service
  `Claude Code-credentials` in your login keychain, the item Claude Code keeps its
  sign-in in. Finding the newest reads only attributes (modification dates). Its
  contents are then read once. From the JSON inside, Brim decodes `accessToken`,
  `expiresAt` and `subscriptionType` only. The refresh token is never decoded.
- **When:** only when you click: switching the option on, or "Allow access…". Never on
  a timer and never at launch. macOS shows its own prompt first. Declining leaves
  everything off until you click again.
- **Kept where:** in memory only, until it expires, Anthropic rejects it (Claude Code
  has renewed its sign-in), or you switch the option off. It is never written to
  disk, logged, printed, shown, or included in any snapshot or error message.
- **Sent where:** only in the `Authorization` header of the request above.
- **Never:** Brim never writes to the keychain, never renews or refreshes the sign-in
  (that would change a credential Claude Code owns), and never reads it through
  `/usr/bin/security` or any other way around macOS's prompt.
- **Token rotation:** when Claude Code renews its sign-in, the copy Brim holds stops
  working. Brim drops it and shows "expired", then waits for your next "Allow
  access…". It never retries the keychain by itself.
- **Revoking:** switch the option off ("Switch off and forget the sign-in" drops it
  from memory at once). If you chose "Always Allow" at the macOS prompt, remove Brim
  from the item's Access Control in Keychain Access. Claude Code files a new item each
  time it renews, so an allowance also lapses by itself.

## Files read

Every read goes through `LocalFileAccess`, which refuses any path outside these roots
(after resolving symlinks):

| Path | Used by | What is taken |
|---|---|---|
| `~/.claude/projects/**/*.jsonl` | Claude Code | Per response: timestamp, model, token counts, message/request id. Rate-limit rejections: type, reset time. Message text is never decoded. |
| `~/.claude/sessions/*.json` | Claude Code | Each session's status, working folder, process id, start time. The session's title is shown only if you switch that on, and never stored. |
| `~/.claude.json` | Claude Code | Only the top-level `cachedUsageUtilization` entry (Anthropic's percentages, reset times and fetch time, as Claude Code last cached them). A byte scan cuts that entry out, and nothing else in the file (account details, history) is decoded. Switch off under Claude Code › "Read the usage figures Claude Code caches". |
| `~/Library/Application Support/Brim/claude-statusline.json` | Claude Code | Written by your status-line command if you add Brim's lines to it: Anthropic's session and weekly percentages, their reset times, and when they were handed over. Nothing else. |
| `~/.codex/sessions/**/rollout-*.jsonl` | Codex | `token_count` events' rate-limit figures and plan type, and task start/complete events. Messages are never decoded. |
| `~/.ollama/logs/` | Ollama (when on) | Request counts and timings from server log lines. |
| `~/.lmstudio/server-logs/` | LM Studio (when on) | Request counts and timings. Never a prompt or reply. |
| `~/Library/Application Support/Brim/` | Brim | Its own settings and cached readings. |

Brim also asks the kernel whether a session's process id is still alive (to drop dead
sessions). For Codex, which writes no process id, it lists the names of the files open
in processes called `codex`, to learn which one is writing each session's rollout file.
It reads nothing from them. When you click a session row, double-click a ring or click a
session notification, it looks up, at that moment only, the app the session's process runs
under (its parent processes) and its terminal device. Process ids and devices are held in
memory for routing the click and are never stored or logged. Brim reads no other process's
memory or file contents.

## Apple Events

Only when you click a session whose agent runs in Terminal or iTerm2, and only if you
allow it when macOS asks, Brim sends that terminal one script. The script reads each
tab's device name (for example `/dev/ttys003`), selects the tab whose device matches the
session's, and brings its window forward. It never reads a tab's contents or history, and
it runs nothing in the terminal. If you refuse, Brim simply brings the terminal forward.
You can change your answer in System Settings › Privacy & Security › Automation. Other
apps (Cursor, VS Code, Ghostty, the Codex app and so on) are only brought forward.

## Programs run

Only with Claude Code › "Ask claude /usage for official figures" switched on (off by
default). Brim runs the first `claude` it finds in `~/.local/bin`, `~/.claude/local`,
`~/.npm-global/bin`, `~/.bun/bin`, `~/.nvm/versions/node/*/bin`, `/opt/homebrew/bin` or
`/usr/local/bin`:

```
claude --print --safe-mode --no-session-persistence --strict-mcp-config /usage
```

It runs from `~/Library/Application Support/Brim/claude-usage`, at most every 5 minutes
(10 by default), with a timeout. `--safe-mode` keeps your hooks, plugins and MCP servers
from starting. `--no-session-persistence` keeps it from writing a transcript. Only the
"Current session / Current week" lines and the plan line are parsed. The output is
held in memory for parsing and then dropped.

There are no other subprocesses. `ProcessRunner` is the only code that can start one.

## Files written

| Path | Contents |
|---|---|
| `~/Library/Application Support/Brim/settings.json` | Your preferences: placement, size, accent, provider order and switches, manual providers, budgets. |
| `~/Library/Application Support/Brim/last-readings.json` | Last reading per provider (window labels, % used, reset times, token totals, source line), plus measured Claude budgets with their timestamps. No text from any log. |
| `~/Library/Application Support/Brim/Demo/` | The same, for demo mode. |
| `~/Library/Application Support/Brim/claude-usage/` | Empty working folder for the optional `claude /usage` run. |
| `~/Library/Preferences/local.brim.Brim.plist` | The Settings window's position. |

`claude-statusline.json` in the same folder is written by your status-line command,
not by Brim. The lines Brim suggests (Settings › Claude Code › "Copy the lines…") write
only `version`, `updated_at`, and `five_hour` / `seven_day` each with
`used_percentage` and `resets_at`, `0600`, atomically, and only if Brim's folder exists.

Files are written atomically, `0600`, in a `0700` folder.

## Notifications and logs

Notifications carry Brim's own summary: provider name, window, percentage, reset time,
and for sessions, the folder name. Permission is requested at the first real alert.
Brim's log lines (`os.Logger`, subsystem `local.brim.Brim`) are fixed event names. No
figures, paths or file contents are logged.

## Turning things off

Settings › Providers has a switch for every provider and each optional source:

- **Claude Code**: "Show Claude Code" off stops every read of `~/.claude*`, the
  handoff file and the keychain. The cache read, budget sizing, `claude /usage` and
  "Refresh while Claude Code is closed" each have their own switch. To stop the
  status-line handoff, remove `writeBrimHandoff` from your status-line command.
- **Codex**: "Show Codex" off.
- **Ollama / LM Studio**: off by default. The log reading has its own switch.
- **Manual**: delete the provider.
- **Demo**: only exists with `--demo`.

Removing Brim: `bash scripts/uninstall.sh`.
