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
