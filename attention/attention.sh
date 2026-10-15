#!/usr/bin/env bash
# Attention tracker: which Claude Code sessions are waiting on you.
#
#   attention.sh hook   registered for Stop, Notification, PreToolUse
#                       (AskUserQuestion|ExitPlanMode), PostToolUse,
#                       UserPromptSubmit and SessionEnd; reads the hook payload
#                       on stdin and marks or clears the session.
#   attention.sh list   prints {"blocked":[...],"turn":[...]} for the widget, each
#                       a list of {session, project} ordered longest waiting
#                       first, after dropping sessions whose process is gone.
#   attention.sh focus [session]
#                       opens Yakuake and switches to that session's tab, or by
#                       default to the one that most needs you: blocked first,
#                       then longest waiting.
#
# State is one JSON map, session_id -> {state, project, pid, start, since},
# where start is the process start time so a recycled PID never counts as
# alive, and since is when the session entered its current state.
set -euo pipefail

FILE="${ATTENTION_FILE:-$HOME/.claude/attention.json}"
LOCK="$FILE.lock"
QDBUS="${ATTENTION_QDBUS:-qdbus}"

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
    --argjson now "${ATTENTION_NOW:-$(date +%s)}" \
    '.[$s] = {state: $st, project: $p, pid: $pid, start: $start,
              since: (if .[$s].state == $st then .[$s].since // $now else $now end)}'
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

  jq -c '[to_entries[] | {session: .key, project: .value.project,
                           state: .value.state, since: (.value.since // 0)}]
    | sort_by(.since) as $all
    | def group(st): [$all[] | select(.state == st) | {session, project}];
      {blocked: group("blocked"), turn: group("turn")}' "$FILE"
}

yakuake() { "$QDBUS" org.kde.yakuake "$@"; }

# Yakuake's tab for the terminal whose shell is <pid>, or nothing.
#
# Yakuake's D-Bus API names terminals by its own IDs, and only the Konsole
# sessions (/Sessions/N) expose their shell PID. Yakuake creates one Konsole
# session per terminal, so terminal ID = N - 1; that is checked across every
# terminal before trusting it, since no API states it.
tab_for_shell() {
  local shell="$1" n konsole=() match=""
  for n in $(yakuake | sed -n 's|^/Sessions/||p'); do
    konsole+=("$((n - 1))")
    [ "$(yakuake "/Sessions/$n" processId)" = "$shell" ] && match="$((n - 1))"
  done
  [ -n "$match" ] || return 0
  [ "$(printf '%s\n' "${konsole[@]}" | sort -n)" = \
    "$(yakuake /yakuake/sessions terminalIdList | tr ',' '\n' | sort -n)" ] || return 0
  local tab
  tab="$(yakuake /yakuake/sessions sessionIdForTerminalId "$match")"
  [ "$tab" -ge 0 ] && echo "$tab"
}

focus() {
  local session="${1:-}" pid="" tab=""
  list >/dev/null
  if [ -s "$FILE" ]; then
    pid="$(jq -r --arg s "$session" '
      if $s != "" then .[$s].pid
      else [.[]] | sort_by([.state != "blocked", .since // 0]) | first | .pid
      end // empty' "$FILE")"
  fi
  [ -n "$pid" ] && tab="$(tab_for_shell "$(stat_field "$pid" 4)")"

  [ "$(yakuake /yakuake/MainWindow_1 org.freedesktop.DBus.Properties.Get \
        org.qtproject.Qt.QWidget visible)" = true ] \
    || yakuake /yakuake/window toggleWindowState >/dev/null
  [ -n "$tab" ] && yakuake /yakuake/sessions raiseSession "$tab" >/dev/null
  return 0
}

case "${1:-}" in
  hook) hook ;;
  list) list ;;
  focus) focus "${2:-}" ;;
  *) echo "usage: attention.sh hook|list|focus" >&2; exit 2 ;;
esac
