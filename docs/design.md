# Design — Claude Code Usage Widget (KDE Plasma / Kubuntu)

> Adapted from an initial plan drafted by Claude Desktop, corrected against the
> actual target machine. Treated as a guideline, not a spec.

## Goal

A small, always-visible KDE Plasma **panel** widget (a Plasmoid), placed next to
the system clock, showing two lines:

```
5h ▓▓▓▓▓▓░░░░ 62%
7d ▓▓▓░░░░░░░ 31%
```

- Top line: current 5-hour rate limit usage
- Bottom line: current 7-day (weekly) rate limit usage
- Styled as a filled progress bar (rendered, not block characters), colored to
  indicate usage level (green → yellow → orange → red as it climbs)
- Lives permanently in the panel (not the desktop), so it stays visible above
  open windows without needing "Show Desktop"

## Data source — confirmed viable

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
fixture.

**Viability check (done):** on the target machine, Claude Code `2.1.207`
returns `rate_limits` populated with both windows. The project is not blocked on
an empty/absent field. `rate_limits` first appeared in `v1.2.80`.

Registered via `~/.claude/settings.json`:

```json
{
  "statusLine": {
    "type": "command",
    "command": "/bin/bash ~/.claude/statusline-command.sh"
  }
}
```

**Correction to the original plan:** there is *no* existing `statusLine` script
to extend on this machine — `settings.json` has no `statusLine` block today. The
writer is built from scratch. Because registering it also defines what the
in-terminal status line displays, the writer should print a useful status line
*and* write the cache as a side effect (design the human-facing line as its own
task).

## Architecture (two-part pipeline)

The JSON is only pushed to the status line script transiently (while a session
is active and a turn completes), so the widget can't query Claude Code directly
on its own schedule. One small cache file is the hand-off point.

### 1. Writer — the statusLine script

Does its normal job (rendering the terminal status line) and additionally writes
the two percentages (and reset timestamps) to a flat cache file, overwriting it
each time:

- File: `~/.claude/usage_cache.json`
- Content: the two percentages plus reset timestamps

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
handled above.

### 2. Reader — the Plasma widget

The widget polls `~/.claude/usage_cache.json` on its own timer (a QML `Timer`),
independent of whether a session is active. Between sessions it displays the
last known values. On a read/parse failure (e.g. rare mid-write timing) it keeps
showing the last good value rather than blanking or erroring.

## Polling frequency

- Reading a small local JSON file is sub-millisecond, negligible CPU.
- Every 1–5 seconds is safe and effectively "live" with no perceptible cost.
- Cost only matters if the source involves a network call or subprocess spawn —
  not the case here (local file read).

## Widget placement and styling

- **Panel widget** (target): sits in the panel row with the clock, stays visible
  above all windows at all times.
- **Desktop widget** (rejected): gets covered by open windows.
- Plasma widgets are QML, supporting full custom rendering:
  - True filled/animated progress bars (rounded-rect track + growing fill rect)
  - Custom colors/gradients keyed to usage level
  - Conditional styling (color change or pulse near a limit)
  - Smooth transitions on value change
  - Optionally a countdown to `resets_at`
- No official "Claude Code usage" Plasmoid exists — this is custom, consisting of
  a QML front-end rendering two bars plus a timer-driven file read.

**Target the Plasma 5.27 (Qt5) widget API** — `metadata.desktop` packaging and
`org.kde.plasma.*` imports — not Plasma 6 (`metadata.json`, Qt6). The machine
runs `plasmashell 5.27.12`.

## Honest scope note

"Always-visible live widget" means *live while a session is active and
completing turns, frozen at last-known between sessions*. The cache only updates
when Claude Code runs. This is inherent to the data source, not a defect.

## Build pieces

| Piece | Purpose |
|---|---|
| `~/.claude/settings.json` | Registers the `statusLine` command with Claude Code |
| statusline writer script | Reads stdin JSON, prints the terminal status line, atomically writes the cache file |
| `~/.claude/usage_cache.json` | Single source of truth the widget reads; always overwritten, never appended |
| Plasmoid (QML) | Panel widget: timer-based poll of cache file, renders two styled progress bars |

## Open questions / next steps

1. Design the human-facing terminal status line (the writer double-duties as it).
2. Decide the cache schema (percentages only vs. include `resets_at` for a
   countdown).
3. Color thresholds and near-limit behavior (static color vs. pulse).
4. Plasmoid scaffolding: `metadata.desktop`, `contents/ui/main.qml`, install path
   under `~/.local/share/plasma/plasmoids/`.
