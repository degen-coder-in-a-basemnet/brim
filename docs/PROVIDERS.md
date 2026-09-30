# Providers

Every provider declares how trustworthy its figures are:

- **Official**: the vendor's own number, relayed without change.
- **Derived**: worked out by Brim from local data. Always shown with `≈`.
- **Manual**: entered by you.
- **Local**: counts and timings from a runtime on this Mac. No limit, so no percentage.
- **Unsupported**: not implemented, and why.

Brim never shows a percentage it can't back: with no budget, a derived window shows
token counts only.

## Support matrix

| Provider | Classification | Default | Source | Network | Windows | Sessions |
|---|---|---|---|---|---|---|
| Claude Code | Official when current, else derived | On | Status-line handoff file, `~/.claude/projects`, `~/.claude/sessions`, `~/.claude.json` (usage cache only); opt-in: `claude /usage`, or the usage endpoint with Claude Code's keychain sign-in | None by default. Opt-in: `/usage` via Claude Code, or `api.anthropic.com/api/oauth/usage` directly | Current session (5 h), All models (7 d), Opus/Sonnet weekly when Anthropic reports them | Busy, waiting, finished, stale |
| Codex | Official | On | `~/.codex/sessions/**/rollout-*.jsonl` | None | Primary and secondary windows as Codex records them (e.g. 5 h, weekly, monthly on Free), plus plan | Busy, waiting for approval, finished, stale |
| Manual | Manual | When added | Your entries | None | Any you define, with reset schedules | — |
| Ollama | Local | Off | 127.0.0.1 `/api/ps`, `/api/version`; `~/.ollama/logs` | Loopback | Loaded models, requests, timings | — |
| LM Studio | Local | Off | 127.0.0.1 `/api/v0/models`; `~/.lmstudio/server-logs` | Loopback | Loaded models, requests, timings | — |
| Demo | Sample data | `--demo` only | Generated in the app | None | Fixed scenes | Simulated |

## Claude Code in detail

Figures, in order of trust:

1. **A logged rejection.** When Anthropic refuses a request, Claude Code records the
   limit type and reset time in the transcript. That window shows an official 100%
   until it resets.
2. **Anthropic's reported percentage**, from whichever of these reported last:
   - **Claude Code's status line**, the main source. After every reply, Claude Code
     hands your status-line command Anthropic's `rate_limits`. With Brim's lines added
     to that command (Settings › Claude Code › "Copy the lines…"), it passes the
     percentages and reset times on in `claude-statusline.json`. As fresh as your last
     reply, and local.
   - **Claude Code's cache.** Each time Claude Code fetches your usage (running `/usage`
     does), it keeps Anthropic's answer in `~/.claude.json`. Brim cuts out that one entry.
   - **`claude /usage`** (opt-in). Brim runs the command on a timer.
   - **Anthropic's usage endpoint** (opt-in: "Refresh while Claude Code is closed").
     When nothing local has reported for 10 minutes, Brim asks
     `https://api.anthropic.com/api/oauth/usage`, signed with Claude Code's sign-in.
     Brim reads that from the keychain only when you click. See
     [PRIVACY.md](PRIVACY.md#keychain-optional-off-by-default).

   With nothing logged since the report, the figure shows as official.
3. **Estimate on top.** Responses logged after that report are added as a `≈` estimate,
   and the card names the report it started from ("Anthropic said 78% at 19:05").
4. **Estimate alone.** With no report for the current window, the percentage is the
   window's weighted tokens over a budget. Weights: input 1, output 5, cache writes
   1.25, cache reads 0.1.

A window opens with the first request after the previous one closed, and runs five
hours. It isn't aligned to the hour: Anthropic's reported reset times pin it exactly.
The budget is measured from Anthropic's own figures: the spend at a logged limit hit,
the spend behind a reported percentage, or better, the rise between two reports of the
same window. A budget you type in Settings overrides the measured one. Derived
estimates stop at 99%: only Anthropic can say a limit is spent.

The logs only see this Mac's Claude Code. Usage on claude.ai, other devices or from
tools that call the API outside Claude Code's transcripts counts against the same
limits without appearing in them. That's why reported figures always win over
estimates, and why the status-line handoff, which reports after every reply,
matters most.

## Unsupported, on purpose

| Provider | Why not |
|---|---|
| Cursor | Usage needs the editor's session token from its local database. Reading it would be credential access. Use a Manual provider instead. |
| GitHub Copilot | Quota is only exposed by an authenticated GitHub endpoint. Shows "Needs authentication". |
| Gemini CLI | Keeps no local record of quota. Would need authenticating to Google's API. |
| ChatGPT (web) | Only the signed-in web session knows the limits, and Brim does not read browser cookies. |
| Claude Desktop cache | The figures sit in Claude Desktop's private HTTP cache, another app's internal storage. |
| Vendor API keys | Brim never asks for API keys. Use a Manual provider for API budgets. |

## Adding a provider

Adapters implement `UsageProvider` (`Sources/BrimCore/Providers/UsageProvider.swift`)
and return `ProviderSnapshot`s. The UI knows nothing about how a figure was fetched.
A new adapter must declare its `Fidelity` and `NetworkUse`, and add its `dataAccess`
lines (shown in Settings). It reads files only through `LocalFileAccess` roots, makes
HTTP requests only through `LoopbackHTTPClient`, and runs programs only through
`ProcessRunner`. Anything networked starts switched off. Update this file and
`docs/PRIVACY.md`, and make `scripts/privacy-audit.sh` pass.
