# plasma-claude-usage

A KDE Plasma panel widget (Plasmoid) that shows Claude Code rate-limit usage —
the 5-hour and 7-day windows — as two always-visible progress bars next to the
system clock.

```
5h ▓▓▓▓▓▓░░░░ 62%
7d ▓▓▓░░░░░░░ 31%
```

## Status

**Planning.** Design is settled and viability is confirmed on the target
machine (see below); the writer script and the Plasmoid are not yet built.

## How it works

Claude Code's status line feature invokes a shell command after each turn,
passing a JSON payload on stdin that includes a `rate_limits` object with both
percentages already computed. That payload is only pushed *transiently* while a
session is active, so a panel widget can't query it on demand.

The bridge is a single cache file:

1. **Writer** — a `statusLine` command registered in `~/.claude/settings.json`
   extracts `rate_limits` from stdin and atomically writes the two percentages
   (plus reset timestamps) to a small cache file.
2. **Reader** — the Plasmoid polls that cache file on its own timer and renders
   two styled progress bars, independent of whether a session is active.

Between sessions the bars show the last known values (the cache only updates
while Claude Code is running and completing turns).

See [`docs/design.md`](docs/design.md) for the full design.

## Target environment

- **KDE Plasma 5.27** (Qt5) — the Plasmoid targets the Plasma 5 widget API
  (`metadata.json` packaging, `org.kde.plasma.*` QML imports), not Plasma 6.
- **Claude Code ≥ 1.2.80** — first version to expose `rate_limits` in the
  status line JSON. Verified populated on `2.1.207`.
