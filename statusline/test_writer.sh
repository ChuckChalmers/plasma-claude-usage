#!/usr/bin/env bash
# Tests for the statusline writer script.
#
# Plain-bash harness (no bats dependency). Run from anywhere:
#   bash statusline/test_writer.sh
#
# The writer's cache path is injectable via USAGE_CACHE_FILE so tests never
# touch the real ~/.claude/usage_cache.json. NO_COLOR forces plain output so
# the terminal line is easy to assert.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
WRITER="$SCRIPT_DIR/statusline-command.sh"
FIXTURE="$REPO_ROOT/docs/statusline-payload.example.json"

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

# haystack contains needle?
check_contains() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    printf 'ok   - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s (needle not found)\n' "$name"
    fail=$((fail + 1))
  fi
}

check_absent() {
  local name="$1" needle="$2" haystack="$3"
  if [[ "$haystack" != *"$needle"* ]]; then
    printf 'ok   - %s\n' "$name"
    pass=$((pass + 1))
  else
    printf 'FAIL - %s (needle unexpectedly present)\n' "$name"
    fail=$((fail + 1))
  fi
}

ORANGE=$'\033[38;2;217;119;87m'
RED=$'\033[38;2;224;49;49m'

# --- writes both windows from the payload into the cache ---------------------
tmp_cache="$(mktemp)"
USAGE_CACHE_FILE="$tmp_cache" bash "$WRITER" <"$FIXTURE" >/dev/null 2>&1
check "cache: five_hour.used_percentage" "1" "$(jq -r '.five_hour.used_percentage' "$tmp_cache" 2>/dev/null)"
check "cache: five_hour.resets_at" "1783823400" "$(jq -r '.five_hour.resets_at' "$tmp_cache" 2>/dev/null)"
check "cache: seven_day.used_percentage" "4" "$(jq -r '.seven_day.used_percentage' "$tmp_cache" 2>/dev/null)"
check "cache: seven_day.resets_at" "1784383200" "$(jq -r '.seven_day.resets_at' "$tmp_cache" 2>/dev/null)"
check "cache: updated_at is numeric" "number" "$(jq -r '.updated_at | type' "$tmp_cache" 2>/dev/null)"
rm -f "$tmp_cache"

# --- prints the terminal line (plain, NO_COLOR) ------------------------------
tmp_cache="$(mktemp)"
line="$(NO_COLOR=1 USAGE_CACHE_FILE="$tmp_cache" bash "$WRITER" <"$FIXTURE" 2>/dev/null)"
check "line: plain format" "Opus 4.8 (1M context) · ctx 5% · 5h 1% · 7d 4%" "$line"
rm -f "$tmp_cache"

# --- coloring: whole line orange; a maxed window's label+percent go red ------
tmp_cache="$(mktemp)"
color_line="$(USAGE_CACHE_FILE="$tmp_cache" bash "$WRITER" <"$FIXTURE" 2>/dev/null)"
check_contains "color: text is orange, not just percents" "${ORANGE}Opus 4.8 (1M context)" "$color_line"
check_absent "color: no red below 100%" "$RED" "$color_line"
rm -f "$tmp_cache"

tmp_cache="$(mktemp)"
maxed="$(jq '.rate_limits.five_hour.used_percentage = 100' "$FIXTURE")"
color_line="$(USAGE_CACHE_FILE="$tmp_cache" bash "$WRITER" <<<"$maxed" 2>/dev/null)"
check_contains "color: maxed window label+percent go red" "${RED}5h 100%" "$color_line"
check_absent "color: non-maxed window stays out of red" "${RED}7d" "$color_line"
rm -f "$tmp_cache"

# --- defensive: no rate_limits -> preserve cache, drop usage from line -------
tmp_cache="$(mktemp)"
printf '%s' '{"five_hour":{"used_percentage":62,"resets_at":111},"seven_day":{"used_percentage":31,"resets_at":222},"updated_at":999}' >"$tmp_cache"
no_rl="$(jq 'del(.rate_limits)' "$FIXTURE")"
line="$(NO_COLOR=1 USAGE_CACHE_FILE="$tmp_cache" bash "$WRITER" <<<"$no_rl" 2>/dev/null)"
check "defensive: cache five_hour preserved" "62" "$(jq -r '.five_hour.used_percentage' "$tmp_cache" 2>/dev/null)"
check "defensive: cache updated_at preserved" "999" "$(jq -r '.updated_at' "$tmp_cache" 2>/dev/null)"
check "defensive: line omits usage figures" "Opus 4.8 (1M context) · ctx 5%" "$line"
rm -f "$tmp_cache"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
