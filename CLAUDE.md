# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

A KDE Plasma 5 panel widget showing Claude Code's 5-hour and 7-day rate-limit
usage as two progress bars. A `statusLine` writer extracts the numbers from
Claude Code's per-turn JSON payload into a small cache file; the Plasmoid polls
that cache and renders the bars. See `README.md` for install, `docs/design.md`
for the full architecture.

## Layout

- `statusline/statusline-command.sh` — the writer, registered as Claude Code's `statusLine` command
- `statusline/test_writer.sh` — writer tests (plain bash, no bats)
- `plasmoid/` — the Plasma widget package (`metadata.json` + `contents/ui/`)
- `plasmoid/contents/ui/staleness.js` — pure helper shared with its node test
- `plasmoid/test_staleness.js` — staleness helper tests (node)
- `docs/` — design doc, captured payload fixture, screenshot
- `install.sh` — installs both pieces on this machine

## Commands

```
bash statusline/test_writer.sh      # writer tests
node plasmoid/test_staleness.js     # staleness helper tests
./install.sh                        # (re)install writer + plasmoid
plasmashell --replace &             # reload the panel after a plasmoid change
```

## Conventions & constraints

- **TDD.** Both suites stay green; write a failing test before changing writer
  or staleness behaviour.
- **Target Plasma 5.27 / Qt5** — `org.kde.plasma.*` imports and `metadata.json`
  packaging. (A `metadata.desktop` package loads by ID but won't drag onto a
  panel on this build.)
- **The plasmoid is copy-installed, not symlinked.** This KDE build's KPackage
  rejects symlinks that escape the package directory. After editing anything
  under `plasmoid/`, re-run `./install.sh` and reload with `plasmashell --replace &`.
  The writer (under `statusline/`) is symlinked into `~/.claude/`, so writer
  edits take effect immediately.
- **Percentages are integers.** The writer rounds `used_percentage`; the payload
  can carry float noise (e.g. `7.000000000000001`).
- **The writer never clobbers good data.** If the payload lacks `rate_limits`, it
  leaves the cache untouched and drops the usage figures from the terminal line.
- **Colour:** Claude orange `#D97757`; red only at `used_percentage >= 100`.
  `NO_COLOR` disables status-line colour.
- The cache (`~/.claude/usage_cache.json`) has a single writer. The widget is
  read-only against it and applies the staleness rule at display time only.
