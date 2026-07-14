#!/usr/bin/env bash
# Install (or upgrade) the Claude usage widget on this machine.
#
# Two pieces:
#   1. The statusLine writer — symlinked into ~/.claude (repo stays source of
#      truth; it's read by bash, so a symlink is fine).
#   2. The Plasma widget — installed as a real copy. This KDE build's KPackage
#      rejects symlinks that escape the package directory ("path traversal"),
#      so the plasmoid cannot be symlinked; re-run this script after editing it.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPLET_ID="org.chuckchalmers.claudeusage"

# 1. Writer
mkdir -p "$HOME/.claude"
ln -sf "$REPO_DIR/statusline/statusline-command.sh" "$HOME/.claude/statusline-command.sh"
echo "Writer symlinked: ~/.claude/statusline-command.sh"

# 1b. OAuth usage poller — symlinked like the writer (read directly by bash),
#     plus a systemd user timer that runs it every few minutes so the cache
#     stays fresh outside a terminal (e.g. the VS Code extension).
ln -sf "$REPO_DIR/poller/usage-poll.sh" "$HOME/.claude/usage-poll.sh"
echo "Poller symlinked: ~/.claude/usage-poll.sh"

if command -v systemctl >/dev/null 2>&1; then
  SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
  mkdir -p "$SYSTEMD_USER_DIR"
  cp "$REPO_DIR/poller/claude-usage-poll.service" "$SYSTEMD_USER_DIR/"
  cp "$REPO_DIR/poller/claude-usage-poll.timer" "$SYSTEMD_USER_DIR/"
  systemctl --user daemon-reload
  systemctl --user enable --now claude-usage-poll.timer \
    && echo "Poller timer enabled (systemctl --user status claude-usage-poll.timer)" \
    || echo "WARNING: could not enable poller timer; enable it manually with 'systemctl --user enable --now claude-usage-poll.timer'"
else
  echo "WARNING: systemctl not found; skipping poller timer (terminal statusLine still refreshes the cache)"
fi

# 2. Plasmoid (copy; upgrade if already present)
if kpackagetool5 --type Plasma/Applet --show "$APPLET_ID" >/dev/null 2>&1; then
  kpackagetool5 --type Plasma/Applet --upgrade "$REPO_DIR/plasmoid"
else
  kpackagetool5 --type Plasma/Applet --install "$REPO_DIR/plasmoid"
fi

echo
echo "If the widget is already on your panel, reload plasmashell to see changes:"
echo "  plasmashell --replace >/dev/null 2>&1 &"
echo
echo "One-time: register the status line in ~/.claude/settings.json:"
echo '  "statusLine": { "type": "command", "command": "/bin/bash ~/.claude/statusline-command.sh" }'
