#!/usr/bin/env bash
# Tests for the attention tracker.
#
# Plain-bash harness (no bats dependency). Run from anywhere:
#   bash attention/test_attention.sh
#
# ATTENTION_FILE keeps tests off the real ~/.claude/attention.json, and
# ATTENTION_PID stands in for the Claude Code process the hook would find.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TRACKER="$SCRIPT_DIR/attention.sh"

pass=0
fail=0

check() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    printf 'ok   - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s\n        expected: [%s]\n        actual:   [%s]\n' \
      "$name" "$expected" "$actual"
    fail=$((fail + 1))
  fi
}

tmp_dir="$(mktemp -d)"
sleep 300 &
LIVE_PID=$!
trap 'kill "$LIVE_PID" 2>/dev/null; rm -rf "$tmp_dir"' EXIT

export ATTENTION_FILE="$tmp_dir/attention.json"
export ATTENTION_PID="$LIVE_PID"

reset() { rm -f "$ATTENTION_FILE"; }

# hook <event> <session> [extra jq object fields]
hook() {
  local event="$1" session="$2" extra="${3:-}"
  jq -n --arg e "$event" --arg s "$session" \
    "{hook_event_name: \$e, session_id: \$s, cwd: (\"/home/u/Source/proj-\" + \$s)${extra:+, $extra}}" \
    | bash "$TRACKER" hook
}

# Project names per group; the session IDs alongside them are checked separately.
list() { bash "$TRACKER" list | jq -c '{blocked: [.blocked[].project], turn: [.turn[].project]}'; }

# --- marking ------------------------------------------------------------------
reset
hook Stop a
check "Stop marks the session done" \
  '{"blocked":[],"turn":["proj-a"]}' "$(list)"

reset
hook Notification a '"notification_type": "permission_prompt"'
check "permission prompt marks the session blocked" \
  '{"blocked":["proj-a"],"turn":[]}' "$(list)"

reset
hook PreToolUse a '"tool_name": "AskUserQuestion"'
check "a question to the user marks the session blocked" \
  '{"blocked":["proj-a"],"turn":[]}' "$(list)"

reset
hook Stop a
hook Notification a '"notification_type": "idle_prompt"'
check "idle reminder leaves the state alone" \
  '{"blocked":[],"turn":["proj-a"]}' "$(list)"

reset
hook Notification a '"message": "Claude is waiting for your input"'
check "idle reminder without notification_type is ignored" \
  '{"blocked":[],"turn":[]}' "$(list)"

reset
hook Notification a '"notification_type": "permission_prompt"'
hook Stop a
check "Stop after a prompt moves the session to done" \
  '{"blocked":[],"turn":["proj-a"]}' "$(list)"

# --- clearing -----------------------------------------------------------------
for event in UserPromptSubmit PostToolUse SessionEnd; do
  reset
  hook Stop a
  hook Stop b
  hook "$event" a
  check "$event clears only its own session" \
    '{"blocked":[],"turn":["proj-b"]}' "$(list)"
done

reset
hook Stop a
hook PostToolUse a '"agent_id": "sub-1"'
check "a subagent's tool call leaves the session waiting" \
  '{"blocked":[],"turn":["proj-a"]}' "$(list)"

reset
hook PostToolUse a
check "clearing an untracked session writes nothing" \
  "no file" "$([ -e "$ATTENTION_FILE" ] && echo file || echo "no file")"

# --- listing and pruning ------------------------------------------------------
reset
check "list with no file is empty" '{"blocked":[],"turn":[]}' "$(list)"

reset
hook Stop live
sleep 0 &
dead_pid=$!
wait "$dead_pid"
ATTENTION_PID="$dead_pid" hook Stop dead
check "list drops sessions whose process has exited" \
  '{"blocked":[],"turn":["proj-live"]}' "$(list)"
check "pruning is written back to the file" \
  '["live"]' "$(jq -c 'keys' "$ATTENTION_FILE")"

reset
hook Stop reused
jq '.reused.start = "1"' "$ATTENTION_FILE" >"$tmp_dir/x" && mv "$tmp_dir/x" "$ATTENTION_FILE"
check "list drops a session whose PID now belongs to another process" \
  '{"blocked":[],"turn":[]}' "$(list)"

reset
ATTENTION_NOW=200 hook Stop b
ATTENTION_NOW=100 hook Stop a
ATTENTION_NOW=300 hook Notification c '"notification_type": "permission_prompt"'
check "list orders each group by longest waiting first" \
  '{"blocked":["proj-c"],"turn":["proj-a","proj-b"]}' "$(list)"
check "list names each session alongside its project" \
  '[{"session":"c","project":"proj-c"}]' "$(bash "$TRACKER" list | jq -c .blocked)"

# --- waiting since ------------------------------------------------------------
reset
ATTENTION_NOW=100 hook Stop a
ATTENTION_NOW=200 hook Stop a
check "repeating the same state keeps the original waiting time" \
  '100' "$(jq '.a.since' "$ATTENTION_FILE")"
ATTENTION_NOW=300 hook Notification a '"notification_type": "permission_prompt"'
check "changing state restarts the waiting time" \
  '300' "$(jq '.a.since' "$ATTENTION_FILE")"

# --- focus --------------------------------------------------------------------
# A fake qdbus stands in for Yakuake: Konsole session N runs the shell listed in
# $fake/konsole, and Yakuake numbers that terminal N-1. Window and tab changes
# are logged to $fake/actions.
fake="$tmp_dir/yakuake"
mkdir -p "$fake"
cat >"$fake/qdbus" <<'EOF'
#!/usr/bin/env bash
d="$(dirname "$0")"
[ $# -eq 1 ] && { awk '{print "/Sessions/" $1}' "$d/konsole"; echo /yakuake/sessions; exit; }
case "$2 $3" in
  "/yakuake/sessions terminalIdList") cat "$d/terminals" ;;
  "/yakuake/sessions sessionIdForTerminalId") awk -v t="$4" '$1 == t {print $2; f=1} END {if (!f) print -1}' "$d/tabs" ;;
  "/yakuake/MainWindow_1 org.freedesktop.DBus.Properties.Get") cat "$d/visible" ;;
  "/yakuake/window toggleWindowState") echo show >>"$d/actions" ;;
  "/yakuake/sessions raiseSession") echo "tab $4" >>"$d/actions" ;;
  *) case "$2 $3" in /Sessions/*" processId") awk -v n="${2#/Sessions/}" '$1 == n {print $2}' "$d/konsole" ;; esac ;;
esac
EOF
chmod +x "$fake/qdbus"
export ATTENTION_QDBUS="$fake/qdbus"

# Two Claude stand-ins, each under its own shell, like two Yakuake terminals.
bash -c 'sleep 300 & wait' &
SHELL_A=$!
bash -c 'sleep 300 & wait' &
SHELL_B=$!
sleep 0.2
CLAUDE_A="$(pgrep -P "$SHELL_A")"
CLAUDE_B="$(pgrep -P "$SHELL_B")"
trap 'kill "$LIVE_PID" "$CLAUDE_A" "$CLAUDE_B" 2>/dev/null; rm -rf "$tmp_dir"' EXIT

yakuake() {
  local visible="$1"
  printf '5 %s\n15 %s\n' "$SHELL_A" "$SHELL_B" >"$fake/konsole"
  echo "4,14" >"$fake/terminals"
  printf '4 3\n14 2\n' >"$fake/tabs"
  echo "$visible" >"$fake/visible"
  rm -f "$fake/actions"
}
focus() { bash "$TRACKER" focus "$@"; tr '\n' ' ' 2>/dev/null <"$fake/actions"; }

reset; yakuake true
ATTENTION_PID="$CLAUDE_A" ATTENTION_NOW=100 hook Stop a
ATTENTION_PID="$CLAUDE_B" ATTENTION_NOW=200 hook Notification b '"notification_type": "permission_prompt"'
check "focus goes to a blocked session ahead of a done one" "tab 2 " "$(focus)"

reset; yakuake true
ATTENTION_PID="$CLAUDE_B" ATTENTION_NOW=200 hook Stop b
ATTENTION_PID="$CLAUDE_A" ATTENTION_NOW=100 hook Stop a
check "focus goes to the session that has waited longest" "tab 3 " "$(focus)"

reset; yakuake true
ATTENTION_PID="$CLAUDE_A" ATTENTION_NOW=100 hook Stop a
ATTENTION_PID="$CLAUDE_B" ATTENTION_NOW=200 hook Notification b '"notification_type": "permission_prompt"'
check "focus on a named session goes to that session's tab" "tab 3 " "$(focus a)"

reset; yakuake false
ATTENTION_PID="$CLAUDE_A" hook Stop a
check "focus opens a hidden Yakuake before switching tabs" "show tab 3 " "$(focus)"

reset; yakuake false
check "focus with nothing waiting only opens Yakuake" "show " "$(focus)"

reset; yakuake true
ATTENTION_PID="$CLAUDE_A" hook Stop a
echo "4,9" >"$fake/terminals"
check "focus leaves the tab alone when terminal numbering doesn't line up" "" "$(focus)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
