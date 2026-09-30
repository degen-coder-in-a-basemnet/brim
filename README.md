# Brim

A small black notch on the edge of your screen that shows how much of your AI
coding limits you have used. Private and local-first: by default it reads a few
files on your Mac and opens no network connections at all.

Brim recreates the look and feel of [Codenotch](https://github.com/vinzdg/codenotch)
by Vinz (MIT). It has its own name, bundle identifier (`local.brim.Brim`), icon, ad-hoc
local signing and data layer, and no update feed, backend or remote service.
See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## What it does

- A black notch welded to any screen edge. On the left or right it runs vertically;
  on the top or bottom, horizontally. Along the top of a display with a camera housing,
  it takes the housing's shape.
- At rest it folds to a slim pill. Hovering unfolds it into one ring per provider
  (percentage used, the provider's glyph, green → yellow → red as the limit nears).
- Hover a ring for its card: every limit window, % used, reset time, stale, error or
  authentication state, and where the figure came from. Estimates carry a `≈`.
- Click a ring for its action (open the usage page, adjust a manual counter, focus a
  session). Right-click for the menu: refresh one or all, open the usage page, adjust or
  reset a manual counter, keep open, recentre, hide for an hour, demo mode, settings, quit.
- The orb past the end of the notch shows as an arc; hover it for the gear, click it
  for Settings.
- ⌥-drag slides the notch along its edge. The offset is remembered per edge, and
  "Recentre" resets it. One notch per display, or only the main one.
- Session indicators for Claude Code and Codex: busy (spinning arc), finished,
  waiting for you, stale. The notch peeks open briefly when a session finishes.
- When a session stops to wait for you, its ring turns amber with a dash chasing
  round it, and the notch stays open until you click that ring; the other rings stay
  as they are. A click acknowledges it, and a double-click also brings the session's
  app forward. A later wait asks again. With reduced motion the dash holds still.
  "Hide" still hides. Clicking the notification can also bring the session's app forward.
- Double-click any ring to go to that provider: its waiting session, else its most recently
  active one, else its own app (Cursor opens if it isn't running). Click a session in a card
  to go to exactly that session. In Terminal and iTerm2 the session's tab is selected, once
  you allow it when macOS asks. A single click on a quiet ring still refreshes (or opens its
  usage page) but waits out the double-click interval first, so a double-click never refreshes.
- Notifications at 80% and 100% of a limit, once per crossing.
- Last-known readings persist and are dimmed when stale, never passed off as live.
- Demo mode shows deterministic sample data and keeps its settings apart.

## Build, run, test

Needs macOS 15 or later and the Xcode Command Line Tools (Swift 6). Xcode itself is
not required. There is no prebuilt download; you build it yourself:

```sh
xcode-select --install     # once, if you don't have the Command Line Tools yet
git clone https://github.com/degen-coder-in-a-basemnet/brim.git
cd brim
make install               # builds, then copies Brim.app to ~/Applications
open ~/Applications/Brim.app
```

Everything else:

```sh
make build       # build/Brim.app, release, ad-hoc signed
make run         # build and open
make demo        # a separate instance with sample data (--demo)
make test        # the test suite (build/test/brim-tests)
make audit       # privacy audit of the source and the built binary
make netcheck    # watch the running app's sockets; fails on anything non-loopback
make snapshots   # render every visual state offline to build/snapshots
make install     # copy to ~/Applications
make uninstall   # remove the app, its settings and its cached readings
```

Every target is a thin wrapper over `scripts/`, so `bash scripts/build.sh` and friends
work without `make`. Brim builds with plain `swiftc` rather than SwiftPM or Xcode:
`scripts/common.sh` explains why and picks an SDK the installed compiler can read.
`CONFIG=debug bash scripts/build.sh` gives an unoptimised build. `bash scripts/test.sh
Claude` runs only the suites whose names match.

## Providers

| Provider | Figures | On by default | Network |
|---|---|---|---|
| Claude Code | Anthropic's own, handed over by Claude Code's status line after every reply; estimated from local logs in between (`≈`) | yes | none, unless you switch on `claude /usage` or "Refresh while Claude Code is closed" |
| Codex | Official: the rate-limit figures Codex records in its session logs | yes | none |
| Manual | Limits you enter yourself | when you add one | none |
| Ollama | Local counts and timings (no percentages) | no | 127.0.0.1 only |
| LM Studio | Local counts and timings (no percentages) | no | 127.0.0.1 only |

Details, and the providers Brim deliberately does not support, are in
[docs/PROVIDERS.md](docs/PROVIDERS.md).

### Live Claude figures

Claude Code gives Anthropic's exact figures only to your status-line command, after
every reply. To pass them on to Brim, add the lines from Settings › Claude Code ›
"Copy the lines for a JavaScript status line" to that command, and call
`writeBrimHandoff(data)` with its parsed input. They write the session and weekly
percentages and their reset times to `~/Library/Application Support/Brim/claude-statusline.json`,
and nothing else. The notch then matches your status line.

While Claude Code is closed, nothing is handed over. Brim keeps the last figure and
estimates on top. If you want it to check with Anthropic in the meantime, switch on
"Refresh while Claude Code is closed". That reads Claude Code's sign-in from the
keychain when you click, and asks `api.anthropic.com` directly; see
[docs/PRIVACY.md](docs/PRIVACY.md#keychain-optional-off-by-default).

## Privacy

- No backend, analytics, telemetry, crash uploads, remote config or update checks.
- No keychain access by default. The optional Claude fallback reads Claude Code's
  sign-in only when you click, read-only, and sends it to Anthropic's usage endpoint
  alone. No credential files, and Brim never asks for an API key.
- Message and prompt text is skipped while parsing, never kept, logged or stored.
- Everything Brim reads, runs and writes is listed in [docs/PRIVACY.md](docs/PRIVACY.md).
  `make audit` and `make netcheck` check those claims.

## Removing Brim

`make uninstall` (or `bash scripts/uninstall.sh`) quits Brim and deletes the app,
`~/Library/Application Support/Brim` and its preferences file. Nothing belonging to
Claude Code, Codex, Ollama or LM Studio is touched, since Brim only ever read those.

## Known limitations

- Claude Code percentages are exact as of Anthropic's last report: after every reply
  with the status-line handoff, otherwise when Claude Code last fetched usage. Between
  reports Brim adds what the local logs show since, as a `≈` estimate. The logs can't
  see usage from other devices, claude.ai, or background tools on the same account,
  so an estimate can drift until the next report.
- The keychain fallback holds Claude Code's sign-in only until it expires or Claude Code
  renews it. Then it needs another "Allow access…", and after every relaunch too. macOS
  may ask each time, because Claude Code files its sign-in in a way that an
  "Always Allow" rarely outlasts.
- With no report in the current window, the budget comes from the last report or
  limit hit, and is weighted by token type in a model-agnostic way.
- Ollama and LM Studio adapters are built and unit-tested against recorded shapes,
  but were not exercised against live servers on the machine this was written on.
- The top placement takes the camera housing's shape but does not split the rings
  around the camera.
- Ad-hoc signed: Gatekeeper will ask the first time a copy is opened on another Mac.
