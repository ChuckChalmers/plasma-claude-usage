#!/usr/bin/env bash
# Tests for the OAuth usage poller.
#
# Plain-bash harness (no bats), mirroring statusline/test_writer.sh. Run from
# anywhere:
#   bash poller/test_poll.sh
#
# The poller's network + credential access is bypassed via env seams so tests
# are hermetic:
#   USAGE_POLL_INPUT        file whose contents stand in for the endpoint body
#   USAGE_POLL_HTTP_STATUS  simulated HTTP status for that body (default 200)
#   USAGE_CACHE_FILE        cache output path (never the real ~/.claude one)
#   USAGE_POLL_STATE_FILE   debounce state path
#   USAGE_NOTIFY_CMD        stands in for notify-send; we record its calls
#   USAGE_POLL_BREAKAGE_THRESHOLD  consecutive breakages before notifying
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
POLLER="$SCRIPT_DIR/usage-poll.sh"
FIXTURE="$REPO_ROOT/docs/usage-endpoint.example.json"

# Epochs for the fixture's reset timestamps (whole-second floor of the ISO ts).
FH_RESET=1784054999   # 2026-07-14T18:49:59.948390+00:00
SD_RESET=1784383199   # 2026-07-18T13:59:59.948413+00:00

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

# Fresh, isolated set of temp paths + a notify recorder for one scenario.
# Sets globals: CACHE, STATE, NOTIFY, NOTIFY_LOG
new_env() {
  CACHE="$(mktemp)"; rm -f "$CACHE"          # absent until the poller writes it
  STATE="$(mktemp)"; rm -f "$STATE"
  NOTIFY_LOG="$(mktemp)"; rm -f "$NOTIFY_LOG"
  NOTIFY="$(mktemp)"
  cat >"$NOTIFY" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$NOTIFY_LOG"
EOF
  chmod +x "$NOTIFY"
}

cleanup_env() { rm -f "$CACHE" "$STATE" "$NOTIFY" "$NOTIFY_LOG"; }

# Run the poller against a body + status. Echoes nothing; sets RC.
# Args: <body-file> <http-status> [threshold]
run_poll() {
  local body="$1" status="$2" threshold="${3:-3}"
  USAGE_POLL_INPUT="$body" \
  USAGE_POLL_HTTP_STATUS="$status" \
  USAGE_CACHE_FILE="$CACHE" \
  USAGE_POLL_STATE_FILE="$STATE" \
  USAGE_NOTIFY_CMD="$NOTIFY" \
  USAGE_POLL_BREAKAGE_THRESHOLD="$threshold" \
    bash "$POLLER" >/dev/null 2>&1
  RC=$?
}

notify_count() { [ -f "$NOTIFY_LOG" ] && wc -l <"$NOTIFY_LOG" | tr -d ' ' || echo 0; }

# --- success: 200 + valid body writes the cache in the widget's schema -------
new_env
run_poll "$FIXTURE" 200
check "success: exit 0" "0" "$RC"
check "success: five_hour.used_percentage" "4" "$(jq -r '.five_hour.used_percentage' "$CACHE" 2>/dev/null)"
check "success: five_hour.resets_at (ISO->epoch)" "$FH_RESET" "$(jq -r '.five_hour.resets_at' "$CACHE" 2>/dev/null)"
check "success: seven_day.used_percentage" "14" "$(jq -r '.seven_day.used_percentage' "$CACHE" 2>/dev/null)"
check "success: seven_day.resets_at (ISO->epoch)" "$SD_RESET" "$(jq -r '.seven_day.resets_at' "$CACHE" 2>/dev/null)"
check "success: updated_at is numeric" "number" "$(jq -r '.updated_at | type' "$CACHE" 2>/dev/null)"
check "success: no notification fired" "0" "$(notify_count)"
cleanup_env

# --- rounding: fractional utilization rounds to an integer -------------------
new_env
rounded="$(mktemp)"
jq '.five_hour.utilization = 4.6' "$FIXTURE" >"$rounded"
run_poll "$rounded" 200
check "round: cache stores integer percent" "5" "$(jq -r '.five_hour.used_percentage' "$CACHE" 2>/dev/null)"
rm -f "$rounded"; cleanup_env

# --- success clears a prior breakage streak (re-arms notifications) ----------
new_env
printf '%s' '{"consecutive_breakages":5,"notified":true}' >"$STATE"
run_poll "$FIXTURE" 200
check "recover: consecutive_breakages reset to 0" "0" "$(jq -r '.consecutive_breakages' "$STATE" 2>/dev/null)"
check "recover: notified reset to false" "false" "$(jq -r '.notified' "$STATE" 2>/dev/null)"
cleanup_env

# --- schema breakage: 200 but utilization missing -> no-clobber + alert -------
new_env
printf '%s' '{"five_hour":{"used_percentage":62,"resets_at":111},"seven_day":{"used_percentage":31,"resets_at":222},"updated_at":999}' >"$CACHE"
broken="$(mktemp)"
jq 'del(.five_hour.utilization)' "$FIXTURE" >"$broken"
run_poll "$broken" 200 1
check "schema-break: exit non-zero" "1" "$RC"
check "schema-break: cache left untouched (percent)" "62" "$(jq -r '.five_hour.used_percentage' "$CACHE" 2>/dev/null)"
check "schema-break: cache left untouched (updated_at)" "999" "$(jq -r '.updated_at' "$CACHE" 2>/dev/null)"
check "schema-break: notification fired" "1" "$(notify_count)"
rm -f "$broken"; cleanup_env

# --- unparseable resets_at is also breakage ----------------------------------
new_env
badts="$(mktemp)"
jq '.five_hour.resets_at = "not-a-date"' "$FIXTURE" >"$badts"
run_poll "$badts" 200 1
check "bad-timestamp: exit non-zero" "1" "$RC"
check "bad-timestamp: cache not written" "false" "$([ -f "$CACHE" ] && echo true || echo false)"
rm -f "$badts"; cleanup_env

# --- non-200 non-401 (404) is breakage ---------------------------------------
new_env
run_poll "$FIXTURE" 404 1
check "http-404: exit non-zero" "1" "$RC"
check "http-404: cache not written" "false" "$([ -f "$CACHE" ] && echo true || echo false)"
check "http-404: notification fired" "1" "$(notify_count)"
cleanup_env

# --- transient: 401 stays silent (token expiry is expected) ------------------
new_env
run_poll "$FIXTURE" 401 1
check "http-401: exit 0 (transient)" "0" "$RC"
check "http-401: no notification" "0" "$(notify_count)"
check "http-401: cache not written" "false" "$([ -f "$CACHE" ] && echo true || echo false)"
cleanup_env

# --- transient: 5xx stays silent (server hiccup) -----------------------------
new_env
run_poll "$FIXTURE" 503 1
check "http-503: exit 0 (transient)" "0" "$RC"
check "http-503: no notification" "0" "$(notify_count)"
cleanup_env

# --- debounce: notify once per breakage episode, not every tick --------------
new_env
broken="$(mktemp)"
jq 'del(.five_hour.utilization)' "$FIXTURE" >"$broken"
run_poll "$broken" 200 3   # 1st failure
check "debounce: below threshold -> no notify yet" "0" "$(notify_count)"
check "debounce: counter at 1" "1" "$(jq -r '.consecutive_breakages' "$STATE" 2>/dev/null)"
run_poll "$broken" 200 3   # 2nd
run_poll "$broken" 200 3   # 3rd -> reaches threshold, notifies
check "debounce: notified at threshold" "1" "$(notify_count)"
run_poll "$broken" 200 3   # 4th -> already notified, stays quiet
check "debounce: no repeat notification" "1" "$(notify_count)"
rm -f "$broken"; cleanup_env

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
