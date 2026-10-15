# CLAUDE.md

Guidance for Claude Code working in this repository.

## What this is

A KDE Plasma 5 panel widget showing Claude Code's 5-hour and 7-day rate-limit
usage as two progress bars. Two writers feed one cache file: a `statusLine`
writer extracts the numbers from Claude Code's per-turn JSON payload (terminal
only), and a systemd-timer poller fetches the same numbers from the OAuth usage
endpoint (any surface — covers the VS Code extension). The Plasmoid polls that
cache and renders the bars. See `README.md` for install, `docs/design.md` for the
full architecture.

## Layout

- `statusline/statusline-command.sh` — the writer, registered as Claude Code's `statusLine` command
- `statusline/test_writer.sh` — writer tests (plain bash, no bats)
- `poller/usage-poll.sh` — the OAuth usage poller (second cache writer, surface-independent)
- `poller/claude-usage-poll.{service,timer}` — systemd user units that run the poller every ~3 min
- `poller/test_poll.sh` — poller tests (plain bash, hermetic via env seams)
- `attention/attention.sh` — the attention tracker: a hook that records sessions waiting on you, the `list` command the widget polls, and the `focus` command a click runs to jump to a session's Yakuake tab
- `attention/test_attention.sh` — tracker tests (plain bash, hermetic via `ATTENTION_FILE` / `ATTENTION_PID` / `ATTENTION_NOW` / `ATTENTION_QDBUS`, the last pointing at a fake `qdbus` that stands in for Yakuake)
- `plasmoid/` — the Plasma widget package (`metadata.json` + `contents/ui/`)
- `plasmoid/contents/ui/staleness.js` — pure helper shared with its node test
- `plasmoid/test_staleness.js` — staleness helper tests (node)
- `plasmoid/contents/ui/attention.js` + `AttentionBadge.qml` — badge helper (pure, node-tested) and the badge itself
- `plasmoid/contents/ui/SessionList.qml` — the interactive tooltip listing waiting sessions; a click on a row jumps to that session
- `plasmoid/test_attention.js` — badge helper tests (node)
- `docs/` — design doc, captured payload + endpoint fixtures, screenshot
- `install.sh` — installs all pieces (writer, poller, and tracker symlinks; poller timer; plasmoid copy) on this machine

## Commands

```
bash statusline/test_writer.sh      # writer tests
bash poller/test_poll.sh            # poller tests
node plasmoid/test_staleness.js     # staleness helper tests
bash attention/test_attention.sh    # attention tracker tests
node plasmoid/test_attention.js     # badge helper tests
./install.sh                        # (re)install writer + poller/timer + plasmoid
plasmashell --replace &             # reload the panel after a plasmoid change
systemctl --user status claude-usage-poll.timer   # is the poller scheduled?
journalctl --user -u claude-usage-poll -n 20       # why did a poll fail?
```

## Conventions & constraints

- **TDD.** All suites stay green; write a failing test before changing writer,
  poller, tracker, staleness, or badge behaviour.
- **Target Plasma 5.27 / Qt5** — `org.kde.plasma.*` imports and `metadata.json`
  packaging, the package format this build's panel accepts when you drag a
  widget onto it.
- **The plasmoid is copy-installed.** This KDE build's KPackage rejects
  symlinks that escape the package directory, so `install.sh` copies the
  package. After editing anything
  under `plasmoid/`, re-run `./install.sh` and reload with `plasmashell --replace &`.
  The writer, poller, and tracker scripts (`statusline/`, `poller/`, `attention/`) are symlinked into
  `~/.claude/`, so script edits take effect immediately. **The systemd units are
  copied** to `~/.config/systemd/user/`, so after editing a `.service`/`.timer`
  re-run `./install.sh` (it reloads and restarts the timer).
- **Percentages are integers.** The writer rounds `used_percentage`; the payload
  can carry float noise (e.g. `7.000000000000001`).
- **Neither writer clobbers good data.** If the statusLine payload lacks
  `rate_limits`, the writer leaves the cache untouched (and drops usage from the
  terminal line). Likewise the poller leaves the cache untouched on any failure —
  offline, timeout, bad/expired token, non-200, or an unrecognised response body.
  Worst case the cache is stale, and the widget's staleness rule bounds how stale.
- **The poller authenticates with the subscription OAuth token.**
  `poller/usage-poll.sh` GETs `https://api.anthropic.com/api/oauth/usage` with the
  OAuth token from `~/.claude/.credentials.json` — read-only, zero token cost, no
  API spend. It only reads the credentials file, which Claude Code owns. The
  endpoint is undocumented beta and can change; the poller classifies failures
  (transient = silent; real breakage = a debounced `notify-send`) so drift is
  visible. Change the poll cadence via `OnUnitActiveSec=` in the `.timer`.
- **The tooltip is a `PlasmaCore.ToolTipArea` with `interactive: true`.**
  `Plasmoid.toolTip*` only appears for a compact representation, and this widget
  always shows its full one; `interactive` keeps the tooltip open while the
  mouse moves into it, so its rows can be clicked. The tooltip window tracks
  `SessionList`'s `width`/`height` and `Layout` sizes, which are bound to its
  implicit size so the window grows upward as rows arrive while it's open.
- **Yakuake terminal ID = Konsole session number − 1.** The shell PID lives on
  the Konsole session (`/Sessions/N`), and Yakuake creates one Konsole session
  per terminal. The offset is inferred from that, so `focus` confirms it across
  all terminals before switching tabs; when it doesn't hold, a click just opens
  Yakuake.
- **Colour:** Claude orange `#D97757`; red only at `used_percentage >= 100`.
  `NO_COLOR` disables status-line colour.
- The cache (`~/.claude/usage_cache.json`) has two writers (statusLine writer +
  poller) that both report the same account-level quota and write atomically, so
  the last write wins and they agree. The widget is read-only
  against it and applies the staleness rule at display time only.
