# plasma-claude-usage

A KDE Plasma panel widget (Plasmoid) that shows Claude Code rate-limit usage —
the 5-hour and 7-day windows — as two always-visible progress bars next to the
system clock.

![Claude Usage widget](docs/widget.png)

## How it works

Claude Code's status line feature invokes a shell command after each turn,
passing a JSON payload on stdin that includes a `rate_limits` object with both
percentages already computed. That payload is only pushed *transiently* while a
session is active, so a panel widget can't query it on demand.

The bridge is a single cache file:

1. **Writer** (`statusline/statusline-command.sh`) — a `statusLine` command
   registered in `~/.claude/settings.json`. It prints the terminal status line
   and atomically writes the two percentages (plus reset timestamps) to
   `~/.claude/usage_cache.json`.
2. **Reader** (`plasmoid/`) — the Plasmoid polls that cache file every 2s and
   renders two styled progress bars, independent of whether a session is active.

### Behavior

- Bars fill in Claude orange (`#D97757`); a window turns red only when it reaches
  100%.
- Between sessions the bars show the last measured values — except a window drops
  to **0%** once its reset time (`resets_at`) passes, since that window has reset
  even without a fresh payload.
- The terminal status line reads e.g. `Opus 4.8 · ctx 5% · 5h 62% · 7d 31%`
  (same orange/red rule). It costs no tokens and is invisible to the model.

See [`docs/design.md`](docs/design.md) for the full design.

## Install

```
./install.sh
```

This symlinks the writer into `~/.claude/` and installs the Plasmoid as a copied
package (this KDE build rejects symlinked packages). Then:

1. Register the status line in `~/.claude/settings.json`:

   ```json
   "statusLine": {
     "type": "command",
     "command": "/bin/bash ~/.claude/statusline-command.sh"
   }
   ```

2. Add the widget to the panel: right-click the panel → **Add Widgets…** →
   search **Claude Usage** → drag it next to the clock.

After editing the Plasmoid, re-run `./install.sh` and reload with
`plasmashell --replace &` — the installed copy does not track the repo.

## Tests

- `bash statusline/test_writer.sh` — the writer (cache write, terminal line,
  coloring, defensive no-clobber, integer rounding).
- `node plasmoid/test_staleness.js` — the staleness helper.

## Target environment

- **KDE Plasma 5.27** (Qt5) — the Plasmoid targets the Plasma 5 widget API
  (`metadata.json` packaging, `org.kde.plasma.*` QML imports), not Plasma 6.
- **Claude Code ≥ 1.2.80** — the first version to expose `rate_limits` in the
  status line JSON (populated on `2.1.207`).
