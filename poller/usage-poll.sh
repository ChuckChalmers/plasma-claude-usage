#!/usr/bin/env bash
# OAuth usage poller — surface-independent refresh of the Claude usage cache.
#
# The statusLine writer only runs in a terminal. When Claude Code is used
# through the VS Code extension (or between sessions) the cache goes stale. This
# script refreshes it from Anthropic's OAuth usage endpoint, which returns the
# same account-level 5h/7d utilization independent of any session or surface. It
# is driven by a systemd user timer (see claude-usage-poll.{service,timer}).
#
# It writes the SAME cache schema the statusLine writer produces, so the widget
# needs no changes. Both writers own the same account-level truth; the atomic
# write makes concurrent updates safe (last write wins, and they agree).
#
# The endpoint is undocumented beta and may change. Failures are classified:
#   - transient (offline, timeout, HTTP 401 token expiry, HTTP 5xx): stay silent,
#     leave the cache untouched.
#   - real breakage (HTTP 200 whose schema we don't recognise, or a persistent
#     non-401/5xx HTTP error like 404/410): after a few consecutive occurrences,
#     fire a debounced desktop notification so the drift is visible.
# In every failure case the cache is left untouched — it is never wrong because
# of us, only (at worst) stale, which the widget's reset rule already bounds.
set -euo pipefail

CACHE_FILE="${USAGE_CACHE_FILE:-$HOME/.claude/usage_cache.json}"
STATE_FILE="${USAGE_POLL_STATE_FILE:-$HOME/.claude/usage_poll_state.json}"
CREDENTIALS_FILE="${CLAUDE_CREDENTIALS_FILE:-$HOME/.claude/.credentials.json}"
ENDPOINT="${USAGE_ENDPOINT:-https://api.anthropic.com/api/oauth/usage}"
BETA_HEADER="${USAGE_OAUTH_BETA:-oauth-2025-04-20}"
NOTIFY_CMD="${USAGE_NOTIFY_CMD:-notify-send}"
BREAKAGE_THRESHOLD="${USAGE_POLL_BREAKAGE_THRESHOLD:-3}"

log() { printf 'usage-poll: %s\n' "$1" >&2; }

# --- state (debounce) --------------------------------------------------------
state_get() { # $1 field, $2 default
  jq -r --arg d "$2" ".$1 // \$d" "$STATE_FILE" 2>/dev/null || printf '%s' "$2"
}
state_set() { # $1 consecutive_breakages, $2 notified(true|false)
  local tmp="${STATE_FILE}.tmp.$$"
  jq -cn --argjson c "$1" --argjson n "$2" \
    '{consecutive_breakages:$c, notified:$n}' >"$tmp" && mv "$tmp" "$STATE_FILE"
}

# A recoverable, expected condition: quietly do nothing this tick.
transient() { log "transient: $1 (cache left unchanged)"; exit 0; }

# The endpoint looks broken (changed schema / retired). Count it; once we've
# seen it enough times in a row, notify once until the next success re-arms.
breakage() {
  local msg="$1"
  local count notified
  count=$(( $(state_get consecutive_breakages 0) + 1 ))
  notified="$(state_get notified false)"
  log "BREAKAGE: $msg (consecutive=$count)"
  if [ "$count" -ge "$BREAKAGE_THRESHOLD" ] && [ "$notified" != "true" ]; then
    "$NOTIFY_CMD" -u normal -a "Claude usage" \
      "Claude usage poller failing" \
      "The usage endpoint may have changed ($msg). Bars may be stale until fixed — see: journalctl --user -u claude-usage-poll" \
      >/dev/null 2>&1 || true
    notified="true"
  fi
  state_set "$count" "$notified"
  exit 1
}

# --- transform: endpoint body -> cache JSON (or non-zero on unrecognised) -----
# Echoes the cache JSON on success. Returns 1 if any required field is
# missing/null or a reset timestamp won't parse — the signal for "schema broke".
transform() {
  local body="$1" now fh_pct sd_pct fh_iso sd_iso fh_epoch sd_epoch
  now="$(date +%s)"
  fh_pct="$(jq -e -r '.five_hour.utilization  | round' <<<"$body" 2>/dev/null)" || return 1
  sd_pct="$(jq -e -r '.seven_day.utilization | round' <<<"$body" 2>/dev/null)" || return 1
  fh_iso="$(jq -e -r '.five_hour.resets_at'         <<<"$body" 2>/dev/null)" || return 1
  sd_iso="$(jq -e -r '.seven_day.resets_at'        <<<"$body" 2>/dev/null)" || return 1
  fh_epoch="$(date -d "$fh_iso" +%s 2>/dev/null)" || return 1
  sd_epoch="$(date -d "$sd_iso" +%s 2>/dev/null)" || return 1
  jq -cn \
    --argjson fp "$fh_pct" --argjson fr "$fh_epoch" \
    --argjson sp "$sd_pct" --argjson sr "$sd_epoch" \
    --argjson now "$now" \
    '{five_hour:  {used_percentage:$fp, resets_at:$fr},
      seven_day:  {used_percentage:$sp, resets_at:$sr},
      updated_at: $now}'
}

write_cache() { # $1 cache json
  local tmp="${CACHE_FILE}.tmp.$$"
  printf '%s' "$1" >"$tmp"
  mv "$tmp" "$CACHE_FILE"
}

# --- fetch (or, under test, read an injected body) ---------------------------
if [ -n "${USAGE_POLL_INPUT:-}" ]; then
  body="$(cat "$USAGE_POLL_INPUT")"
  status="${USAGE_POLL_HTTP_STATUS:-200}"
else
  token="$(jq -r '.claudeAiOauth.accessToken // empty' "$CREDENTIALS_FILE" 2>/dev/null || true)"
  [ -n "$token" ] || transient "no OAuth access token in $CREDENTIALS_FILE"
  resp="$(curl -sS --max-time 15 -w $'\n%{http_code}' \
            -H "Authorization: Bearer $token" \
            -H "anthropic-beta: $BETA_HEADER" \
            "$ENDPOINT" 2>/dev/null)" || transient "request failed (offline/timeout)"
  status="${resp##*$'\n'}"
  body="${resp%$'\n'*}"
fi

# --- classify ----------------------------------------------------------------
case "$status" in
  200)
    if cache="$(transform "$body")"; then
      write_cache "$cache"
      state_set 0 false          # success re-arms the breakage notification
      log "ok: cache refreshed"
      exit 0
    fi
    breakage "HTTP 200 but response schema unrecognised"
    ;;
  401)     transient "HTTP 401 (token expired/invalid)" ;;
  5[0-9][0-9]) transient "HTTP $status (server error)" ;;
  *)       breakage "HTTP $status from usage endpoint" ;;
esac
