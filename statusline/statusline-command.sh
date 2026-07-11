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

# Render a "5h 62%" window segment. The line is orange overall (see emit_line);
# a maxed window (>=100%) turns its label+percent red, then returns to orange so
# the rest of the line stays orange.
window_seg() {
  local label="$1" pct="$2"
  if [ -z "${NO_COLOR:-}" ] && [ "$pct" -ge 100 ]; then
    printf '%s%s %s%%%s' "$RED" "$label" "$pct" "$ORANGE"
  else
    printf '%s %s%%' "$label" "$pct"
  fi
}

# Print a status line. NO_COLOR yields plain text; otherwise the whole line is
# wrapped in orange (embedded red segments already restore orange after).
emit_line() {
  if [ -n "${NO_COLOR:-}" ]; then
    printf '%s\n' "$1"
  else
    printf '%s%s%s\n' "$ORANGE" "$1" "$RESET"
  fi
}

payload="$(cat)"
now="$(date +%s)"

# Always available, needed by both branches below.
model="$(jq -r '.model.display_name' <<<"$payload")"
ctx="$(jq -r '.context_window.used_percentage | round' <<<"$payload")"

# When the payload carries no usable rate-limit data (older CLI, or a window not
# yet populated), leave the cache untouched — preserve last-good values rather
# than clobbering them with nulls — and print a reduced line.
has_rl="$(jq -r \
  '(.rate_limits.five_hour.used_percentage != null) and (.rate_limits.seven_day.used_percentage != null)' \
  <<<"$payload")"

if [ "$has_rl" != "true" ]; then
  emit_line "$model · ctx $ctx%"
  exit 0
fi

cache="$(jq -c --argjson now "$now" '{
  five_hour: {
    used_percentage: (.rate_limits.five_hour.used_percentage | round),
    resets_at:       .rate_limits.five_hour.resets_at
  },
  seven_day: {
    used_percentage: (.rate_limits.seven_day.used_percentage | round),
    resets_at:       .rate_limits.seven_day.resets_at
  },
  updated_at: $now
}' <<<"$payload")"

tmp="${CACHE_FILE}.tmp.$$"
printf '%s' "$cache" >"$tmp"
mv "$tmp" "$CACHE_FILE"

# Terminal status line: model · context% · 5h% · 7d%
fh="$(jq -r '.rate_limits.five_hour.used_percentage | round' <<<"$payload")"
sd="$(jq -r '.rate_limits.seven_day.used_percentage | round' <<<"$payload")"

emit_line "$model · ctx $ctx% · $(window_seg 5h "$fh") · $(window_seg 7d "$sd")"
