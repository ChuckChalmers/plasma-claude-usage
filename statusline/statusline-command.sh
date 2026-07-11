#!/usr/bin/env bash
# Claude Code statusLine writer.
#
# Reads the status-line JSON payload on stdin. Atomically writes the two
# rate-limit windows (plus a write timestamp) to a cache file the Plasma widget
# reads. Cache path is overridable via USAGE_CACHE_FILE (defaults to the real
# ~/.claude location).
set -euo pipefail

CACHE_FILE="${USAGE_CACHE_FILE:-$HOME/.claude/usage_cache.json}"

ORANGE=$'\033[38;2;217;119;87m' # Claude orange #D97757
RED=$'\033[38;2;224;49;49m'     # maxed-out indicator
RESET=$'\033[0m'

# Render a percentage for the terminal line: orange below 100%, red at >=100%.
# NO_COLOR (any non-empty value) yields plain text.
color_pct() {
  local pct="$1"
  if [ -n "${NO_COLOR:-}" ]; then
    printf '%s%%' "$pct"
    return
  fi
  local c="$ORANGE"
  if [ "$pct" -ge 100 ]; then c="$RED"; fi
  printf '%s%s%%%s' "$c" "$pct" "$RESET"
}

payload="$(cat)"
now="$(date +%s)"

# Always available, needed by both branches below.
model="$(jq -r '.model.display_name' <<<"$payload")"
ctx="$(jq -r '.context_window.used_percentage' <<<"$payload")"

# When the payload carries no usable rate-limit data (older CLI, or a window not
# yet populated), leave the cache untouched — preserve last-good values rather
# than clobbering them with nulls — and print a reduced line.
has_rl="$(jq -r \
  '(.rate_limits.five_hour.used_percentage != null) and (.rate_limits.seven_day.used_percentage != null)' \
  <<<"$payload")"

if [ "$has_rl" != "true" ]; then
  printf '%s · ctx %s%%\n' "$model" "$ctx"
  exit 0
fi

cache="$(jq -c --argjson now "$now" '{
  five_hour: {
    used_percentage: .rate_limits.five_hour.used_percentage,
    resets_at:       .rate_limits.five_hour.resets_at
  },
  seven_day: {
    used_percentage: .rate_limits.seven_day.used_percentage,
    resets_at:       .rate_limits.seven_day.resets_at
  },
  updated_at: $now
}' <<<"$payload")"

tmp="${CACHE_FILE}.tmp.$$"
printf '%s' "$cache" >"$tmp"
mv "$tmp" "$CACHE_FILE"

# Terminal status line: model · context% · 5h% · 7d%
fh="$(jq -r '.rate_limits.five_hour.used_percentage' <<<"$payload")"
sd="$(jq -r '.rate_limits.seven_day.used_percentage' <<<"$payload")"

printf '%s · ctx %s%% · 5h %s · 7d %s\n' \
  "$model" "$ctx" "$(color_pct "$fh")" "$(color_pct "$sd")"
