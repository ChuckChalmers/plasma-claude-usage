# Design — Claude Code Usage Widget (KDE Plasma / Kubuntu)

## Goal

A small, always-visible KDE Plasma **panel** widget (a Plasmoid), placed next to
the system clock, showing two lines:

```
5h ▓▓▓▓▓▓░░░░ 62%
7d ▓▓▓░░░░░░░ 31%
```

- Top line: current 5-hour rate limit usage
- Bottom line: current 7-day (weekly) rate limit usage
- Styled as a filled progress bar (rendered, not block characters): a thin,
  pill-shaped rounded track with a solid fill, modeled on the Claude Desktop
  usage bars. Fill length carries the "how full" signal; color does not.
- Fill color is **Claude orange `#D97757`** from 0–99%, switching to **red only
  when a window is maxed out (`used_percentage >= 100`)**. The percentage value
  is always shown, so color is a binary maxed indicator, not a usage gradient.
- Lives permanently in the panel (not the desktop), so it stays visible above
  open windows without needing "Show Desktop"

## Data source

Claude Code's **status line** feature invokes a user-configured shell command
after each turn, passing a JSON payload on stdin. That payload includes a
`rate_limits` object with both values already computed — no aggregation across
session/transcript files required:

```json
"rate_limits": {
  "five_hour":  { "used_percentage": 1, "resets_at": 1783823400 },
  "seven_day":  { "used_percentage": 4, "resets_at": 1784383200 }
}
```

`resets_at` is a Unix epoch (seconds). A full captured payload is checked in at
[`statusline-payload.example.json`](statusline-payload.example.json) as a test
fixture. `rate_limits` is present in Claude Code `v1.2.80`+ (populated with both
windows on `2.1.207`).

The writer is registered via `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/bin/bash ~/.claude/statusline-command.sh"
  }
}
```

Registering a `statusLine` command also defines what Claude Code shows in the
terminal, so the writer serves double duty: it prints the terminal status line
*and* writes the cache as a side effect.

The terminal status line is a local terminal-chrome element: Claude Code runs
the command each turn and displays its stdout below the input box. Its output is
**never** added to the conversation — it costs no context tokens and is invisible
to the model. It is therefore a free surface, and the script runs regardless (it
is the only way to receive the payload). Its content:

```
Opus 4.8 · ctx 5% · 5h 62% · 7d 31%
```

model display name · context-window usage · 5-hour usage · 7-day usage. The whole
line renders in Claude orange `#D97757`; when a rate-limit window is maxed
(`used_percentage >= 100`) that window's label and percent turn red, and the rest
of the line stays orange (ANSI 24-bit; suppressed when `NO_COLOR` is set). If
`rate_limits` is absent the line omits the two usage figures.

## Architecture

The JSON is only pushed to the status line script transiently (while a session
is active and a turn completes), so the widget can't query Claude Code directly
on its own schedule. One small cache file is the hand-off point, fed by two
independent writers — the statusLine writer (terminal) and the OAuth poller (any
surface) — and read by the widget. Both write the same account-level truth
atomically, so they never conflict.

### 1. Writer — the statusLine script

Does its normal job (rendering the terminal status line) and additionally writes
the two percentages plus their reset timestamps to a flat cache file, overwriting
it each time:

- File: `~/.claude/usage_cache.json`
- Schema:

```json
{
  "five_hour": { "used_percentage": 62, "resets_at": 1783823400 },
  "seven_day": { "used_percentage": 31, "resets_at": 1784383200 },
  "updated_at": 1783820000
}
```

`resets_at` (Unix epoch seconds) is required — the reader needs it for the
staleness rule below. `updated_at` records when the cache was last written.

**Defensive write:** if the payload has no `rate_limits` object (older CLI, or a
window not yet populated), the writer does **not** overwrite the cache. It
preserves the last-good values rather than clobbering them with nulls, and the
terminal line simply omits the usage figures for that turn.

Atomic write so concurrent sessions can't corrupt the file:

```bash
tmp="$HOME/.claude/usage_cache.json.tmp.$$"
printf '%s' "$json" > "$tmp"
mv "$tmp" "$HOME/.claude/usage_cache.json"
```

`mv` on the same filesystem is atomic — a reader always sees either the complete
old file or the complete new file, never a half-written one. The `$$` (PID) in
the temp name avoids collisions across concurrent sessions.

**Concurrency note:** the 5h/7d percentages are account-level, not per-session,
so simultaneous sessions all report against the same underlying quota — there's
no "which session's number is correct" conflict, only the file-write race
handled above. The same holds for the poller below: it reports the same
account-level numbers, so it and the writer never disagree — the file is simply
whichever of them wrote last.

### 1b. Poller — the OAuth usage timer

`statusLine` runs only in a terminal. When Claude Code is driven through the VS
Code extension (or no session is running), the writer never fires and the cache
would freeze (see [Surface coverage](#surface-coverage) under Update cadence).
The poller (`poller/usage-poll.sh`, driven by a systemd user timer every ~3 min)
closes that gap by fetching the same numbers directly:

```
GET https://api.anthropic.com/api/oauth/usage
Authorization: Bearer <oauth token from ~/.claude/.credentials.json>
anthropic-beta: oauth-2025-04-20
```

This is the endpoint Claude Code itself falls back to when the statusLine payload
lacks `rate_limits`. It returns the server-computed 5h/7d utilization keyed as
`utilization` (float) and `resets_at` (ISO-8601), which the poller normalises to
the cache schema above (round to int; ISO→epoch seconds) and writes with the same
atomic `mv`. It authenticates with the **subscription** OAuth token — not an API
key — and is a read-only usage query, so it consumes no tokens and incurs no API
spend.

**Failure classification.** The endpoint is undocumented beta and may change. The
poller sorts failures into two buckets and, like the writer, never clobbers
good data:

- *Transient* (offline, timeout, HTTP 401 token expiry, HTTP 5xx) → stay silent,
  leave the last-good cache in place. These are expected and self-heal (Claude
  Code refreshes the token; the network comes back).
- *Real breakage* (HTTP 200 whose shape is no longer recognised, or a persistent
  non-401/5xx error like 404/410) → after a few consecutive occurrences, fire a
  **debounced desktop notification** (once per outage, re-armed on the next
  success) so silent drift becomes visible. A small state file
  (`~/.claude/usage_poll_state.json`) holds the consecutive-failure count and the
  "already notified" flag.

**Credentials are read-only to the poller.** It only reads the access token; it
never writes `~/.claude/.credentials.json` (Claude Code owns that and refreshes
the token). If the token is expired and no session is refreshing it, the poll
degrades transiently until the next refresh — correctness is preserved by the
reader's staleness rule.

### 2. Reader — the Plasma widget

The widget polls `~/.claude/usage_cache.json` on its own timer (a QML `Timer`),
independent of whether a session is active. On a read/parse failure (e.g. rare
mid-write timing) it keeps showing the last good value rather than blanking or
erroring.

#### Staleness rule

The cache only updates while Claude Code is running, so between sessions the
stored percentage grows stale. But the cache also carries `resets_at` per window,
which tells the reader when the stored number stops being true. On every poll
tick the widget applies, per window:

```
displayedPercent(window, now) = (now >= window.resets_at) ? 0 : window.used_percentage
```

Once a window's `resets_at` has passed, its usage has reset, so the bar drops to
0% — even with no fresh payload. This is an *inference* (a session running in a
terminal we haven't polled a payload from could already be consuming the new
window), but 0% is the correct best estimate for the common between-sessions
case, and the next payload corrects it.

This logic lives **entirely in the reader** and is **display-only** — the widget
never writes back to the cache. The writer remains the single owner of the file,
which stays honest about what was last *measured*; the widget is honest about
what is *currently true*. The writer's own terminal line never needs this rule,
because it always has a fresh payload.

The rule is implemented as an isolated pure JS helper so its logic (0%-at-reset,
value-below-reset, exactly-at-reset boundary) is verifiable with a faked `now`.

## Polling frequency

- Reading a small local JSON file is sub-millisecond, negligible CPU.
- Every 1–5 seconds is safe and effectively "live" with no perceptible cost.
- Cost only matters if the source involves a network call or subprocess spawn —
  not the case here (local file read).

## Widget placement and styling

- It is a **panel widget**: it sits in the panel row with the clock and stays
  visible above all windows. (A desktop widget would be covered by open windows.)
- Plasma widgets are QML, supporting full custom rendering:
  - True filled progress bars (rounded pill track + growing fill rect)
  - Solid Claude-orange fill, red at 100% (see Goal); no gradient
  - Smooth transitions on value change
- No official "Claude Code usage" Plasmoid exists — this is custom: a QML
  front-end rendering two bars plus a timer-driven file read.

Uses the Plasma 5.27 (Qt5) widget API — `org.kde.plasma.*` QML imports. The
machine runs `plasmashell 5.27.12`.

Packaging uses **`metadata.json`** (the `KPlugin` manifest). A `metadata.desktop`
package is a trap: it lists and loads by ID, but the widget explorer cannot
instantiate it on drag-and-drop, so only a `metadata.json` package drops onto a
panel.

Install as a **real copy** via `kpackagetool5 --install` (see `install.sh`), not
a symlink: this build's KPackage rejects symlinks that escape the package
directory ("path traversal"), so the plasmoid must be copied and re-installed
after edits. (The statusLine writer, read directly by bash, is still symlinked.)

## Update cadence

The **writer** refreshes the cache every turn, but only in a terminal. The
**poller** refreshes it every ~3 minutes regardless of surface. So during active
use the numbers are effectively live (instant in a terminal, within a few minutes
elsewhere), and between sessions the poller keeps them current until its token
expires — after which the widget falls back to the last measured values, with a
window dropping to 0% once its `resets_at` passes (the staleness rule).

### Surface coverage

`statusLine` is a **terminal-chrome** feature: it is invoked only by the `claude`
CLI in a terminal, not by the VS Code extension's sidebar UI. And `rate_limits`
rides *exclusively* on the `statusLine` payload — no hook event carries it, and
Claude Code persists no rate-limit state to disk. So the writer alone would leave
the cache frozen during VS Code-only work.

The **poller** (see [1b](#1b-poller--the-oauth-usage-timer)) covers that gap by
reading the same account-level numbers straight from the OAuth usage endpoint,
independent of any session or surface. The two writers are complementary: the
writer is the official, credential-free path that works whenever a terminal is
active; the poller is the surface-independent path that also covers the VS Code
extension and idle stretches. If the (undocumented) endpoint ever breaks, the
poller degrades quietly and notifies, and terminal sessions still refresh the
cache — so coverage never drops below the terminal-only baseline.

## Build pieces

| Piece | Purpose |
|---|---|
| `~/.claude/settings.json` | Registers the `statusLine` command with Claude Code |
| statusline writer script | Reads stdin JSON, prints the terminal status line, atomically writes the cache file |
| poller script + systemd timer | GETs the OAuth usage endpoint every ~3 min, atomically writes the same cache file (surface-independent refresh) |
| `~/.claude/usage_cache.json` | Single source of truth the widget reads; always overwritten, never appended |
| `~/.claude/usage_poll_state.json` | Poller's debounce state (consecutive failures + notified flag); not read by the widget |
| Plasmoid (QML) | Panel widget: timer-based poll of cache file, renders two styled progress bars |

## Testing

- **Writer** — feed `statusline-payload.example.json` on stdin and assert both
  the cache output and the terminal-line format. Cover the missing-`rate_limits`
  case (asserts the cache is left untouched).
- **Poller** — feed `usage-endpoint.example.json` through the script's injectable
  seams (no network/credentials) and assert: the cache is written in the widget's
  schema (`utilization`→int, ISO→epoch), transient statuses (401/5xx) stay silent,
  real breakage (unrecognised 200 body, 404) leaves the cache untouched and fires
  a debounced notification, and a success re-arms the alert.
- **Staleness helper** — unit-test the pure `displayedPercent` function with a
  faked `now`: 0%-at-reset, value-below-reset, exactly-at-reset boundary.
- **Widget rendering** — verified manually. Qt5 QML unit testing is not worth the
  harness for two bars; the testable logic is isolated in the helper above.
