#!/usr/bin/env bash
# Attention tracker: which Claude Code sessions are waiting on you.
#
#   attention.sh hook   registered for Stop, Notification, PreToolUse
#                       (AskUserQuestion|ExitPlanMode), PostToolUse,
#                       UserPromptSubmit and SessionEnd; reads the hook payload
#                       on stdin and marks or clears the session.
#   attention.sh list   prints {"blocked":[projects],"turn":[projects]} for the
#                       widget, first dropping sessions whose process is gone.
#
# State is one JSON map, session_id -> {state, project, pid, start}, where
# start is the process start time so a recycled PID never counts as alive.
set -euo pipefail

FILE="${ATTENTION_FILE:-$HOME/.claude/attention.json}"
LOCK="$FILE.lock"

# Field <n> of /proc/<pid>/stat; the command name in field 2 may contain spaces.
stat_field() {
  local stat
  stat="$(cat "/proc/$1/stat" 2>/dev/null)" || return 1
  awk -v n="$(($2 - 2))" '{print $n}' <<<"${stat##*) }"
}

start_time() { stat_field "$1" 22; }

# The Claude Code process that ran this hook: the nearest ancestor named claude.
claude_pid() {
  if [ -n "${ATTENTION_PID:-}" ]; then
    echo "$ATTENTION_PID"
    return
  fi
  local pid=$PPID
  while [ "${pid:-1}" -gt 1 ]; do
    if [ "$(cat "/proc/$pid/comm" 2>/dev/null)" = claude ]; then
      echo "$pid"
      return
    fi
    pid="$(stat_field "$pid" 4 || echo 1)"
  done
  echo "$PPID"
}

# Apply a jq filter to the state file, atomically and under a lock.
update() {
  exec 9>"$LOCK"
  flock 9
  local current tmp
  current="$(cat "$FILE" 2>/dev/null || echo '{}')"
  tmp="$(mktemp "$FILE.XXXXXX")"
  jq "$@" <<<"$current" >"$tmp"
  mv "$tmp" "$FILE"
}

mark() {
  local session="$1" state="$2" cwd="$3" pid start
  pid="$(claude_pid)"
  start="$(start_time "$pid" || echo 0)"
  update --arg s "$session" --arg st "$state" --arg p "${cwd##*/}" \
    --argjson pid "$pid" --arg start "$start" \
    '.[$s] = {state: $st, project: $p, pid: $pid, start: $start}'
}

clear_session() {
  local session="$1"
  # Fast path: PostToolUse runs on every tool call.
  grep -qF "\"$session\"" "$FILE" 2>/dev/null || return 0
  update --arg s "$session" 'del(.[$s])'
}

hook() {
  local payload event session cwd
  payload="$(cat)"
  event="$(jq -r '.hook_event_name // empty' <<<"$payload")"
  session="$(jq -r '.session_id // empty' <<<"$payload")"
  cwd="$(jq -r '.cwd // empty' <<<"$payload")"
  [ -n "$session" ] || return 0
  : "${cwd:=$PWD}"

  case "$event" in
    Stop)
      mark "$session" turn "$cwd" ;;
    Notification)
      # The idle reminder repeats what Stop recorded; older payloads lack the type.
      local type message
      type="$(jq -r '.notification_type // empty' <<<"$payload")"
      message="$(jq -r '.message // empty' <<<"$payload")"
      case "$type" in
        idle_prompt|auth_success) return 0 ;;
        "") [[ "$message" == *"waiting for your input"* ]] && return 0 ;;
      esac
      mark "$session" blocked "$cwd" ;;
    PreToolUse)
      mark "$session" blocked "$cwd" ;;
    PostToolUse)
      # A subagent working in the background doesn't mean you've responded.
      [ -n "$(jq -r '.agent_id // empty' <<<"$payload")" ] && return 0
      clear_session "$session" ;;
    UserPromptSubmit|SessionEnd)
      clear_session "$session" ;;
  esac
}

list() {
  local empty='{"blocked":[],"turn":[]}'
  [ -s "$FILE" ] || { echo "$empty"; return; }

  local session pid start dead=()
  while IFS=$'\t' read -r session pid start; do
    [ "$(start_time "$pid" || true)" = "$start" ] || dead+=("$session")
  done < <(jq -r 'to_entries[] | [.key, .value.pid, .value.start] | @tsv' "$FILE")

  if [ "${#dead[@]}" -gt 0 ]; then
    update --args 'delpaths($ARGS.positional | map([.]))' "${dead[@]}"
  fi

  jq -c '[.[]] as $all
    | {blocked: [$all[] | select(.state == "blocked") | .project] | sort,
       turn:    [$all[] | select(.state == "turn") | .project] | sort}' "$FILE"
}

case "${1:-}" in
  hook) hook ;;
  list) list ;;
  *) echo "usage: attention.sh hook|list" >&2; exit 2 ;;
esac
