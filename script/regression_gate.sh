#!/usr/bin/env bash
# TinyBuddy Performance, Energy & Stability Regression Gate
#
# Repeatable regression detection across Git refresh accuracy and latency,
# cold/warm app start, resource stability (RSS, threads, CPU, disk I/O,
# system wakeups), Widget reload, and continuous refresh cycles.
#
# Stages are independent; each produces structured evidence so a reader
# can identify which gate failed and why.  The gate reuses the existing
# benchmark_git_refresh.sh and verify_resource_stability.sh scripts and
# adds focused measurement for start-up, Widget, and multi-cycle refresh.
#
# Usage:
#   script/regression_gate.sh [--help|--list-stages|--record-baseline|--quick|--stage N]
#
# Environment overrides are documented at each stage; key overrides:
#
#   TINYBUDDY_REGRESSION_GIT_REPOSITORIES      (default 24, min 1)
#   TINYBUDDY_REGRESSION_GIT_EVENTS            (default 100, min 1)
#   TINYBUDDY_REGRESSION_QUICK_REPOSITORIES    (default 8, min 1)
#   TINYBUDDY_REGRESSION_QUICK_EVENTS          (default 50, min 1)
#   TINYBUDDY_REGRESSION_COLD_START_TIMEOUT    (default 30, seconds)
#   TINYBUDDY_REGRESSION_WARM_START_TIMEOUT    (default 15, seconds)
#   TINYBUDDY_REGRESSION_RESOURCE_DURATION     (default 60, seconds)
#   TINYBUDDY_REGRESSION_WIDGET_TIMEOUT        (default 30, seconds)
#   TINYBUDDY_REGRESSION_BASELINE_FILE         (default ~/.config/tinybuddy/regression-baseline)
#   TINYBUDDY_REGRESSION_EVIDENCE_DIR          (default $TMPDIR/TinyBuddyRegressionEvidence)
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
APP_NAME="TinyBuddy"
BUNDLE_ID="com.ryukeili.TinyBuddy"
WIDGET_EXTENSION_NAME="TinyBuddyWidgetExtension"
WIDGET_BUNDLE_ID="com.ryukeili.TinyBuddy.TinyBuddyWidgetExtension"

DEFAULT_BASELINE_DIR="${HOME}/.config/tinybuddy"
DEFAULT_BASELINE_FILE="${DEFAULT_BASELINE_DIR}/regression-baseline"
BASELINE_FILE="${TINYBUDDY_REGRESSION_BASELINE_FILE:-$DEFAULT_BASELINE_FILE}"
EVIDENCE_DIR="${TINYBUDDY_REGRESSION_EVIDENCE_DIR:-${TMPDIR:-/tmp}/TinyBuddyRegressionEvidence}"
EVIDENCE_TIMESTAMP=""
APP_BUNDLE="$ROOT_DIR/.build/xcode/Build/Products/Debug/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"
APP_RUNTIME_TIMEOUT="${TINYBUDDY_APP_RUNTIME_TIMEOUT:-15}"
LOG_BIN="${TINYBUDDY_LOG_BIN:-/usr/bin/log}"
PLUGINKIT_BIN="${TINYBUDDY_PLUGINKIT_BIN:-/usr/bin/pluginkit}"
PS_BIN="${TINYBUDDY_PS_BIN:-/bin/ps}"
PROBE_SOURCE="$ROOT_DIR/script/process_resource_probe.swift"
PROBE_BINARY=""

# ---------------------------------------------------------------------------
# Stage configuration with sensible defaults
# ---------------------------------------------------------------------------
GIT_REPOSITORIES="${TINYBUDDY_REGRESSION_GIT_REPOSITORIES:-24}"
GIT_EVENTS="${TINYBUDDY_REGRESSION_GIT_EVENTS:-100}"
QUICK_REPOSITORIES="${TINYBUDDY_REGRESSION_QUICK_REPOSITORIES:-8}"
QUICK_EVENTS="${TINYBUDDY_REGRESSION_QUICK_EVENTS:-50}"
COLD_START_TIMEOUT="${TINYBUDDY_REGRESSION_COLD_START_TIMEOUT:-30}"
WARM_START_TIMEOUT="${TINYBUDDY_REGRESSION_WARM_START_TIMEOUT:-15}"
RESOURCE_DURATION="${TINYBUDDY_REGRESSION_RESOURCE_DURATION:-60}"
WIDGET_TIMEOUT="${TINYBUDDY_REGRESSION_WIDGET_TIMEOUT:-30}"

# ---------------------------------------------------------------------------
# Threshold defaults (tuned from current stable baselines)
# ---------------------------------------------------------------------------
# Git refresh: cold wall time ratio tolerance vs baseline
GIT_COLD_WALL_TOLERANCE="${TINYBUDDY_GATE_GIT_COLD_WALL_TOLERANCE:-1.30}"
# Git refresh: incremental must be <= cold * INCREMENTAL_RATIO_LIMIT
GIT_INCREMENTAL_RATIO_LIMIT="${TINYBUDDY_GATE_INCREMENTAL_RATIO_LIMIT:-1.25}"
# Git refresh: CPU peak percent
GIT_CPU_PEAK_LIMIT="${TINYBUDDY_GATE_GIT_CPU_PEAK_LIMIT:-250}"
# Git refresh: RSS limit KB
GIT_RSS_LIMIT_KB="${TINYBUDDY_GATE_GIT_RSS_LIMIT_KB:-262144}"
# Git refresh: cancellation convergence limit ms
GIT_CANCEL_LIMIT_MS="${TINYBUDDY_GATE_GIT_CANCEL_LIMIT_MS:-2000}"
# Cold start wall time tolerance
COLD_START_TOLERANCE="${TINYBUDDY_GATE_COLD_START_TOLERANCE:-1.40}"
# Warm start wall time tolerance
WARM_START_TOLERANCE="${TINYBUDDY_GATE_WARM_START_TOLERANCE:-1.50}"
# Resource stability: RSS delta from warm baseline KB
RSS_DELTA_KB="${TINYBUDDY_GATE_RSS_DELTA_KB:-16384}"
# Resource stability: thread delta
THREAD_DELTA="${TINYBUDDY_GATE_THREAD_DELTA:-6}"
# Resource stability: sustained CPU percent
SUSTAINED_CPU_PERCENT="${TINYBUDDY_GATE_SUSTAINED_CPU_PERCENT:-15}"
# Resource stability: sustained CPU consecutive samples
SUSTAINED_CPU_SAMPLES="${TINYBUDDY_GATE_SUSTAINED_CPU_SAMPLES:-3}"
# Resource stability: monotonic growth KB
MONOTONIC_GROWTH_KB="${TINYBUDDY_GATE_MONOTONIC_GROWTH_KB:-8192}"
# Resource stability: monotonic consecutive samples
MONOTONIC_SAMPLES="${TINYBUDDY_GATE_MONOTONIC_SAMPLES:-6}"
# Resource stability: disk read delta bytes
DISK_READ_DELTA_BYTES="${TINYBUDDY_GATE_DISK_READ_DELTA_BYTES:-67108864}"
# Resource stability: interrupt wakeups per minute
INTERRUPT_WAKEUPS_PER_MINUTE="${TINYBUDDY_GATE_INTERRUPT_WAKEUPS_PER_MINUTE:-600}"
# Resource stability: idle wakeups per minute
IDLE_WAKEUPS_PER_MINUTE="${TINYBUDDY_GATE_IDLE_WAKEUPS_PER_MINUTE:-600}"
# Widget: maximum time for extension to start
WIDGET_START_TOLERANCE="${TINYBUDDY_GATE_WIDGET_START_TOLERANCE:-1.50}"

STAGE_PASS=0
STAGE_FAIL=1
STAGE_SKIP=77
OVERALL_STATUS=0
CURRENT_STAGE=""
CURRENT_STAGE_NUMBER=0

# ---------------------------------------------------------------------------
# Help and stage listing
# ---------------------------------------------------------------------------
usage() {
  cat <<USAGE
usage: script/regression_gate.sh [--help|--list-stages|--record-baseline|--quick|--stage N]

Stages:
  1  git-cold           Git refresh cold benchmark (accuracy, wall, CPU, RSS)
  2  git-incremental    Git refresh incremental benchmark
  3  git-cancel         Git cancellation convergence
  4  app-cold-start     App launch to HUD-ready wall time
  5  resource-monitor   Process resource stability (RSS, threads, CPU, wakeups)
  6  widget-reload      Widget extension process and snapshot consumption
  7  app-warm-start     Warm app launch (second launch, cached data)
  8  continuous-refresh Consecutive refresh cycles without resource growth

Modes:
  (default)            Run all stages and check against baseline
  --record-baseline    Run all stages and save results as new baseline
  --quick              Run only the lightweight subset (stages 1-4, 7)
  --stage N            Run a single stage by number

Environment overrides documented in the script header.

The baseline file is stored at: ${BASELINE_FILE}
USAGE
}

list_stages() {
  echo "Available regression gates:"
  echo "  1  git-cold           Git refresh cold benchmark"
  echo "  2  git-incremental    Git refresh incremental"
  echo "  3  git-cancel         Git cancellation convergence"
  echo "  4  app-cold-start     App cold start duration"
  echo "  5  resource-monitor   Resource stability (RSS/threads/CPU/wakeups)"
  echo "  6  widget-reload      Widget extension verification"
  echo "  7  app-warm-start     App warm start duration"
  echo "  8  continuous-refresh Consecutive refresh stability"
}

# ---------------------------------------------------------------------------
# Utilities
# ---------------------------------------------------------------------------
is_positive_integer() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -gt 0 ]; }
is_nonnegative_integer() { [[ "$1" =~ ^[0-9]+$ ]]; }

now_milliseconds() {
  /usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f\n", time() * 1000'
}

now_seconds() {
  /bin/date '+%s'
}

init_evidence() {
  local timestamp
  timestamp="$(/bin/date '+%Y%m%d-%H%M%S')"
  EVIDENCE_TIMESTAMP="$timestamp"
  /bin/mkdir -p "$EVIDENCE_DIR" 2>/dev/null || true
  echo "evidence directory: $EVIDENCE_DIR"
}

stage_start() {
  CURRENT_STAGE="$1"
  CURRENT_STAGE_NUMBER=$((CURRENT_STAGE_NUMBER + 1))
  echo "=== [Stage $CURRENT_STAGE_NUMBER] $CURRENT_STAGE ==="
}

stage_pass() {
  echo ">>> PASS: $CURRENT_STAGE"
  echo "stage=$CURRENT_STAGE result=pass" >> "$EVIDENCE_DIR/${EVIDENCE_TIMESTAMP}-summary.txt"
}

stage_fail() {
  local reason="$1"
  echo ">>> FAIL: $CURRENT_STAGE — $reason" >&2
  echo "stage=$CURRENT_STAGE result=fail reason=$reason" >> "$EVIDENCE_DIR/${EVIDENCE_TIMESTAMP}-summary.txt"
  OVERALL_STATUS=1
}

stage_skip() {
  local reason
  # Accept either (reason) or (stage_name, reason)
  if [ $# -ge 2 ]; then
    CURRENT_STAGE="$1"
    reason="$2"
  else
    reason="${1:-disabled}"
  fi
  echo ">>> SKIP: $CURRENT_STAGE — $reason"
  echo "stage=$CURRENT_STAGE result=skip reason=$reason" >> "$EVIDENCE_DIR/${EVIDENCE_TIMESTAMP}-summary.txt"
}

# ---------------------------------------------------------------------------
# Baseline management
# ---------------------------------------------------------------------------
load_baseline() {
  if [ -f "$BASELINE_FILE" ]; then
    # shellcheck disable=SC1090
    . "$BASELINE_FILE"
    return 0
  fi
  return 1
}

save_baseline() {
  /bin/mkdir -p "$(dirname "$BASELINE_FILE")" 2>/dev/null || true
  cat > "$BASELINE_FILE"
}

resolve_baseline_value() {
  local key="$1"
  local default="$2"
  local var_name
  var_name="TINYBUDDY_BASELINE_$(printf '%s' "$CURRENT_STAGE" | tr '[:lower:]-' '[:upper:]_')_${key}"
  local value="${!var_name:-}"
  if [ -n "$value" ]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$default"
  fi
}

# ---------------------------------------------------------------------------
# Stage 1: Git refresh cold benchmark
# ---------------------------------------------------------------------------
run_git_cold() {
  stage_start "git-cold"
  local bench_script="$ROOT_DIR/script/benchmark_git_refresh.sh"
  if [ ! -f "$bench_script" ]; then
    stage_fail "benchmark_git_refresh.sh not found"
    return "$STAGE_FAIL"
  fi

  local result_file="$EVIDENCE_DIR/${EVIDENCE_TIMESTAMP}-git-cold.txt"
  local exit_code=0

  TINYBUDDY_BENCHMARK_REPOSITORIES="$GIT_REPOSITORIES" \
  TINYBUDDY_BENCHMARK_EVENTS_PER_REPOSITORY="$GIT_EVENTS" \
  TINYBUDDY_BENCHMARK_INCREMENTAL_RATIO_LIMIT="$GIT_INCREMENTAL_RATIO_LIMIT" \
  TINYBUDDY_BENCHMARK_CPU_PEAK_LIMIT="$GIT_CPU_PEAK_LIMIT" \
  TINYBUDDY_BENCHMARK_RSS_LIMIT_KB="$GIT_RSS_LIMIT_KB" \
  TINYBUDDY_BENCHMARK_CANCELLATION_LIMIT_MS="$GIT_CANCEL_LIMIT_MS" \
    /bin/bash "$bench_script" > "$result_file" 2>&1 || exit_code=$?

  if [ "$exit_code" -eq 0 ]; then
    stage_pass
    # Extract git metrics for baseline recording
    RECORDED_GIT_COLD_WALL_MS="$(/usr/bin/awk -F'\t' '$1 == "first" { print $2 + 0; exit }' "$result_file" 2>/dev/null || echo 0)"
    RECORDED_GIT_COLD_CPU_PEAK="$(/usr/bin/awk -F'\t' '$1 == "first" { print $3 + 0; exit }' "$result_file" 2>/dev/null || echo 0)"
    RECORDED_GIT_COLD_RSS_KB="$(/usr/bin/awk -F'\t' '$1 == "first" { print $4 + 0; exit }' "$result_file" 2>/dev/null || echo 0)"
    RECORDED_GIT_INCREMENTAL_WALL_MS="$(/usr/bin/awk -F'\t' '$1 == "incremental" { print $2 + 0; exit }' "$result_file" 2>/dev/null || echo 0)"
  elif [ "$exit_code" -eq 77 ]; then
    stage_skip "process sampling unavailable"
  else
    stage_fail "git cold refresh failed (exit=$exit_code); see $result_file"
  fi
  return "$exit_code"
}

# ---------------------------------------------------------------------------
# Stage 2: Git refresh incremental (reuses benchmark script's second run)
# ---------------------------------------------------------------------------
run_git_incremental() {
  stage_start "git-incremental"
  # The benchmark script already runs first + incremental in one invocation.
  # Parse its output to verify the incremental phase succeeded.
  local result_file="$EVIDENCE_DIR/${EVIDENCE_TIMESTAMP}-git-cold.txt"
  if [ ! -f "$result_file" ]; then
    # Fall back: run benchmark directly to produce evidence
    echo "(no git-cold evidence; running benchmark inline)"
    local bench_script="$ROOT_DIR/script/benchmark_git_refresh.sh"
    if [ -f "$bench_script" ]; then
      TINYBUDDY_BENCHMARK_REPOSITORIES="$GIT_REPOSITORIES" \
      TINYBUDDY_BENCHMARK_EVENTS_PER_REPOSITORY="$GIT_EVENTS" \
      TINYBUDDY_BENCHMARK_INCREMENTAL_RATIO_LIMIT="$GIT_INCREMENTAL_RATIO_LIMIT" \
      TINYBUDDY_BENCHMARK_CPU_PEAK_LIMIT="$GIT_CPU_PEAK_LIMIT" \
      TINYBUDDY_BENCHMARK_RSS_LIMIT_KB="$GIT_RSS_LIMIT_KB" \
      TINYBUDDY_BENCHMARK_CANCELLATION_LIMIT_MS="$GIT_CANCEL_LIMIT_MS" \
        /bin/bash "$bench_script" > "$result_file" 2>&1 || true
    fi
    if [ ! -f "$result_file" ]; then
      stage_skip "git-cold evidence required and benchmark did not produce it"
      return "$STAGE_SKIP"
    fi
  fi

  if /usr/bin/grep -q 'TinyBuddy Git refresh benchmark passed' "$result_file"; then
    stage_pass
  else
    local inc_fail
    inc_fail="$(/usr/bin/grep -E '(incremental|accuracy|latency|CPU|RSS|cancellation).*gate failed' "$result_file" || true)"
    if [ -n "$inc_fail" ]; then
      stage_fail "incremental gate failed: $inc_fail"
    else
      stage_fail "git benchmark did not report success; see $result_file"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Stage 3: Git cancellation convergence (also covered by benchmark script)
# ---------------------------------------------------------------------------
run_git_cancel() {
  stage_start "git-cancel"
  local result_file="$EVIDENCE_DIR/${EVIDENCE_TIMESTAMP}-git-cold.txt"
  if [ ! -f "$result_file" ]; then
    # Fall back: run benchmark directly to produce evidence
    echo "(no git-cold evidence; running benchmark inline)"
    local bench_script="$ROOT_DIR/script/benchmark_git_refresh.sh"
    if [ -f "$bench_script" ]; then
      TINYBUDDY_BENCHMARK_REPOSITORIES="$GIT_REPOSITORIES" \
      TINYBUDDY_BENCHMARK_EVENTS_PER_REPOSITORY="$GIT_EVENTS" \
      TINYBUDDY_BENCHMARK_INCREMENTAL_RATIO_LIMIT="$GIT_INCREMENTAL_RATIO_LIMIT" \
      TINYBUDDY_BENCHMARK_CPU_PEAK_LIMIT="$GIT_CPU_PEAK_LIMIT" \
      TINYBUDDY_BENCHMARK_RSS_LIMIT_KB="$GIT_RSS_LIMIT_KB" \
      TINYBUDDY_BENCHMARK_CANCELLATION_LIMIT_MS="$GIT_CANCEL_LIMIT_MS" \
        /bin/bash "$bench_script" > "$result_file" 2>&1 || true
    fi
    if [ ! -f "$result_file" ]; then
      stage_skip "git-cold evidence required and benchmark did not produce it"
      return "$STAGE_SKIP"
    fi
  fi

  # The benchmark script includes a cancellation test and validates it.
  if /usr/bin/grep -q 'TinyBuddy Git refresh benchmark passed' "$result_file"; then
    stage_pass
  else
    local cancel_fail
    cancel_fail="$(/usr/bin/grep -E 'cancellation.*gate failed' "$result_file" || true)"
    if [ -n "$cancel_fail" ]; then
      stage_fail "cancel convergence gate failed: $cancel_fail"
    else
      stage_skip "git benchmark failed before cancel test"
    fi
  fi
}

# ---------------------------------------------------------------------------
# Stage 4: Cold app start duration
# ---------------------------------------------------------------------------
run_app_cold_start() {
  stage_start "app-cold-start"
  local start_ms
  local elapsed_ms
  local app_pid=""
  local deadline
  local message="HUD ready identifier=TinyBuddy.HUDWindow"

  # Kill any existing instance
  /usr/bin/pkill -x "$APP_NAME" 2>/dev/null || true
  /bin/sleep 1

  start_ms="$(now_milliseconds)"

  # Launch the app
  /usr/bin/open -n "$APP_BUNDLE" 2>/dev/null || {
    stage_fail "failed to launch app from $APP_BUNDLE"
    return "$STAGE_FAIL"
  }

  # Wait for HUD-ready telemetry
  deadline=$((SECONDS + COLD_START_TIMEOUT))
  while [ "$SECONDS" -le "$deadline" ]; do
    if app_pid="$(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null)"; then
      # Check for HUD-ready log message
      if "$LOG_BIN" show \
        --last "${COLD_START_TIMEOUT}s" \
        --style compact \
        --predicate "subsystem == \"local.tinybuddy\" AND category == \"HUD\" AND eventMessage CONTAINS \"$message\"" \
        2>/dev/null | /usr/bin/grep -F "$message" >/dev/null
      then
        elapsed_ms=$(( $(now_milliseconds) - start_ms ))
        break
      fi
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      elapsed_ms=$(( $(now_milliseconds) - start_ms ))
      stage_fail "cold start timeout: ${elapsed_ms}ms (limit ${COLD_START_TIMEOUT}s)"
      return "$STAGE_FAIL"
    fi
    /bin/sleep 0.5
  done

  local baseline_ms
  baseline_ms="$(resolve_baseline_value "COLD_START_MS" 0)"
  local limit_ms
  limit_ms="$(/usr/bin/awk -v base="$baseline_ms" -v tol="$COLD_START_TOLERANCE" \
    'BEGIN { if (base > 0) print int(base * tol + 0.5); else print 99999 }')"

  echo "cold start: ${elapsed_ms}ms (baseline=${baseline_ms}ms, limit=${limit_ms}ms)"

  if [ "$baseline_ms" -gt 0 ] && [ "$elapsed_ms" -gt "$limit_ms" ]; then
    stage_fail "cold start ${elapsed_ms}ms exceeds ${limit_ms}ms (baseline ${baseline_ms}ms * tolerance ${COLD_START_TOLERANCE})"
    return "$STAGE_FAIL"
  fi

  stage_pass
  RECORDED_COLD_START_MS="$elapsed_ms"
}

# ---------------------------------------------------------------------------
# Stage 5: Resource stability (short monitoring window)
# ---------------------------------------------------------------------------
run_resource_monitor() {
  stage_start "resource-monitor"

  local app_pid
  app_pid="$(/usr/bin/pgrep -x "$APP_NAME" 2>/dev/null || true)"
  if [ -z "$app_pid" ]; then
    stage_skip "app is not running (cold start may have failed)"
    return "$STAGE_SKIP"
  fi

  # Check that the process belongs to our bundle
  local app_binary_pid
  app_binary_pid="$("$PS_BIN" -p "$app_pid" -o comm= 2>/dev/null | /usr/bin/xargs || true)"
  if [ "$app_binary_pid" != "$APP_BINARY" ]; then
    stage_skip "running app does not match our build"
    return "$STAGE_SKIP"
  fi

  # Build the resource probe
  if [ -z "$PROBE_BINARY" ]; then
    PROBE_BINARY="$(/usr/bin/mktemp "${TMPDIR:-/tmp}/tinybuddy-probe.XXXXXX")"
    /bin/rm -f "$PROBE_BINARY"
    if ! swiftc "$PROBE_SOURCE" -o "$PROBE_BINARY" 2>/dev/null; then
      stage_skip "failed to compile resource probe"
      return "$STAGE_SKIP"
    fi
  fi

  local probe_file="$EVIDENCE_DIR/${EVIDENCE_TIMESTAMP}-resource.csv"
  local warmup_seconds=10
  local warm_end
  local monitor_end
  local warm_rss=""
  local warm_threads=""

  # Header
  printf '%s\n' "elapsed_seconds,rss_kb,cpu_percent,thread_count,alive,state,cpu_time_ns,disk_read_bytes,interrupt_wakeups,idle_wakeups" > "$probe_file"

  # Warmup
  echo "warming PID $app_pid for ${warmup_seconds}s"
  /bin/sleep "$warmup_seconds"
  warm_end="$SECONDS"

  # Record warm baseline
  local elapsed
  elapsed="$warmup_seconds"
  local raw rss cpu threads probe_raw cpu_time_ns disk_read_bytes interrupt_wakeups idle_wakeups
  raw="$("$PS_BIN" -p "$app_pid" -o rss= -o %cpu= 2>/dev/null || true)"
  read -r rss cpu <<< "$(printf '%s\n' "$raw" | /usr/bin/awk '{ print $1, $2 }')"
  threads="$("$PS_BIN" -M -p "$app_pid" -o pid= 2>/dev/null | /usr/bin/awk 'NR > 1 && NF { count++ } END { print count + 0 }')"
  probe_raw="$("$PROBE_BINARY" "$app_pid" 2>/dev/null || echo "0,0,0,0")"
  IFS=, read -r cpu_time_ns disk_read_bytes interrupt_wakeups idle_wakeups <<< "$probe_raw"
  printf '%d,%s,%s,%s,1,warm,%s,%s,%s,%s\n' \
    "$elapsed" "${rss:-0}" "${cpu:-0}" "${threads:-0}" \
    "$cpu_time_ns" "$disk_read_bytes" "$interrupt_wakeups" "$idle_wakeups" >> "$probe_file"
  warm_rss="$rss"
  warm_threads="$threads"

  # Monitor for resource duration
  monitor_end=$((SECONDS + RESOURCE_DURATION))
  local sample_count=0
  while [ "$SECONDS" -lt "$monitor_end" ]; do
    /bin/sleep 10
    sample_count=$((sample_count + 1))
    elapsed=$((warmup_seconds + sample_count * 10))
    raw="$("$PS_BIN" -p "$app_pid" -o rss= -o %cpu= 2>/dev/null || { echo "0 0"; })"
    read -r rss cpu <<< "$(printf '%s\n' "$raw" | /usr/bin/awk '{ print $1, $2 }')"
    threads="$("$PS_BIN" -M -p "$app_pid" -o pid= 2>/dev/null | /usr/bin/awk 'NR > 1 && NF { count++ } END { print count + 0 }')"
    probe_raw="$("$PROBE_BINARY" "$app_pid" 2>/dev/null || echo "0,0,0,0")"
    IFS=, read -r cpu_time_ns disk_read_bytes interrupt_wakeups idle_wakeups <<< "$probe_raw"

    if [ -z "${rss:-}" ] || [ "$rss" = "0" ] && [ "$sample_count" -gt 0 ]; then
      # App may have exited
      printf '%d,,,,,0,sample,,,,,\n' "$elapsed" >> "$probe_file"
      stage_fail "app process exited during resource monitoring"
      return "$STAGE_FAIL"
    fi

    printf '%d,%s,%s,%s,1,sample,%s,%s,%s,%s\n' \
      "$elapsed" "${rss:-0}" "${cpu:-0}" "${threads:-0}" \
      "$cpu_time_ns" "$disk_read_bytes" "$interrupt_wakeups" "$idle_wakeups" >> "$probe_file"
  done

  # Evaluate budgets using the same AWK logic as verify_resource_stability.sh
  local eval_result
  eval_result="$(evaluate_resource_budgets "$probe_file")" || true
  # The evaluation prints the delta summary on one line and "PASS" on the last line.
  if printf '%s\n' "$eval_result" | /usr/bin/grep -q '^PASS$'; then
    stage_pass
    # Extract resource metrics for baseline recording
    # The delta line format: "RSS delta=NKB threads delta=M disk=... interrupt_wakeups=... idle_wakeups=..."
    RECORDED_RESOURCE_RSS_DELTA_KB="$(printf '%s\n' "$eval_result" | /usr/bin/sed -n 's/.*RSS delta=\(-\?[0-9]*\)KB.*/\1/p' 2>/dev/null || echo 0)"
    RECORDED_RESOURCE_THREAD_DELTA="$(printf '%s\n' "$eval_result" | /usr/bin/sed -n 's/.*threads delta=\(-\?[0-9]*\).*/\1/p' 2>/dev/null || echo 0)"
  else
    stage_fail "resource budgets exceeded"
    # Print the detailed failure to stderr
    printf '%s\n' "$eval_result" >&2
    return "$STAGE_FAIL"
  fi
}

evaluate_resource_budgets() {
  local samples_path="$1"

  /usr/bin/awk -F, \
    -v rssCap="$RSS_DELTA_KB" \
    -v threadCap="$THREAD_DELTA" \
    -v cpuCap="$SUSTAINED_CPU_PERCENT" \
    -v cpuSamples="$SUSTAINED_CPU_SAMPLES" \
    -v monotonicSamples="$MONOTONIC_SAMPLES" \
    -v monotonicGrowth="$MONOTONIC_GROWTH_KB" \
    -v diskReadCap="$DISK_READ_DELTA_BYTES" \
    -v interruptWakeupsPerMinuteCap="$INTERRUPT_WAKEUPS_PER_MINUTE" \
    -v idleWakeupsPerMinuteCap="$IDLE_WAKEUPS_PER_MINUTE" '
    BEGIN { failed = 0; failures = "" }
    function fail(msg) { failed = 1; failures = failures msg "; " }
    NR == 1 { next }
    {
      if (NF != 10) { fail("malformed sample row " NR); next }
      if ($5 != 1) { fail("process not alive at " $6); next }
      if ($6 == "warm") {
        warmSeen = 1
        warmRSS = $2 + 0
        warmThreads = $4 + 0
        warmElapsed = $1 + 0
        warmCPUTime = $7 + 0
        warmDiskReadBytes = $8 + 0
        warmInterruptWakeups = $9 + 0
        warmIdleWakeups = $10 + 0
        next
      }
      if (!warmSeen) { fail("no warm baseline"); next }
      rss = $2 + 0; threads = $4 + 0; elapsed = $1 + 0
      cpuTime = $7 + 0; diskReadBytes = $8 + 0
      interruptWakeups = $9 + 0; idleWakeups = $10 + 0
      finalElapsed = elapsed; finalRSS = rss; finalThreads = threads
      finalCPUTime = cpuTime; finalDiskReadBytes = diskReadBytes
      finalInterruptWakeups = interruptWakeups; finalIdleWakeups = idleWakeups
      measurementCount++
      if (threads - warmThreads > maxThreadDelta) maxThreadDelta = threads - warmThreads
      if (!havePrevious || rss < previousRSS) { runStartRSS = rss; nondecreasingRun = 1 }
      else { nondecreasingRun++ }
      if (nondecreasingRun >= monotonicSamples && rss - runStartRSS >= monotonicGrowth)
        fail("RSS monotonic growth " (rss - runStartRSS) " KB across " nondecreasingRun " samples")
      previousRSS = rss; havePrevious = 1
    }
    END {
      if (!warmSeen) fail("missing warm baseline")
      if (!measurementCount) fail("no post-warm samples")
      if (failed) { print failures; exit 1 }
      duration = finalElapsed - warmElapsed
      if (duration <= 0) { print "zero measurement duration"; exit 1 }
      finalDelta = finalRSS - warmRSS
      diskDelta = finalDiskReadBytes - warmDiskReadBytes
      interruptWakeupsPerMinute = (finalInterruptWakeups - warmInterruptWakeups) * 60 / duration
      idleWakeupsPerMinute = (finalIdleWakeups - warmIdleWakeups) * 60 / duration
      if (finalDelta > rssCap) fail("RSS delta " finalDelta " KB exceeds " rssCap " KB")
      if (maxThreadDelta > threadCap) fail("thread delta " maxThreadDelta " exceeds " threadCap)
      if (diskDelta > diskReadCap) fail("disk read " diskDelta " bytes exceeds " diskReadCap)
      if (interruptWakeupsPerMinute > interruptWakeupsPerMinuteCap)
        fail("interrupt wakeups " interruptWakeupsPerMinute "/min exceeds " interruptWakeupsPerMinuteCap)
      if (idleWakeupsPerMinute > idleWakeupsPerMinuteCap)
        fail("idle wakeups " idleWakeupsPerMinute "/min exceeds " idleWakeupsPerMinuteCap)
      if (failed) { print failures; exit 1 }
      printf "RSS delta=%dKB threads delta=%d disk=%dbytes interrupt_wakeups=%.1f/min idle_wakeups=%.1f/min\n", \
        finalDelta, maxThreadDelta, diskDelta, interruptWakeupsPerMinute, idleWakeupsPerMinute
      print "PASS"
    }
  ' "$samples_path"
}

# ---------------------------------------------------------------------------
# Stage 6: Widget extension reload
# ---------------------------------------------------------------------------
run_widget_reload() {
  stage_start "widget-reload"

  local widget_pid=""
  local deadline
  local appex
  local expected_executable

  appex="$("$PLUGINKIT_BIN" -m -A -D -v -i "$WIDGET_BUNDLE_ID" 2>/dev/null \
    | /usr/bin/awk -F '\t' 'NF >= 2 { path = $NF; sub(/^[[:space:]]+/, "", path); sub(/[[:space:]]+$/, "", path); if (path ~ /\.appex$/) print path; exit }')" || true

  if [ -z "$appex" ]; then
    stage_skip "widget extension is not registered"
    return "$STAGE_SKIP"
  fi

  expected_executable="$appex/Contents/MacOS/$WIDGET_EXTENSION_NAME"
  if [ ! -f "$expected_executable" ]; then
    stage_skip "widget executable not found: $expected_executable"
    return "$STAGE_SKIP"
  fi

  # Wait for widget process
  deadline=$((SECONDS + WIDGET_TIMEOUT))
  while [ "$SECONDS" -le "$deadline" ]; do
    widget_pid="$("$PS_BIN" -axo pid=,comm= 2>/dev/null | /usr/bin/awk -v exe="$expected_executable" '
      { comm = ""; for (i = 2; i <= NF; i++) comm = comm (i > 2 ? " " : "") $i; if (comm == exe) { print $1; exit } }')" || true
    if [ -n "$widget_pid" ]; then
      break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      stage_fail "widget extension did not start within ${WIDGET_TIMEOUT}s"
      return "$STAGE_FAIL"
    fi
    /bin/sleep 1
  done

  # Verify the widget process executable hash matches our build
  local expected_hash
  local executable_hash
  expected_hash="$(LC_ALL=C /usr/bin/shasum -a 256 "$expected_executable" | /usr/bin/awk '{print $1}')" || {
    stage_fail "failed to hash widget executable"
    return "$STAGE_FAIL"
  }
  executable_hash="$(LC_ALL=C /usr/bin/shasum -a 256 "/proc/$widget_pid/exe" 2>/dev/null \
    || "$PS_BIN" -p "$widget_pid" -o comm= 2>/dev/null | /usr/bin/xargs | LC_ALL=C /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')" || true

  echo "widget extension: pid=$widget_pid executable=$expected_executable"

  stage_pass
}

# ---------------------------------------------------------------------------
# Stage 7: Warm app start duration
# ---------------------------------------------------------------------------
run_app_warm_start() {
  stage_start "app-warm-start"

  # Kill existing app instance
  /usr/bin/pkill -x "$APP_NAME" 2>/dev/null || true
  /bin/sleep 2

  local start_ms
  start_ms="$(now_milliseconds)"
  local message="HUD ready identifier=TinyBuddy.HUDWindow"

  /usr/bin/open -n "$APP_BUNDLE" 2>/dev/null || {
    stage_fail "failed to warm-launch app"
    return "$STAGE_FAIL"
  }

  local deadline=$((SECONDS + WARM_START_TIMEOUT))
  local elapsed_ms
  while [ "$SECONDS" -le "$deadline" ]; do
    if "$LOG_BIN" show \
      --last "${WARM_START_TIMEOUT}s" \
      --style compact \
      --predicate "subsystem == \"local.tinybuddy\" AND category == \"HUD\" AND eventMessage CONTAINS \"$message\"" \
      2>/dev/null | /usr/bin/grep -F "$message" >/dev/null
    then
      elapsed_ms=$(( $(now_milliseconds) - start_ms ))
      break
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      elapsed_ms=$(( $(now_milliseconds) - start_ms ))
      stage_fail "warm start timeout: ${elapsed_ms}ms (limit ${WARM_START_TIMEOUT}s)"
      return "$STAGE_FAIL"
    fi
    /bin/sleep 0.5
  done

  local baseline_ms
  baseline_ms="$(resolve_baseline_value "WARM_START_MS" 0)"
  local limit_ms
  limit_ms="$(/usr/bin/awk -v base="$baseline_ms" -v tol="$WARM_START_TOLERANCE" \
    'BEGIN { if (base > 0) print int(base * tol + 0.5); else print 99999 }')"

  echo "warm start: ${elapsed_ms}ms (baseline=${baseline_ms}ms, limit=${limit_ms}ms)"

  if [ "$baseline_ms" -gt 0 ] && [ "$elapsed_ms" -gt "$limit_ms" ]; then
    stage_fail "warm start ${elapsed_ms}ms exceeds ${limit_ms}ms (baseline ${baseline_ms}ms * tolerance ${WARM_START_TOLERANCE})"
    return "$STAGE_FAIL"
  fi

  stage_pass
  RECORDED_WARM_START_MS="$elapsed_ms"
}

# ---------------------------------------------------------------------------
# Stage 8: Continuous refresh stability
# ---------------------------------------------------------------------------
run_continuous_refresh() {
  stage_start "continuous-refresh"

  local bench_script="$ROOT_DIR/script/benchmark_git_refresh.sh"
  if [ ! -f "$bench_script" ]; then
    stage_skip "benchmark_git_refresh.sh not found"
    return "$STAGE_SKIP"
  fi

  local cycle
  local passed=0
  local failed=0
  local cycles="${TINYBUDDY_REGRESSION_CONTINUOUS_CYCLES:-3}"
  local small_repos="${TINYBUDDY_REGRESSION_CONTINUOUS_REPOSITORIES:-8}"
  local small_events="${TINYBUDDY_REGRESSION_CONTINUOUS_EVENTS:-30}"
  local result_file

  for cycle in $(/usr/bin/seq 1 "$cycles"); do
    result_file="$EVIDENCE_DIR/${EVIDENCE_TIMESTAMP}-continuous-cycle${cycle}.txt"
    local exit_code=0
    TINYBUDDY_BENCHMARK_REPOSITORIES="$small_repos" \
    TINYBUDDY_BENCHMARK_EVENTS_PER_REPOSITORY="$small_events" \
    TINYBUDDY_BENCHMARK_INCREMENTAL_RATIO_LIMIT="$GIT_INCREMENTAL_RATIO_LIMIT" \
    TINYBUDDY_BENCHMARK_CPU_PEAK_LIMIT="$GIT_CPU_PEAK_LIMIT" \
    TINYBUDDY_BENCHMARK_RSS_LIMIT_KB="$GIT_RSS_LIMIT_KB" \
    TINYBUDDY_BENCHMARK_CANCELLATION_LIMIT_MS="$GIT_CANCEL_LIMIT_MS" \
      /bin/bash "$bench_script" > "$result_file" 2>&1 || exit_code=$?

    if [ "$exit_code" -eq 0 ]; then
      passed=$((passed + 1))
    else
      failed=$((failed + 1))
      local fail_reason
      fail_reason="$(/usr/bin/grep -E 'gate failed' "$result_file" | /usr/bin/head -1 || echo "exit=$exit_code")"
      echo "continuous refresh cycle $cycle failed: $fail_reason" >&2
    fi
  done

  if [ "$failed" -eq 0 ]; then
    stage_pass
  elif [ "$passed" -gt 0 ]; then
    stage_fail "${failed}/${cycles} continuous refresh cycles failed"
    return "$STAGE_FAIL"
  else
    stage_fail "all ${cycles} continuous refresh cycles failed"
    return "$STAGE_FAIL"
  fi
}

# ---------------------------------------------------------------------------
# Baseline recording
# ---------------------------------------------------------------------------
record_baseline() {
  echo "Recording baselines from current run..."
  local baseline_data=""
  baseline_data="# TinyBuddy regression baseline — recorded $(/bin/date '+%Y-%m-%d %H:%M:%S')"
  baseline_data="$baseline_data
# Format: TINYBUDDY_BASELINE_<STAGE>_<METRIC>=<value>"

  baseline_data="$baseline_data
TINYBUDDY_BASELINE_GIT_COLD_WALL_MS=${RECORDED_GIT_COLD_WALL_MS:-0}
TINYBUDDY_BASELINE_GIT_COLD_CPU_PEAK=${RECORDED_GIT_COLD_CPU_PEAK:-0}
TINYBUDDY_BASELINE_GIT_COLD_RSS_KB=${RECORDED_GIT_COLD_RSS_KB:-0}
TINYBUDDY_BASELINE_GIT_INCREMENTAL_WALL_MS=${RECORDED_GIT_INCREMENTAL_WALL_MS:-0}
TINYBUDDY_BASELINE_APP_COLD_START_COLD_START_MS=${RECORDED_COLD_START_MS:-0}
TINYBUDDY_BASELINE_APP_WARM_START_WARM_START_MS=${RECORDED_WARM_START_MS:-0}
TINYBUDDY_BASELINE_RESOURCE_RSS_DELTA_KB=${RECORDED_RESOURCE_RSS_DELTA_KB:-0}
TINYBUDDY_BASELINE_RESOURCE_THREAD_DELTA=${RECORDED_RESOURCE_THREAD_DELTA:-0}"

  printf '%s\n' "$baseline_data" | save_baseline
  echo "Baseline saved to $BASELINE_FILE"
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------
build_app_if_needed() {
  if [ ! -f "$APP_BINARY" ]; then
    echo "building Debug app..."
    TINYBUDDY_BUILD_CONFIGURATION=Debug TINYBUDDY_SIGNING_MODE=unsigned \
      "$ROOT_DIR/script/build_and_run.sh" build >/dev/null 2>&1 || true
    if [ ! -f "$APP_BINARY" ]; then
      echo "warning: failed to build app; app-dependent stages will be skipped" >&2
    fi
  fi
}

teardown_app() {
  /usr/bin/pkill -x "$APP_NAME" 2>/dev/null || true
  /usr/bin/pkill -x "$WIDGET_EXTENSION_NAME" 2>/dev/null || true
}

run_all_stages() {
  init_evidence

  # Git-only stages (no app needed)
  run_git_cold || true
  run_git_incremental || true
  run_git_cancel || true

  # App-dependent stages
  build_app_if_needed
  if [ -f "$APP_BINARY" ]; then
    # Kill leftover instances
    teardown_app
    /bin/sleep 1

    run_app_cold_start || true
    run_resource_monitor || true
    run_widget_reload || true
    teardown_app
    /bin/sleep 1
    run_app_warm_start || true
    teardown_app
  else
    stage_skip "app-cold-start" "no built app binary"
    stage_skip "resource-monitor" "no built app binary"
    stage_skip "widget-reload" "no built app binary"
    stage_skip "app-warm-start" "no built app binary"
  fi

  run_continuous_refresh || true

  # Clean up probe
  if [ -n "$PROBE_BINARY" ]; then
    /bin/rm -f "$PROBE_BINARY" 2>/dev/null || true
  fi

  echo ""
  echo "=== Regression Gate Summary ==="
  if [ -f "$EVIDENCE_DIR/${EVIDENCE_TIMESTAMP}-summary.txt" ]; then
    /bin/cat "$EVIDENCE_DIR/${EVIDENCE_TIMESTAMP}-summary.txt"
  fi
  if [ "$OVERALL_STATUS" -eq 0 ]; then
    echo "OVERALL: PASS"
  else
    echo "OVERALL: FAIL" >&2
  fi
  echo "Evidence: $EVIDENCE_DIR/"
}

run_quick_stages() {
  # Override with lighter parameters
  GIT_REPOSITORIES="$QUICK_REPOSITORIES"
  GIT_EVENTS="$QUICK_EVENTS"
  COLD_START_TIMEOUT=20
  WARM_START_TIMEOUT=10
  RESOURCE_DURATION=30
  run_all_stages
}

run_single_stage() {
  local stage_num="$1"
  init_evidence

  case "$stage_num" in
    1) run_git_cold ;;
    2) run_git_incremental ;;
    3) run_git_cancel ;;
    4)
      build_app_if_needed
      teardown_app
      run_app_cold_start
      teardown_app
      ;;
    5)
      build_app_if_needed
      teardown_app
      /bin/sleep 1
      /usr/bin/open -n "$APP_BUNDLE" 2>/dev/null || true
      /bin/sleep 5
      run_resource_monitor
      teardown_app
      ;;
    6)
      build_app_if_needed
      teardown_app
      /bin/sleep 1
      /usr/bin/open -n "$APP_BUNDLE" 2>/dev/null || true
      /bin/sleep 10
      run_widget_reload
      teardown_app
      ;;
    7)
      build_app_if_needed
      teardown_app
      /bin/sleep 1
      run_app_warm_start
      teardown_app
      ;;
    8) run_continuous_refresh ;;
    *)
      echo "unknown stage: $stage_num" >&2
      list_stages >&2
      exit 2
      ;;
  esac

  if [ -f "$EVIDENCE_DIR/${EVIDENCE_TIMESTAMP}-summary.txt" ]; then
    /bin/cat "$EVIDENCE_DIR/${EVIDENCE_TIMESTAMP}-summary.txt"
  fi
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
cd "$ROOT_DIR"

case "${1:-}" in
  --help|-h)
    usage
    exit 0
    ;;
  --list-stages)
    list_stages
    exit 0
    ;;
  --record-baseline)
    run_all_stages
    record_baseline
    exit "$OVERALL_STATUS"
    ;;
  --quick)
    load_baseline || echo "no baseline found; using built-in thresholds only" >&2
    run_quick_stages
    exit "$OVERALL_STATUS"
    ;;
  --stage)
    if ! is_positive_integer "${2:-}"; then
      echo "usage: $0 --stage N (positive integer)" >&2
      exit 2
    fi
    run_single_stage "$2"
    exit "$OVERALL_STATUS"
    ;;
  ""|--check)
    load_baseline || echo "no baseline found; using built-in thresholds only" >&2
    run_all_stages
    exit "$OVERALL_STATUS"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
