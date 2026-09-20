#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C
export LANG=C

REPOSITORY_COUNT="${TINYBUDDY_BENCHMARK_REPOSITORIES:-24}"
EVENTS_PER_REPOSITORY="${TINYBUDDY_BENCHMARK_EVENTS_PER_REPOSITORY:-100}"
TREE_ENTRIES="${TINYBUDDY_BENCHMARK_TREE_ENTRIES:-30000}"
INCREMENTAL_RATIO_LIMIT="${TINYBUDDY_BENCHMARK_INCREMENTAL_RATIO_LIMIT:-1.25}"
SCOPED_RATIO_LIMIT="${TINYBUDDY_BENCHMARK_SCOPED_RATIO_LIMIT:-1.0}"
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
FIND_PROBE_LOG="$FIXTURE_ROOT/find-probe.log"
FIND_PROBE="$FIXTURE_ROOT/find-probe.sh"
TODAY="$(date +%F)"
DAY_START_EPOCH="$(date -j -f '%Y-%m-%d %H:%M:%S' "$TODAY 00:00:00" +%s)"
# Fixture events are placed inside the local day. Pinning the refresh epoch to
# the end of that day keeps every event in the past no matter what time the
# benchmark runs and makes the published revision independent of the wall clock.
REFRESH_EPOCH_LIMIT=$((DAY_START_EPOCH + 86399))
AFFECTED_REPOSITORY_NAME="Repository-0001"
AFFECTED_REPOSITORY="$SCAN_ROOT/$AFFECTED_REPOSITORY_NAME"

cleanup() {
  rm -rf "$FIXTURE_ROOT"
}
trap cleanup EXIT

case "$REPOSITORY_COUNT:$EVENTS_PER_REPOSITORY:$TREE_ENTRIES" in
  *[!0-9:]*|:*|*:|*::* )
    echo "benchmark repository, event, and tree counts must be positive integers" >&2
    exit 64
    ;;
esac
if [ "$REPOSITORY_COUNT" -lt 1 ] || [ "$EVENTS_PER_REPOSITORY" -lt 1 ]; then
  echo "benchmark repository and event counts must be positive" >&2
  exit 64
fi
# The scoped phase proves the discovery rescan covers one repository instead of
# the whole scan root, so the fixture needs a non-repository tree big enough for
# that difference to be measurable.
if [ "$TREE_ENTRIES" -lt 1000 ]; then
  echo "benchmark tree entry count must be at least 1000" >&2
  exit 64
fi

mkdir -p "$SCAN_ROOT" "$PREFERENCES_DIR"

# A pass-through `find` probe records the path a repository discovery rescan is
# rooted at, which is the direct evidence of the invalidation scope.
printf '%s\n' '#!/bin/bash' \
  "printf '%s\\n' \"\$*\" >> \"$FIND_PROBE_LOG\"" \
  'exec /usr/bin/find "$@"' > "$FIND_PROBE"
chmod +x "$FIND_PROBE"
: > "$FIND_PROBE_LOG"

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
  local invalidated_paths="${2:-}"
  local find_probe="${3:-}"
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

  if [ -n "$find_probe" ]; then
    : > "$FIND_PROBE_LOG"
  fi
  start_ms="$(now_milliseconds)"
  env \
    TINYBUDDY_USER_HOME="$FIXTURE_ROOT/home" \
    TINYBUDDY_APP_GROUP_CONTAINER="$FIXTURE_ROOT/group" \
    TINYBUDDY_APP_GROUP_PREFERENCES_DIR="$PREFERENCES_DIR" \
    TINYBUDDY_APP_GROUP_PREFERENCES_PLIST="$PREFERENCES_PLIST" \
    TINYBUDDY_GIT_REPOSITORY_CACHE_DIR="$CACHE_DIR" \
    TINYBUDDY_GIT_SCAN_ROOTS="$SCAN_ROOT" \
    TINYBUDDY_GIT_INVALIDATED_ROOTS="$invalidated_paths" \
    TINYBUDDY_FIND_BIN="${find_probe:-find}" \
    TINYBUDDY_TODAY="$TODAY" \
    TINYBUDDY_REFRESH_EPOCH="$REFRESH_EPOCH_LIMIT" \
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

  printf '%s\t%d\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$phase" "$((end_ms - start_ms))" "$peak_cpu" "$peak_rss" \
    "$(metric_value "$stdout_file" cache_hit_count)" \
    "$(metric_value "$stdout_file" recomputed_repository_count)" \
    "$(metric_value "$stdout_file" reflog_unchanged_skip_count)" \
    "$(metric_value "$stdout_file" evicted_repository_count)" \
    "$(metric_value "$stdout_file" retained_cached_repository_count)" \
    "$([ -n "$find_probe" ] && discovery_scope_for_probe_log || echo '-')"
}

discovery_scope_for_probe_log() {
  awk '$0 ~ /-name \.git/ { print $1; exit }' "$FIND_PROBE_LOG"
}

traversal_entry_count() {
  find "$1" -mindepth 1 2>/dev/null | wc -l | tr -d ' '
}

# The refresh script canonicalizes the paths it reports, so compare canonical
# paths here as well.
resolved_path() {
  (cd "$1" 2>/dev/null && pwd -P) || printf '%s\n' "$1"
}

build_benchmark_tree() {
  local group_index=1
  local group_limit=$((TREE_ENTRIES / 3))
  local padded_paths

  while [ "$group_index" -le "$group_limit" ]; do
    padded_paths=()
    local batch_end=$((group_index + 199))
    while [ "$group_index" -le "$group_limit" ] && [ "$group_index" -le "$batch_end" ]; do
      padded_paths+=("$SCAN_ROOT/workspace/pad-$(printf '%05d' "$group_index")/level-1/level-2")
      group_index=$((group_index + 1))
    done
    mkdir -p "${padded_paths[@]}"
  done
}

# Appends one reflog completion to the affected repository, which is what a
# repository-change event means for the refresh.
append_affected_repository_event() {
  local event_epoch="$1"
  local new_oid

  new_oid="$(printf '%040x' "$event_epoch")"
  printf '%040d %s Tiny Buddy <tinybuddy@example.com> %d +0000\tcommit: scoped-%d\n' \
    0 "$new_oid" "$event_epoch" "$event_epoch" \
    >> "$SCAN_ROOT/$AFFECTED_REPOSITORY_NAME/.git/logs/HEAD"
}

printf 'phase\twall_ms\tcpu_peak_percent\tmax_rss_kb\tcache_hits\trecomputed\tunchanged_skips\tevicted_repositories\tretained_cached_repositories\tdiscovery_scope\n'
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
printf 'cancel\t%d\t0\t0\t0\t0\t0\t0\t0\t-\n' "$cancel_ms"
if [ "$cancel_ms" -gt "$CANCELLATION_LIMIT_MS" ]; then
  echo "cancellation convergence gate failed: elapsed_ms=$cancel_ms limit_ms=$CANCELLATION_LIMIT_MS" >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# Repository-change refresh scoping: a repository-change refresh must recompute
# discovery only for the affected repository instead of rescanning its whole
# scan root, while publishing the same activity.
# ---------------------------------------------------------------------------
build_benchmark_tree
padded_result="$(run_measured_refresh padded)"
printf '%s\n' "$padded_result"
padded_count="$(/usr/libexec/PlistBuddy -c 'Print :tinybuddy.gitTodayCommitCount.count' "$PREFERENCES_PLIST")"
test "$padded_count" -eq "$expected_count" || {
  echo "padded tree gate failed: expected=$expected_count actual=$padded_count" >&2
  exit 1
}

affected_repository_root_entries="$(traversal_entry_count "$SCAN_ROOT")"
affected_repository_entries="$(traversal_entry_count "$AFFECTED_REPOSITORY")"

expected_after_first_change=$((expected_count + 1))
append_affected_repository_event "$((DAY_START_EPOCH + 3000))"
unscoped_result="$(run_measured_refresh unscoped "$SCAN_ROOT" "$FIND_PROBE")"
printf '%s\n' "$unscoped_result"
unscoped_count="$(/usr/libexec/PlistBuddy -c 'Print :tinybuddy.gitTodayCommitCount.count' "$PREFERENCES_PLIST")"

expected_after_second_change=$((expected_count + 2))
append_affected_repository_event "$((DAY_START_EPOCH + 3001))"
scoped_result="$(run_measured_refresh scoped "$AFFECTED_REPOSITORY" "$FIND_PROBE")"
printf '%s\n' "$scoped_result"
scoped_count="$(/usr/libexec/PlistBuddy -c 'Print :tinybuddy.gitTodayCommitCount.count' "$PREFERENCES_PLIST")"

unscoped_wall="$(printf '%s\n' "$unscoped_result" | awk -F '\t' '{ print $2 }')"
unscoped_cpu="$(printf '%s\n' "$unscoped_result" | awk -F '\t' '{ print $3 }')"
unscoped_rss="$(printf '%s\n' "$unscoped_result" | awk -F '\t' '{ print $4 }')"
unscoped_cache_hits="$(printf '%s\n' "$unscoped_result" | awk -F '\t' '{ print $5 }')"
unscoped_recomputed="$(printf '%s\n' "$unscoped_result" | awk -F '\t' '{ print $6 }')"
unscoped_unchanged="$(printf '%s\n' "$unscoped_result" | awk -F '\t' '{ print $7 }')"
unscoped_evicted="$(printf '%s\n' "$unscoped_result" | awk -F '\t' '{ print $8 }')"
unscoped_retained="$(printf '%s\n' "$unscoped_result" | awk -F '\t' '{ print $9 }')"
unscoped_scope="$(printf '%s\n' "$unscoped_result" | awk -F '\t' '{ print $10 }')"
scoped_wall="$(printf '%s\n' "$scoped_result" | awk -F '\t' '{ print $2 }')"
scoped_cpu="$(printf '%s\n' "$scoped_result" | awk -F '\t' '{ print $3 }')"
scoped_rss="$(printf '%s\n' "$scoped_result" | awk -F '\t' '{ print $4 }')"
scoped_cache_hits="$(printf '%s\n' "$scoped_result" | awk -F '\t' '{ print $5 }')"
scoped_recomputed="$(printf '%s\n' "$scoped_result" | awk -F '\t' '{ print $6 }')"
scoped_unchanged="$(printf '%s\n' "$scoped_result" | awk -F '\t' '{ print $7 }')"
scoped_evicted="$(printf '%s\n' "$scoped_result" | awk -F '\t' '{ print $8 }')"
scoped_retained="$(printf '%s\n' "$scoped_result" | awk -F '\t' '{ print $9 }')"
scoped_scope="$(printf '%s\n' "$scoped_result" | awk -F '\t' '{ print $10 }')"

test "$unscoped_scope" = "$(resolved_path "$SCAN_ROOT")" || {
  echo "unscoped discovery scope gate failed: scope=$unscoped_scope expected=$(resolved_path "$SCAN_ROOT")" >&2
  exit 1
}
test "$scoped_scope" = "$(resolved_path "$AFFECTED_REPOSITORY")" || {
  echo "scoped discovery scope gate failed: scope=$scoped_scope expected=$(resolved_path "$AFFECTED_REPOSITORY")" >&2
  exit 1
}
if [ "$unscoped_evicted" != "$REPOSITORY_COUNT" ] || [ "$unscoped_retained" != "0" ]; then
  echo "unscoped invalidation gate failed: evicted=$unscoped_evicted retained_cached=$unscoped_retained" >&2
  exit 1
fi
if [ "$scoped_evicted" != "1" ] || [ "$scoped_retained" != "$((REPOSITORY_COUNT - 1))" ]; then
  echo "scoped invalidation gate failed: evicted=$scoped_evicted retained_cached=$scoped_retained" >&2
  exit 1
fi
if [ "$scoped_recomputed" != "1" ] || [ "$unscoped_recomputed" != "1" ]; then
  echo "scoped recompute gate failed: unscoped=$unscoped_recomputed scoped=$scoped_recomputed" >&2
  exit 1
fi
if [ "$scoped_cache_hits" != "$REPOSITORY_COUNT" ] || [ "$unscoped_cache_hits" != "$REPOSITORY_COUNT" ]; then
  echo "cache reuse gate failed: unscoped=$unscoped_cache_hits scoped=$scoped_cache_hits" >&2
  exit 1
fi
if [ "$scoped_unchanged" != "$((REPOSITORY_COUNT - 1))" ] || [ "$unscoped_unchanged" != "$((REPOSITORY_COUNT - 1))" ]; then
  echo "unchanged repository gate failed: unscoped=$unscoped_unchanged scoped=$scoped_unchanged" >&2
  exit 1
fi
test "$unscoped_count" -eq "$expected_after_first_change" || {
  echo "unscoped publication gate failed: expected=$expected_after_first_change actual=$unscoped_count" >&2
  exit 1
}
test "$scoped_count" -eq "$expected_after_second_change" || {
  echo "scoped publication gate failed: expected=$expected_after_second_change actual=$scoped_count" >&2
  exit 1
}
if [ "$unscoped_rss" -gt "$RSS_LIMIT_KB" ] || [ "$scoped_rss" -gt "$RSS_LIMIT_KB" ]; then
  echo "scoped RSS gate failed: unscoped_kb=$unscoped_rss scoped_kb=$scoped_rss limit_kb=$RSS_LIMIT_KB" >&2
  exit 1
fi
awk -v unscoped="$unscoped_cpu" -v scoped="$scoped_cpu" -v limit="$CPU_PEAK_LIMIT" \
  'BEGIN { exit unscoped <= limit && scoped <= limit ? 0 : 1 }' || {
  echo "scoped CPU peak gate failed: unscoped=$unscoped_cpu scoped=$scoped_cpu limit=$CPU_PEAK_LIMIT" >&2
  exit 1
}
if [ "$((affected_repository_entries * 10))" -gt "$affected_repository_root_entries" ]; then
  echo "scoped traversal gate failed: affected_entries=$affected_repository_entries scan_root_entries=$affected_repository_root_entries" >&2
  exit 1
fi
awk -v scoped="$scoped_wall" -v unscoped="$unscoped_wall" -v limit="$SCOPED_RATIO_LIMIT" \
  'BEGIN { exit scoped <= unscoped * limit ? 0 : 1 }' || {
  echo "scoped latency gate failed: unscoped_ms=$unscoped_wall scoped_ms=$scoped_wall ratio_limit=$SCOPED_RATIO_LIMIT" >&2
  exit 1
}
printf 'scoped-comparison\tunscoped_wall_ms=%s\tscoped_wall_ms=%s\tunscoped_cpu_peak=%s\tscoped_cpu_peak=%s\ttraversal_entries_unscoped=%s\ttraversal_entries_scoped=%s\tevicted_unscoped=%s\tevicted_scoped=%s\n' \
  "$unscoped_wall" "$scoped_wall" "$unscoped_cpu" "$scoped_cpu" \
  "$affected_repository_root_entries" "$affected_repository_entries" \
  "$unscoped_evicted" "$scoped_evicted"

echo "TinyBuddy Git refresh benchmark passed: repositories=$REPOSITORY_COUNT events_per_repository=$EVENTS_PER_REPOSITORY tree_entries=$TREE_ENTRIES expected_events=$expected_count"
