#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export LANG=C

REPOSITORY_COUNT="${TINYBUDDY_BENCHMARK_REPOSITORIES:-24}"
EVENTS_PER_REPOSITORY="${TINYBUDDY_BENCHMARK_EVENTS_PER_REPOSITORY:-100}"
INCREMENTAL_RATIO_LIMIT="${TINYBUDDY_BENCHMARK_INCREMENTAL_RATIO_LIMIT:-1.25}"
CPU_PEAK_LIMIT="${TINYBUDDY_BENCHMARK_CPU_PEAK_LIMIT:-250}"
RSS_LIMIT_KB="${TINYBUDDY_BENCHMARK_RSS_LIMIT_KB:-262144}"
CANCELLATION_LIMIT_MS="${TINYBUDDY_BENCHMARK_CANCELLATION_LIMIT_MS:-2000}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
REFRESH_SCRIPT="$SCRIPT_DIR/update_git_completion_count.sh"
FIXTURE_ROOT="$(mktemp -d "${TMPDIR%/}/TinyBuddyGitBenchmark.XXXXXX")"
SCAN_ROOT="$FIXTURE_ROOT/repositories"
PREFERENCES_DIR="$FIXTURE_ROOT/preferences"
PREFERENCES_PLIST="$PREFERENCES_DIR/group.plist"
CACHE_DIR="$FIXTURE_ROOT/cache"
TODAY="$(date +%F)"
DAY_START_EPOCH="$(date -j -f '%Y-%m-%d %H:%M:%S' "$TODAY 00:00:00" +%s)"

cleanup() {
  rm -rf "$FIXTURE_ROOT"
}
trap cleanup EXIT

case "$REPOSITORY_COUNT:$EVENTS_PER_REPOSITORY" in
  *[!0-9:]*|:*|*:|*::* )
    echo "benchmark repository and event counts must be positive integers" >&2
    exit 64
    ;;
esac
if [ "$REPOSITORY_COUNT" -lt 1 ] || [ "$EVENTS_PER_REPOSITORY" -lt 1 ]; then
  echo "benchmark repository and event counts must be positive" >&2
  exit 64
fi

mkdir -p "$SCAN_ROOT" "$PREFERENCES_DIR"

repository_index=1
while [ "$repository_index" -le "$REPOSITORY_COUNT" ]; do
  repository_name="Repository-$(printf '%04d' "$repository_index")"
  git_dir="$SCAN_ROOT/$repository_name/.git"
  mkdir -p "$git_dir/logs"
  printf 'ref: refs/heads/main\n' > "$git_dir/HEAD"
  : > "$git_dir/logs/HEAD"

  event_index=1
  while [ "$event_index" -le "$EVENTS_PER_REPOSITORY" ]; do
    sequence=$(((repository_index - 1) * EVENTS_PER_REPOSITORY + event_index))
    epoch=$((DAY_START_EPOCH + 60 + sequence % 86000))
    new_oid="$(printf '%040x' "$sequence")"
    printf '%040d %s Tiny Buddy <tinybuddy@example.com> %d +0000\tcommit: benchmark-%d\n' \
      0 "$new_oid" "$epoch" "$sequence" >> "$git_dir/logs/HEAD"
    event_index=$((event_index + 1))
  done
  repository_index=$((repository_index + 1))
done

now_milliseconds() {
  /usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

metric_value() {
  local output_file="$1"
  local key="$2"
  awk -F '\t' -v key="$key" '
    /^TINYBUDDY_REFRESH_METRICS\t/ {
      for (field_index = 2; field_index <= NF; field_index++) {
        split($field_index, pair, "=")
        if (pair[1] == key) value = pair[2]
      }
    }
    END { print value }
  ' "$output_file"
}

run_measured_refresh() {
  local phase="$1"
  local stdout_file="$FIXTURE_ROOT/$phase.stdout"
  local stderr_file="$FIXTURE_ROOT/$phase.stderr"
  local start_ms
  local end_ms
  local refresh_pid
  local sample
  local cpu
  local rss
  local peak_cpu=0
  local peak_rss=0
  local exit_code=0
  local process_table

  start_ms="$(now_milliseconds)"
  env \
    TINYBUDDY_USER_HOME="$FIXTURE_ROOT/home" \
    TINYBUDDY_APP_GROUP_CONTAINER="$FIXTURE_ROOT/group" \
    TINYBUDDY_APP_GROUP_PREFERENCES_DIR="$PREFERENCES_DIR" \
    TINYBUDDY_APP_GROUP_PREFERENCES_PLIST="$PREFERENCES_PLIST" \
    TINYBUDDY_GIT_REPOSITORY_CACHE_DIR="$CACHE_DIR" \
    TINYBUDDY_GIT_SCAN_ROOTS="$SCAN_ROOT" \
    TINYBUDDY_TODAY="$TODAY" \
    /bin/bash "$REFRESH_SCRIPT" > "$stdout_file" 2> "$stderr_file" &
  refresh_pid=$!

  while kill -0 "$refresh_pid" 2>/dev/null; do
    if ! process_table="$(ps -axo pid=,ppid=,%cpu=,rss=)"; then
      kill -TERM "$refresh_pid" 2>/dev/null || true
      wait "$refresh_pid" 2>/dev/null || true
      echo "process sampling is unavailable; CPU and RSS benchmark evidence cannot be collected" >&2
      return 77
    fi
    sample="$(printf '%s\n' "$process_table" | awk -v root="$refresh_pid" '
      $1 == root || $2 == root { cpu += $3; rss += $4 }
      END { printf "%.1f %d", cpu + 0, rss + 0 }
    ')"
    cpu="${sample%% *}"
    rss="${sample##* }"
    peak_cpu="$(awk -v current="$peak_cpu" -v sample="$cpu" 'BEGIN {
      if (sample > current) print sample; else print current
    }')"
    if [ "$rss" -gt "$peak_rss" ]; then
      peak_rss="$rss"
    fi
    sleep 0.02
  done
  wait "$refresh_pid" || exit_code=$?
  end_ms="$(now_milliseconds)"

  if [ "$exit_code" -ne 0 ]; then
    echo "$phase refresh failed with exit code $exit_code" >&2
    sed -n '1,20p' "$stderr_file" >&2
    return "$exit_code"
  fi

  printf '%s\t%d\t%s\t%d\t%s\t%s\t%s\n' \
    "$phase" "$((end_ms - start_ms))" "$peak_cpu" "$peak_rss" \
    "$(metric_value "$stdout_file" cache_hit_count)" \
    "$(metric_value "$stdout_file" recomputed_repository_count)" \
    "$(metric_value "$stdout_file" reflog_unchanged_skip_count)"
}

printf 'phase\twall_ms\tcpu_peak_percent\tmax_rss_kb\tcache_hits\trecomputed\tunchanged_skips\n'
first_result="$(run_measured_refresh first)"
printf '%s\n' "$first_result"
incremental_result="$(run_measured_refresh incremental)"
printf '%s\n' "$incremental_result"

expected_count=$((REPOSITORY_COUNT * EVENTS_PER_REPOSITORY))
actual_count="$(/usr/libexec/PlistBuddy -c 'Print :tinybuddy.gitTodayCommitCount.count' "$PREFERENCES_PLIST")"
first_wall="$(printf '%s\n' "$first_result" | awk -F '\t' '{ print $2 }')"
incremental_wall="$(printf '%s\n' "$incremental_result" | awk -F '\t' '{ print $2 }')"
first_cpu="$(printf '%s\n' "$first_result" | awk -F '\t' '{ print $3 }')"
incremental_cpu="$(printf '%s\n' "$incremental_result" | awk -F '\t' '{ print $3 }')"
first_rss="$(printf '%s\n' "$first_result" | awk -F '\t' '{ print $4 }')"
incremental_rss="$(printf '%s\n' "$incremental_result" | awk -F '\t' '{ print $4 }')"
incremental_recomputed="$(printf '%s\n' "$incremental_result" | awk -F '\t' '{ print $6 }')"

test "$actual_count" -eq "$expected_count" || {
  echo "accuracy gate failed: expected=$expected_count actual=$actual_count" >&2
  exit 1
}
test "$incremental_recomputed" -eq 0 || {
  echo "incremental gate failed: recomputed=$incremental_recomputed" >&2
  exit 1
}
awk -v incremental="$incremental_wall" -v first="$first_wall" -v limit="$INCREMENTAL_RATIO_LIMIT" \
  'BEGIN { exit incremental <= first * limit ? 0 : 1 }' || {
  echo "incremental latency gate failed: first_ms=$first_wall incremental_ms=$incremental_wall ratio_limit=$INCREMENTAL_RATIO_LIMIT" >&2
  exit 1
}
awk -v first="$first_cpu" -v incremental="$incremental_cpu" -v limit="$CPU_PEAK_LIMIT" \
  'BEGIN { exit first <= limit && incremental <= limit ? 0 : 1 }' || {
  echo "CPU peak gate failed: first=$first_cpu incremental=$incremental_cpu limit=$CPU_PEAK_LIMIT" >&2
  exit 1
}
if [ "$first_rss" -gt "$RSS_LIMIT_KB" ] || [ "$incremental_rss" -gt "$RSS_LIMIT_KB" ]; then
  echo "RSS gate failed: first_kb=$first_rss incremental_kb=$incremental_rss limit_kb=$RSS_LIMIT_KB" >&2
  exit 1
fi

slow_stat="$FIXTURE_ROOT/slow-stat.sh"
printf '%s\n' \
  '#!/bin/bash' \
  'case "${*: -1}" in' \
  '  */logs/HEAD) exec /bin/sleep 30 ;;' \
  'esac' \
  'exec /usr/bin/stat "$@"' > "$slow_stat"
chmod +x "$slow_stat"

cancel_start_ms="$(now_milliseconds)"
env \
  TINYBUDDY_USER_HOME="$FIXTURE_ROOT/home" \
  TINYBUDDY_APP_GROUP_PREFERENCES_DIR="$PREFERENCES_DIR" \
  TINYBUDDY_APP_GROUP_PREFERENCES_PLIST="$PREFERENCES_PLIST" \
  TINYBUDDY_GIT_REPOSITORY_CACHE_DIR="$CACHE_DIR" \
  TINYBUDDY_GIT_SCAN_ROOTS="$SCAN_ROOT" \
  TINYBUDDY_TODAY="$TODAY" \
  TINYBUDDY_STAT_BIN="$slow_stat" \
  /bin/bash "$REFRESH_SCRIPT" >/dev/null 2>/dev/null &
cancel_pid=$!
sleep 0.2
kill -TERM "$cancel_pid" 2>/dev/null || true
wait "$cancel_pid" 2>/dev/null || true
cancel_end_ms="$(now_milliseconds)"
cancel_ms=$((cancel_end_ms - cancel_start_ms))
printf 'cancel\t%d\t0\t0\t0\t0\t0\n' "$cancel_ms"
if [ "$cancel_ms" -gt "$CANCELLATION_LIMIT_MS" ]; then
  echo "cancellation convergence gate failed: elapsed_ms=$cancel_ms limit_ms=$CANCELLATION_LIMIT_MS" >&2
  exit 1
fi

echo "TinyBuddy Git refresh benchmark passed: repositories=$REPOSITORY_COUNT events_per_repository=$EVENTS_PER_REPOSITORY expected_events=$expected_count"
