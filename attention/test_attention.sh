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

list() { bash "$TRACKER" list | jq -c .; }

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
hook Stop b
hook Stop a
hook Notification c '"notification_type": "permission_prompt"'
check "list sorts projects by name" \
  '{"blocked":["proj-c"],"turn":["proj-a","proj-b"]}' "$(list)"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
