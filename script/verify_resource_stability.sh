#!/usr/bin/env bash
# Local-only resource stability verifier for the Debug TinyBuddy app.
#
# The default budgets are intentionally measured after a warm baseline: 16 MiB
# RSS and six threads allow normal AppKit/Swift/WidgetKit settling while still
# making a repeating lifecycle allocation visible.  A CPU value at or above
# 15% for three consecutive 30-second samples is treated as a sustained idle
# load.  Six non-decreasing RSS samples that add 8 MiB catch gradual growth
# before the final RSS cap.  Override any value with the variables printed by
# --help when establishing a machine-specific baseline.
#
# This command requires an interactive macOS desktop session because it uses
# AppleScript activation to create active/resign lifecycle transitions.  It
# never installs or signs the app and always terminates the launched PID.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="TinyBuddy"
APP_BUNDLE="$ROOT_DIR/.build/xcode/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
BUNDLE_ID="com.ryukeili.TinyBuddy"

DURATION_SECONDS="${TINYBUDDY_RESOURCE_DURATION_SECONDS:-600}"
SAMPLE_INTERVAL_SECONDS="${TINYBUDDY_RESOURCE_SAMPLE_INTERVAL_SECONDS:-30}"
WARMUP_SECONDS="${TINYBUDDY_RESOURCE_WARMUP_SECONDS:-15}"
CYCLE_COUNT="${TINYBUDDY_RESOURCE_CYCLE_COUNT:-25}"
CYCLE_SETTLE_SECONDS="${TINYBUDDY_RESOURCE_CYCLE_SETTLE_SECONDS:-1}"
RSS_DELTA_KB="${TINYBUDDY_RESOURCE_RSS_DELTA_KB:-16384}"
THREAD_DELTA="${TINYBUDDY_RESOURCE_THREAD_DELTA:-6}"
SUSTAINED_CPU_PERCENT="${TINYBUDDY_RESOURCE_SUSTAINED_CPU_PERCENT:-15}"
SUSTAINED_CPU_SAMPLES="${TINYBUDDY_RESOURCE_SUSTAINED_CPU_SAMPLES:-3}"
MONOTONIC_SAMPLES="${TINYBUDDY_RESOURCE_MONOTONIC_SAMPLES:-6}"
MONOTONIC_GROWTH_KB="${TINYBUDDY_RESOURCE_MONOTONIC_GROWTH_KB:-8192}"
SKIP_INTERNAL_TESTS="${TINYBUDDY_RESOURCE_SKIP_INTERNAL_TESTS:-0}"

APP_PID=""
SAMPLES_FILE=""
WARM_RSS_KB=""
WARM_THREADS=""
START_SECONDS=0
MONITOR_START_SECONDS=0
PREEXISTING_PIDS=""

usage() {
  cat <<'USAGE'
usage: script/verify_resource_stability.sh [--help|--dry-run|--thread-count pid|--evaluate-samples path]

Builds and launches the unsigned Debug app, runs lifecycle cycles through
AppleScript, then writes CSV samples to stdout:
  elapsed_seconds,rss_kb,cpu_percent,thread_count,alive,state

Defaults: duration=600s, interval=30s, warmup=15s, cycles=25.
Budgets (relative to the warm baseline): RSS final delta <= 16384 KB, maximum
thread delta <= 6, CPU < 15% for every 3 consecutive samples, and no run of
6 non-decreasing RSS samples that grows by >= 8192 KB.

Environment overrides:
  TINYBUDDY_RESOURCE_DURATION_SECONDS (default 600; may be reduced locally)
  TINYBUDDY_RESOURCE_SAMPLE_INTERVAL_SECONDS (default 30)
  TINYBUDDY_RESOURCE_WARMUP_SECONDS (default 15)
  TINYBUDDY_RESOURCE_CYCLE_COUNT (default/minimum 25)
  TINYBUDDY_RESOURCE_CYCLE_SETTLE_SECONDS (default 1)
  TINYBUDDY_RESOURCE_RSS_DELTA_KB (default 16384)
  TINYBUDDY_RESOURCE_THREAD_DELTA (default 6)
  TINYBUDDY_RESOURCE_SUSTAINED_CPU_PERCENT (default 15)
  TINYBUDDY_RESOURCE_SUSTAINED_CPU_SAMPLES (default 3)
  TINYBUDDY_RESOURCE_MONOTONIC_SAMPLES (default 6)
  TINYBUDDY_RESOURCE_MONOTONIC_GROWTH_KB (default 8192)
  TINYBUDDY_RESOURCE_SKIP_INTERNAL_TESTS=1 (skip deterministic invariant tests)
USAGE
}

is_positive_integer() {
  [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]
}

is_nonnegative_integer() {
  [[ "$1" =~ ^[0-9]+$ ]]
}

validate_configuration() {
  local value
  for value in "$SAMPLE_INTERVAL_SECONDS" "$WARMUP_SECONDS" "$CYCLE_SETTLE_SECONDS" \
    "$RSS_DELTA_KB" "$THREAD_DELTA" "$SUSTAINED_CPU_SAMPLES" "$MONOTONIC_SAMPLES" \
    "$MONOTONIC_GROWTH_KB"
  do
    is_positive_integer "$value" || { echo "expected a positive integer, got: $value" >&2; return 2; }
  done
  is_nonnegative_integer "$DURATION_SECONDS" || { echo "duration must be a non-negative integer" >&2; return 2; }
  is_positive_integer "$CYCLE_COUNT" && [ "$CYCLE_COUNT" -ge 25 ] || {
    echo "TINYBUDDY_RESOURCE_CYCLE_COUNT must be at least 25" >&2
    return 2
  }
  /usr/bin/awk -v value="$SUSTAINED_CPU_PERCENT" 'BEGIN { exit !(value + 0 > 0) }' || {
    echo "TINYBUDDY_RESOURCE_SUSTAINED_CPU_PERCENT must be positive" >&2
    return 2
  }
}

print_configuration() {
  printf 'duration_seconds,%s\n' "$DURATION_SECONDS"
  printf 'sample_interval_seconds,%s\n' "$SAMPLE_INTERVAL_SECONDS"
  printf 'warmup_seconds,%s\n' "$WARMUP_SECONDS"
  printf 'cycle_count,%s\n' "$CYCLE_COUNT"
  printf 'rss_delta_kb,%s\n' "$RSS_DELTA_KB"
  printf 'thread_delta,%s\n' "$THREAD_DELTA"
  printf 'sustained_cpu_percent,%s\n' "$SUSTAINED_CPU_PERCENT"
}

is_preexisting_pid() {
  case " $PREEXISTING_PIDS " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

is_owned_app_process() {
  local command

  [ -n "$APP_PID" ] && /bin/kill -0 "$APP_PID" 2>/dev/null || return 1
  if ! command="$(LC_ALL=C /bin/ps -p "$APP_PID" -o comm= 2>&1)"; then
    echo "ps ownership check failed for PID $APP_PID: $command" >&2
    return 2
  fi
  [ "$(printf '%s\n' "$command" | /usr/bin/xargs)" = "$APP_BINARY" ]
}

thread_count_for_pid() {
  local pid="$1" raw count

  if ! raw="$(LC_ALL=C /bin/ps -M -p "$pid" -o pid= 2>&1)"; then
    echo "ps thread count failed for PID $pid: $raw" >&2
    return 1
  fi
  count="$(printf '%s\n' "$raw" | /usr/bin/awk 'NR > 1 && NF { count++ } END { print count + 0 }')"
  if ! is_positive_integer "$count"; then
    echo "unable to determine thread count for PID $pid: $raw" >&2
    return 1
  fi
  printf '%s\n' "$count"
}

cleanup() {
  local attempt
  if is_owned_app_process; then
    /bin/kill "$APP_PID" 2>/dev/null || true
    for attempt in 1 2 3 4 5; do
      is_owned_app_process || break
      /bin/sleep 1
    done
    is_owned_app_process && /bin/kill -9 "$APP_PID" 2>/dev/null || true
  fi
  [ -n "$SAMPLES_FILE" ] && /bin/rm -f "$SAMPLES_FILE"
  return 0
}

trap cleanup EXIT
trap 'exit 130' HUP INT TERM

run_internal_invariant_tests() {
  if [ "$SKIP_INTERNAL_TESTS" = "1" ]; then
    echo "skipping deterministic lifecycle invariant tests" >&2
    return 0
  fi

  echo "running deterministic lifecycle invariant tests before OS sampling" >&2
  "$ROOT_DIR/script/swiftpm.sh" test --filter GitActivityRefreshCoordinatorTests >&2
  "$ROOT_DIR/script/swiftpm.sh" test --filter PetViewModelTests >&2
}

wait_for_app_pid() {
  local attempt candidate candidates status
  for attempt in $(/usr/bin/seq 1 30); do
    if candidates="$(/usr/bin/pgrep -x "$APP_NAME" 2>&1)"; then
      :
    else
      status="$?"
      if [ "$status" -ne 1 ]; then
        echo "pgrep launch check failed: $candidates" >&2
        return 1
      fi
      candidates=""
    fi
    for candidate in $candidates; do
      if is_preexisting_pid "$candidate"; then
        continue
      fi
      APP_PID="$candidate"
      if is_owned_app_process; then
        return 0
      else
        status="$?"
      fi
      [ "$status" -eq 1 ] || return 1
    done
    APP_PID=""
    /bin/sleep 1
  done
  echo "could not find launched $APP_NAME process at $APP_BINARY" >&2
  return 1
}

record_sample() {
  local state="$1" elapsed raw rss cpu threads line
  elapsed="$((SECONDS - START_SECONDS))"
  if is_owned_app_process; then
    :
  else
    local ownership_status="$?"
    [ "$ownership_status" -eq 1 ] || return "$ownership_status"
    line="${elapsed},,,,0,${state}"
    printf '%s\n' "$line" | /usr/bin/tee -a "$SAMPLES_FILE"
    echo "app process exited while sampling ($state)" >&2
    return 1
  fi

  if ! raw="$(LC_ALL=C /bin/ps -p "$APP_PID" -o rss= -o %cpu= 2>&1)"; then
    echo "ps sample failed for PID $APP_PID: $raw" >&2
    return 1
  fi
  read -r rss cpu <<< "$(printf '%s\n' "$raw" | /usr/bin/awk '{ print $1, $2 }')"
  threads="$(thread_count_for_pid "$APP_PID")" || return 1
  if ! is_positive_integer "$rss" || ! is_positive_integer "$threads" || \
    ! /usr/bin/awk -v value="$cpu" 'BEGIN { exit !(value + 0 >= 0) }'; then
    echo "unable to parse ps sample for PID $APP_PID: $raw" >&2
    return 1
  fi

  line="${elapsed},${rss},${cpu},${threads},1,${state}"
  printf '%s\n' "$line" | /usr/bin/tee -a "$SAMPLES_FILE"
  if [ "$state" = "warm" ]; then
    WARM_RSS_KB="$rss"
    WARM_THREADS="$threads"
  fi
}

run_lifecycle_cycles() {
  local cycle
  for cycle in $(/usr/bin/seq 1 "$CYCLE_COUNT"); do
    /usr/bin/osascript -e "tell application id \"$BUNDLE_ID\" to activate" >/dev/null
    /bin/sleep "$CYCLE_SETTLE_SECONDS"
    /usr/bin/osascript -e 'tell application id "com.apple.finder" to activate' >/dev/null
    /bin/sleep "$CYCLE_SETTLE_SECONDS"
    echo "completed lifecycle cycle $cycle/$CYCLE_COUNT" >&2
  done
}

evaluate_budgets() {
  local samples_path="${1:-$SAMPLES_FILE}"
  local required_samples="$(( (DURATION_SECONDS + SAMPLE_INTERVAL_SECONDS - 1) / SAMPLE_INTERVAL_SECONDS ))"

  /usr/bin/awk -F, \
    -v rssCap="$RSS_DELTA_KB" \
    -v threadCap="$THREAD_DELTA" \
    -v cpuCap="$SUSTAINED_CPU_PERCENT" \
    -v cpuSamples="$SUSTAINED_CPU_SAMPLES" \
    -v monotonicSamples="$MONOTONIC_SAMPLES" \
    -v monotonicGrowth="$MONOTONIC_GROWTH_KB" \
    -v requiredSamples="$required_samples" '
      BEGIN { maxThreadDelta = 0 }
      function isPositiveInteger(value) { return value ~ /^[0-9]+$/ && value + 0 > 0 }
      function isNonnegativeNumber(value) { return value ~ /^[0-9]+([.][0-9]+)?$/ }
      NR == 1 {
        headerSeen = 1
        if ($0 != "elapsed_seconds,rss_kb,cpu_percent,thread_count,alive,state") {
          print "FAIL: unexpected sample header" > "/dev/stderr"
          failed = 1
        }
        next
      }
      {
        if (NF != 6) {
          print "FAIL: malformed sample row " NR > "/dev/stderr"
          failed = 1
          next
        }
        if (!isPositiveInteger($1) && $1 != "0") {
          print "FAIL: invalid elapsed seconds at row " NR > "/dev/stderr"
          failed = 1
          next
        }
        if ($5 != 1) { print "FAIL: process was not alive at " $6 > "/dev/stderr"; failed = 1; next }
        if (!isPositiveInteger($2) || !isNonnegativeNumber($3) || !isPositiveInteger($4)) {
          print "FAIL: invalid process sample at row " NR > "/dev/stderr"
          failed = 1
          next
        }
      }
      $6 == "warm" {
        if (warmSeen++) {
          print "FAIL: duplicate warm baseline" > "/dev/stderr"
          failed = 1
          next
        }
        warmRSS = $2 + 0
        warmThreads = $4 + 0
        next
      }
      {
        if (!warmSeen) {
          print "FAIL: sample recorded before warm baseline" > "/dev/stderr"
          failed = 1
          next
        }
        if ($6 != "post_cycles" && $6 != "sample") {
          print "FAIL: unknown sample state " $6 > "/dev/stderr"
          failed = 1
          next
        }
        rss = $2 + 0
        cpu = $3 + 0
        threads = $4 + 0
        finalRSS = rss
        measurementCount++
        if (threads - warmThreads > maxThreadDelta) maxThreadDelta = threads - warmThreads
        if ($6 == "sample") {
          sampleCount++
          if (cpu >= cpuCap) cpuRun++; else cpuRun = 0
          if (cpuRun >= cpuSamples) {
            print "FAIL: sustained CPU " cpu "% for " cpuRun " samples" > "/dev/stderr"
            failed = 1
          }
        }
        if (!havePrevious || rss < previousRSS) {
          runStartRSS = rss
          nondecreasingRun = 1
        } else {
          nondecreasingRun++
        }
        if (nondecreasingRun >= monotonicSamples && rss - runStartRSS >= monotonicGrowth) {
          print "FAIL: RSS grew monotonically by " (rss - runStartRSS) " KB across " nondecreasingRun " samples" > "/dev/stderr"
          failed = 1
        }
        previousRSS = rss
        havePrevious = 1
      }
      END {
        if (!headerSeen) {
          print "FAIL: sample file is empty" > "/dev/stderr"
          failed = 1
        }
        if (!warmSeen) {
          print "FAIL: missing warm baseline" > "/dev/stderr"
          failed = 1
        }
        if (!measurementCount) {
          print "FAIL: missing post-warm samples" > "/dev/stderr"
          failed = 1
        }
        if (sampleCount + 0 < requiredSamples) {
          print "FAIL: expected at least " requiredSamples " monitoring samples, got " (sampleCount + 0) > "/dev/stderr"
          failed = 1
        }
        if (!warmSeen || !measurementCount) exit 1
        finalDelta = finalRSS - warmRSS
        if (finalDelta > rssCap) {
          print "FAIL: final RSS delta " finalDelta " KB exceeds " rssCap " KB" > "/dev/stderr"
          failed = 1
        }
        if (maxThreadDelta > threadCap) {
          print "FAIL: thread delta " maxThreadDelta " exceeds " threadCap > "/dev/stderr"
          failed = 1
        }
        if (failed) exit 1
        print "PASS: final RSS delta=" finalDelta " KB, max thread delta=" maxThreadDelta > "/dev/stderr"
      }
    ' "$samples_path"
}

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --dry-run)
    validate_configuration
    print_configuration
    exit 0
    ;;
  --thread-count)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    is_positive_integer "$2" || { echo "PID must be a positive integer" >&2; exit 2; }
    thread_count_for_pid "$2"
    exit "$?"
    ;;
  --evaluate-samples)
    [ "$#" -eq 2 ] || { usage >&2; exit 2; }
    validate_configuration
    [ -f "$2" ] || { echo "sample file does not exist: $2" >&2; exit 2; }
    evaluate_budgets "$2"
    exit "$?"
    ;;
  "")
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

validate_configuration
SAMPLES_FILE="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/tinybuddy-resource.XXXXXX")"

if PREEXISTING_PIDS="$(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null)"; then
  :
else
  PREEXISTING_PIDS=""
fi

run_internal_invariant_tests
echo "building and launching unsigned Debug app" >&2
TINYBUDDY_BUILD_CONFIGURATION=Debug TINYBUDDY_SIGNING_MODE=unsigned \
  "$ROOT_DIR/script/build_and_run.sh" >&2
wait_for_app_pid

START_SECONDS="$SECONDS"
echo "warming PID $APP_PID for ${WARMUP_SECONDS}s" >&2
/bin/sleep "$WARMUP_SECONDS"
printf 'elapsed_seconds,rss_kb,cpu_percent,thread_count,alive,state\n' | /usr/bin/tee "$SAMPLES_FILE"
record_sample warm
run_lifecycle_cycles
record_sample post_cycles
MONITOR_START_SECONDS="$SECONDS"

while [ $((SECONDS - MONITOR_START_SECONDS)) -lt "$DURATION_SECONDS" ]; do
  remaining_seconds="$((DURATION_SECONDS - (SECONDS - MONITOR_START_SECONDS)))"
  sleep_seconds="$SAMPLE_INTERVAL_SECONDS"
  [ "$remaining_seconds" -lt "$sleep_seconds" ] && sleep_seconds="$remaining_seconds"
  /bin/sleep "$sleep_seconds"
  record_sample sample
done

evaluate_budgets
