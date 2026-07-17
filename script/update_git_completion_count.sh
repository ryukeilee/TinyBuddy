#!/usr/bin/env bash
set -Eeuo pipefail

LC_ALL=C
export LC_ALL

APP_GROUP_ID="group.com.ryukeili.TinyBuddy"
USER_HOME="${TINYBUDDY_USER_HOME:-$HOME}"
APP_GROUP_CONTAINER="${TINYBUDDY_APP_GROUP_CONTAINER:-$USER_HOME/Library/Group Containers/$APP_GROUP_ID}"
APP_GROUP_PREFERENCES_DIR="${TINYBUDDY_APP_GROUP_PREFERENCES_DIR:-$APP_GROUP_CONTAINER/Library/Preferences}"
APP_GROUP_PREFERENCES_PLIST="${TINYBUDDY_APP_GROUP_PREFERENCES_PLIST:-$APP_GROUP_PREFERENCES_DIR/$APP_GROUP_ID.plist}"
DAY_KEY="tinybuddy.gitTodayCommitCount.dayIdentifier"
COUNT_KEY="tinybuddy.gitTodayCommitCount.count"
FOCUS_BLOCK_DAY_KEY="tinybuddy.gitTodayFocusBlockCount.dayIdentifier"
FOCUS_BLOCK_COUNT_KEY="tinybuddy.gitTodayFocusBlockCount.count"
RECENT_PROJECT_DAY_KEY="tinybuddy.gitTodayRecentProject.dayIdentifier"
RECENT_PROJECT_NAME_KEY="tinybuddy.gitTodayRecentProject.projectName"
TRUSTED_SNAPSHOT_KEY="tinybuddy.gitTodayActivity.trustedSnapshot"
SCAN_ROOTS="${TINYBUDDY_GIT_SCAN_ROOTS:-${TINYBUDDY_GIT_SCAN_ROOT:-}}"
TODAY="${TINYBUDDY_TODAY:-$(/bin/date +%F)}"
TIME_SCOPE_IDENTIFIER="${TINYBUDDY_TIME_SCOPE_IDENTIFIER:-${TZ:-system-default}}"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:${PATH:-}"
# Signed-runtime dependency boundary: Bash 3.2 plus date, find, stat, mktemp,
# awk, sed, sort, cmp, cp, mv, rm, mkdir, rmdir, test, sleep, tr, paste, basename,
# base64, cksum, defaults, plutil, PlistBuddy, git, and optional perl. The
# script also requires its inherited temporary directory, authorized scan
# roots, and the app-group preferences container.
FIND_BIN="${TINYBUDDY_FIND_BIN:-find}"
STAT_BIN="${TINYBUDDY_STAT_BIN:-stat}"
GIT_BIN="${TINYBUDDY_GIT_BIN:-git}"
PERL_BIN="${TINYBUDDY_PERL_BIN:-}"
DUPLICATE_EVENT_WINDOW_SECONDS="${TINYBUDDY_DUPLICATE_EVENT_WINDOW_SECONDS:-120}"
REPOSITORY_CACHE_MAX_AGE_SECONDS="${TINYBUDDY_GIT_REPOSITORY_CACHE_MAX_AGE_SECONDS:-300}"
SCAN_ROOT_TIMEOUT_SECONDS="${TINYBUDDY_GIT_SCAN_ROOT_TIMEOUT_SECONDS:-15}"
REPOSITORY_READ_TIMEOUT_SECONDS="${TINYBUDDY_GIT_REPOSITORY_READ_TIMEOUT_SECONDS:-5}"
REPOSITORY_PARSE_TIMEOUT_SECONDS="${TINYBUDDY_GIT_REPOSITORY_PARSE_TIMEOUT_SECONDS:-30}"
SNAPSHOT_WRITE_LOCK_TIMEOUT_SECONDS="${TINYBUDDY_SNAPSHOT_WRITE_LOCK_TIMEOUT_SECONDS:-120}"
CACHE_DIR="${TINYBUDDY_GIT_REPOSITORY_CACHE_DIR:-$APP_GROUP_PREFERENCES_DIR/.tinybuddy-git-repository-cache}"
CACHE_REPO_LIST_FILE="$CACHE_DIR/repositories.txt"
CACHE_REPO_STATS_FILE="$CACHE_DIR/repository-stats.tsv"
CACHE_REPO_STATS_CHECKSUM_FILE="$CACHE_DIR/repository-stats.cksum"
CACHE_SCAN_ROOTS_FILE="$CACHE_DIR/authorized-roots.txt"
CACHE_SCAN_ROOTS_SIGNATURE_FILE="$CACHE_DIR/authorized-roots.signature"
EMPTY_CACHE_VALUE="__TINYBUDDY_EMPTY__"
MISSING_PLIST_VALUE="__TINYBUDDY_MISSING_PLIST_VALUE__"

normalize_nonnegative_int64() {
  local value="$1"

  case "$value" in
    ""|*[!0-9]*)
      return 1
      ;;
  esac

  while [ "${#value}" -gt 1 ] && [ "${value#0}" != "$value" ]; do
    value="${value#0}"
  done

  if [ "${#value}" -gt 19 ] ||
     { [ "${#value}" -eq 19 ] && [[ "$value" > "9223372036854775807" ]]; }; then
    return 1
  fi

  printf '%s\n' "$value"
}

if [ -n "${TINYBUDDY_REFRESH_EPOCH:-}" ]; then
  if ! REFRESH_EPOCH="$(normalize_nonnegative_int64 "$TINYBUDDY_REFRESH_EPOCH")"; then
    echo "TinyBuddy refresh script: explicit refresh epoch is invalid" >&2
    exit 64
  fi
else
  REFRESH_EPOCH="$(/bin/date +%s)"
fi

if [ -n "${TINYBUDDY_REFRESH_REVISION:-}" ]; then
  if ! REFRESH_REVISION="$(normalize_nonnegative_int64 "$TINYBUDDY_REFRESH_REVISION")"; then
    echo "TinyBuddy refresh script: explicit refresh revision is invalid" >&2
    exit 64
  fi
  REFRESH_REVISION_IS_EXPLICIT=1
else
  REFRESH_REVISION="$REFRESH_EPOCH"
  REFRESH_REVISION_IS_EXPLICIT=0
fi
SNAPSHOT_WRITE_LOCK="$APP_GROUP_PREFERENCES_DIR/.tinybuddy-git-snapshot-write.lock"
SNAPSHOT_WRITE_LOCK_OWNER="$SNAPSHOT_WRITE_LOCK/owner-$$"

total_count=0
latest_activity_timestamp=""
recent_project_name=""
readable_reflog_repo_count=0
successful_reflog_repo_count=0
failed_reflog_repo_count=0
scan_roots_file="$(mktemp)"
valid_scan_roots_file=""
repo_list_file="$(mktemp)"
repo_scan_file="$(mktemp)"
repo_reflog_file="$(mktemp)"
repo_git_paths_file="$(mktemp)"
repo_stats_cache_file="$(mktemp)"
new_repo_stats_file="$(mktemp)"
validated_repo_list_file="$(mktemp)"
repository_identity_file="$(mktemp)"
repository_records_file="$(mktemp)"
unique_repository_records_file="$(mktemp)"
raw_activity_events_file="$(mktemp)"
normalized_activity_events_file="$(mktemp)"
repo_activity_events_file="$(mktemp)"
rewrite_log_file="$(mktemp)"
rewrite_candidates_file="$(mktemp)"
find_stderr_file="$(mktemp)"
focus_block_list_file="$(mktemp)"
diagnostics_emitted=0
shared_data_rewritten=0
repository_count=0
cache_hit_count=0
reflog_unchanged_skip_count=0
recomputed_repository_count=0
retained_repository_count=0
repository_scan_failed=0
repository_scan_failure_count=0
invalid_repository_count=0
recovery_has_missing_reflog=0
snapshot_write_lock_acquired=0
trusted_snapshot_stale=0
refresh_outcome_override=""
future_reflog_event_detected=0

record_invalid_repository() {
  local diagnostic="$1"
  local candidate_fingerprint
  local candidate_id
  invalid_repository_count=$((invalid_repository_count + 1))
  if candidate_fingerprint="$(printf '%s' "$current_repository_candidate" | /usr/bin/cksum)"; then
    candidate_fingerprint="${candidate_fingerprint%% *}"
  else
    candidate_fingerprint="unavailable"
  fi
  candidate_id="repo-$candidate_fingerprint"
  log_error "invalid repository candidate #$invalid_repository_count candidate=$candidate_id diagnostic=$diagnostic"
}

log_error() {
  echo "TinyBuddy refresh script: $*" >&2
}

run_command_with_timeout() {
  local timeout_seconds="$1"
  shift
  local command_pid
  local command_status=0
  local poll_count=0
  local poll_limit=$((timeout_seconds * 100))

  "$@" &
  command_pid=$!

  while kill -0 "$command_pid" 2>/dev/null; do
    if [ "$poll_count" -ge "$poll_limit" ]; then
      kill -TERM "$command_pid" 2>/dev/null || true
      sleep 0.1
      kill -KILL "$command_pid" 2>/dev/null || true
      wait "$command_pid" 2>/dev/null || true
      return 124
    fi
    poll_count=$((poll_count + 1))
    sleep 0.01
  done

  wait "$command_pid" || command_status=$?
  return "$command_status"
}

cleanup() {
  if [ "$snapshot_write_lock_acquired" -eq 1 ]; then
    rmdir "$SNAPSHOT_WRITE_LOCK_OWNER" 2>/dev/null || true
    rmdir "$SNAPSHOT_WRITE_LOCK" 2>/dev/null || true
  fi
  rm -f "$scan_roots_file" "$valid_scan_roots_file" "$repo_list_file" "$repo_scan_file" "$repo_reflog_file" "$repo_git_paths_file" "$repo_stats_cache_file" "$new_repo_stats_file" "$validated_repo_list_file" "$repository_identity_file" "$repository_records_file" "$unique_repository_records_file" "$raw_activity_events_file" "$normalized_activity_events_file" "$repo_activity_events_file" "$rewrite_log_file" "$rewrite_candidates_file" "$find_stderr_file" "$focus_block_list_file"
}

emit_runtime_diagnostics_once() {
  if [ "$diagnostics_emitted" -eq 1 ]; then
    return
  fi

  diagnostics_emitted=1

  local git_available="no"
  local home_configured="no"
  local scan_roots_count
  command -v git >/dev/null 2>&1 && git_available="yes"
  [ -n "${HOME:-}" ] && home_configured="yes"
  scan_roots_count="$(awk 'END { print NR + 0 }' "$scan_roots_file")"
  log_error "diagnostics: script=${0##*/} paths_redacted=yes home_configured=$home_configured scan_roots_count=$scan_roots_count git_available=$git_available app_group_plist_configured=yes"
}

emit_find_stderr_sample() {
  if [ ! -s "$find_stderr_file" ]; then
    return
  fi

  local line_count
  line_count="$(awk 'END { print NR + 0 }' "$find_stderr_file")"
  log_error "find stderr present: line_count=$line_count contents=redacted"
}

normalized_scan_root_path() {
  local path="$1"
  local resolved_path="$path"

  if run_command_with_timeout "$SCAN_ROOT_TIMEOUT_SECONDS" /bin/test -d "$path"; then
    resolved_path="$(cd "$path" 2>/dev/null && pwd -P)" || resolved_path="$path"
  fi

  while [ "${#resolved_path}" -gt 1 ] && [[ "$resolved_path" == */ ]]; do
    resolved_path="${resolved_path%/}"
  done

  printf '%s\n' "$resolved_path"
}

path_contains_noise_component() {
  local candidate_path
  candidate_path="$(normalized_scan_root_path "$1" | tr '[:upper:]' '[:lower:]')"

  case "$candidate_path" in
    */.build|*/.build/*|\
    */.cache|*/.cache/*|\
    */.gradle|*/.gradle/*|\
    */.next|*/.next/*|\
    */.pnpm-store|*/.pnpm-store/*|\
    */.swiftpm|*/.swiftpm/*|\
    */.terraform|*/.terraform/*|\
    */.tmp|*/.tmp/*|\
    */.turbo|*/.turbo/*|\
    */.venv|*/.venv/*|\
    */__fixtures__|*/__fixtures__/*|\
    */bower_components|*/bower_components/*|\
    */build|*/build/*|\
    */caches|*/caches/*|\
    */carthage|*/carthage/*|\
    */coverage|*/coverage/*|\
    */deriveddata|*/deriveddata/*|\
    */deps|*/deps/*|\
    */dist|*/dist/*|\
    */fixtures|*/fixtures/*|\
    */node_modules|*/node_modules/*|\
    */pods|*/pods/*|\
    */target|*/target/*|\
    */temp|*/temp/*|\
    */testdata|*/testdata/*|\
    */third_party|*/third_party/*|\
    */tmp|*/tmp/*|\
    */vendor|*/vendor/*)
      return 0
      ;;
  esac

  return 1
}

path_is_within_root() {
  local candidate_path
  local root_path
  candidate_path="$(normalized_scan_root_path "$1")"
  root_path="$(normalized_scan_root_path "$2")"

  [ "$candidate_path" = "$root_path" ] || [[ "$candidate_path" == "$root_path/"* ]]
}

path_is_within_authorized_roots() {
  local candidate_path="$1"
  local authorized_root

  while IFS= read -r authorized_root; do
    if path_is_within_root "$candidate_path" "$authorized_root"; then
      return 0
    fi
  done < "$scan_roots_file"

  return 1
}

is_broad_scan_root() {
  local path
  path="$(normalized_scan_root_path "$1")"

  [ "$path" = "/" ] || [ "$path" = "/Users" ] || [ "$path" = "$USER_HOME" ]
}

resolve_existing_directory_path() {
  local directory_path="$1"
  (
    trap - ERR
    cd "$directory_path" 2>/dev/null && pwd -P
  )
}

resolve_git_dir() {
  local repo_root="$1"
  local dot_git_path="$repo_root/.git"
  local gitdir_line
  local git_dir

  if [ -d "$dot_git_path" ]; then
    resolve_existing_directory_path "$dot_git_path"
    return
  fi

  if [ ! -f "$dot_git_path" ]; then
    return 1
  fi

  gitdir_line="$(sed -n '1p' "$dot_git_path")"
  case "$gitdir_line" in
    gitdir:\ *)
      git_dir="${gitdir_line#gitdir: }"
      ;;
    *)
      return 1
      ;;
  esac

  if [[ "$git_dir" != /* ]]; then
    git_dir="$repo_root/$git_dir"
  fi

  resolve_existing_directory_path "$git_dir"
}

resolve_git_metadata_dir() {
  local base_path="$1"
  local target_path="$2"

  if [[ "$target_path" != /* ]]; then
    target_path="$base_path/$target_path"
  fi

  resolve_existing_directory_path "$target_path"
}

repository_candidate_is_allowed() {
  local repo_root="$1"

  if path_contains_noise_component "$repo_root"; then
    return 1
  fi

  return 0
}

validate_git_metadata_layout() {
  local git_dir="$1"
  local common_dir_path_file="$git_dir/commondir"
  local git_head_path="$git_dir/HEAD"
  local common_dir_path
  local common_dir

  if [ ! -f "$git_head_path" ] || [ ! -r "$git_head_path" ]; then
    return 1
  fi

  if [ ! -f "$common_dir_path_file" ]; then
    return 0
  fi

  common_dir_path="$(sed -n '1p' "$common_dir_path_file")"
  if [ -z "$common_dir_path" ]; then
    return 1
  fi

  trap - ERR
  if common_dir="$(resolve_git_metadata_dir "$git_dir" "$common_dir_path")"; then
    resolve_common_dir_exit_code=0
  else
    resolve_common_dir_exit_code="$?"
  fi
  enable_error_trap
  if [ "$resolve_common_dir_exit_code" -ne 0 ]; then
    return 1
  fi

  if ! path_is_within_authorized_roots "$common_dir"; then
    return 1
  fi

  [ -d "$common_dir" ]
}

resolve_common_git_dir() {
  local git_dir="$1"
  local common_dir_path_file="$git_dir/commondir"
  local common_dir_path

  if [ ! -f "$common_dir_path_file" ]; then
    printf '%s\n' "$git_dir"
    return
  fi

  common_dir_path="$(sed -n '1p' "$common_dir_path_file")"
  [ -n "$common_dir_path" ] || return 1
  resolve_git_metadata_dir "$git_dir" "$common_dir_path"
}

repository_display_name() {
  local repo_root="$1"
  local common_dir="$2"
  local common_basename

  common_basename="$(basename "$common_dir")"
  if [ "$common_basename" = ".git" ]; then
    basename "${common_dir%/.git}"
  else
    basename "$repo_root"
  fi
}

record_field_is_supported() {
  case "$1" in
    *$'\t'*|*$'\n'*|*$'\r'*)
      return 1
      ;;
  esac
}

identity_looks_automated() {
  local normalized_identity
  normalized_identity="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"

  case "$normalized_identity" in
    *'[bot]'*|*dependabot*|*renovate-bot*|*renovate\ bot*|*github-actions*|*copilot-swe-agent*|*automation@*|*bot@*|*' bot <'*|*' robot <'*)
      return 0
      ;;
  esac

  return 1
}

git_commit_is_automated() {
  local git_dir="$1"
  local object_id="$2"
  local commit_identity
  local git_identity_exit_code

  case "$object_id" in
    ""|*[!0-9a-fA-F]*)
      return 1
      ;;
  esac
  [ "${#object_id}" -eq 40 ] || [ "${#object_id}" -eq 64 ] || return 1

  trap - ERR
  if commit_identity="$(
      GIT_CONFIG_NOSYSTEM=1 \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_OPTIONAL_LOCKS=0 \
      GIT_NO_LAZY_FETCH=1 \
      "$GIT_BIN" --git-dir="$git_dir" show -s --format='%an <%ae> %cn <%ce>' "$object_id" 2>/dev/null
    )"; then
    git_identity_exit_code=0
  else
    git_identity_exit_code="$?"
  fi
  enable_error_trap
  [ "$git_identity_exit_code" -eq 0 ] || return 1

  identity_looks_automated "$commit_identity"
}

parse_reflog_events() {
  local reflog_path="$1"
  local metadata
  local message
  local kind
  local old_object_id
  local new_object_id
  local epoch
  local actor_is_automated
  local parse_deadline=$((SECONDS + REPOSITORY_PARSE_TIMEOUT_SECONDS))

  : > "$repo_reflog_file"

  if [ -n "$PERL_BIN" ]; then
    run_command_with_timeout "$REPOSITORY_PARSE_TIMEOUT_SECONDS" "$PERL_BIN" -e '
      use strict;
      use warnings;

      while (my $line = <>) {
          chomp $line;
          my ($metadata, $message) = split /\t/, $line, 2;
          next unless defined $message;

          my $kind;
          if ($message =~ /^commit \(amend\):/) {
              $kind = "amend";
          } elsif ($message =~ /^commit(?: \(.+\))?:/) {
              $kind = "commit";
          } elsif ($message =~ /^merge(?:\s+[^:]*)?:/) {
              $kind = "merge";
          } elsif ($message =~ /^rebase \(start\):/) {
              $kind = "rewriteStart";
          } elsif ($message =~ /^rebase \((?:pick|reword|edit|squash|fixup)\):/) {
              $kind = "rewrite";
          } elsif ($message =~ /^rebase \(finish\):/) {
              $kind = "rewriteFinish";
          } else {
              next;
          }

          my @parts = split / /, $metadata;
          next if @parts < 4;
          my ($old_object_id, $new_object_id) = @parts[0, 1];
          my $epoch = $parts[-2];
          next unless $old_object_id =~ /^[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?$/;
          next unless $new_object_id =~ /^[0-9a-fA-F]{40}(?:[0-9a-fA-F]{24})?$/;
          next unless $epoch =~ /^\d+$/;

          my $identity = lc $metadata;
          my $actor_is_automated = $identity =~ /\[bot\]|dependabot|renovate-bot|renovate bot|github-actions|copilot-swe-agent|automation\@|bot\@| bot <| robot </ ? 1 : 0;
          $message =~ s/[\t\r\n]+/ /g;
          print join("\t", $kind, $old_object_id, $new_object_id, $epoch, $actor_is_automated, $message), "\n";
      }
    ' "$reflog_path" > "$repo_reflog_file"
    return
  fi

  while IFS=$'\t' read -r metadata message || [ -n "${metadata:-}" ]; do
    [ "$SECONDS" -lt "$parse_deadline" ] || return 124
    case "$message" in
      "commit (amend):"*)
        kind="amend"
        ;;
      commit:*|"commit ("*"):"*)
        kind="commit"
        ;;
      merge:*|"merge "*":"*)
        kind="merge"
        ;;
      "rebase (start):"*)
        kind="rewriteStart"
        ;;
      "rebase (pick):"*|"rebase (reword):"*|"rebase (edit):"*|"rebase (squash):"*|"rebase (fixup):"*)
        kind="rewrite"
        ;;
      "rebase (finish):"*)
        kind="rewriteFinish"
        ;;
      *)
        continue
        ;;
    esac

    set -f
    metadata_parts=($metadata)
    set +f
    [ "${#metadata_parts[@]}" -ge 4 ] || continue
    old_object_id="${metadata_parts[0]}"
    new_object_id="${metadata_parts[1]}"
    epoch="${metadata_parts[${#metadata_parts[@]} - 2]}"
    case "$old_object_id$new_object_id" in
      *[!0-9a-fA-F]*)
        continue
        ;;
    esac
    { [ "${#old_object_id}" -eq 40 ] || [ "${#old_object_id}" -eq 64 ]; } || continue
    { [ "${#new_object_id}" -eq 40 ] || [ "${#new_object_id}" -eq 64 ]; } || continue
    case "$epoch" in
      ""|*[!0-9]*)
        continue
        ;;
    esac

    actor_is_automated=0
    identity_looks_automated "$metadata" && actor_is_automated=1
    message="$(printf '%s' "$message" | tr '\t\r\n' '   ')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$kind" "$old_object_id" "$new_object_id" "$epoch" "$actor_is_automated" "$message" >> "$repo_reflog_file"
  done < "$reflog_path"
}

# Activity semantics are intentionally event based rather than reachability
# based. A completed commit remains activity after a branch deletion, reset, or
# rebase. Amend replaces the earlier logical event, while rebase/reset/checkout
# records never create another completion. Events are later grouped by the
# canonical common Git directory, filtered for automated identities, and
# deduplicated by object identity inside the bounded observation window.
append_reflog_events_for_today() {
  local repository_identity="$1"
  local display_name="$2"
  local git_dir="$3"
  local kind
  local old_object_id
  local new_object_id
  local epoch
  local actor_is_automated
  local message
  local day_identifier
  local local_hour
  local local_minute
  local block_minute
  local focus_block
  local message_fingerprint
  local activity_subject
  local object_is_automated
  local parse_deadline=$((SECONDS + REPOSITORY_PARSE_TIMEOUT_SECONDS))

  : > "$repo_activity_events_file"
  parse_reflog_events "$4" || return 1

  while IFS=$'\t' read -r kind old_object_id new_object_id epoch actor_is_automated message; do
    [ "$SECONDS" -lt "$parse_deadline" ] || return 124
    if ! epoch="$(normalize_nonnegative_int64 "$epoch")"; then
      continue
    fi
    if [ "$epoch" -gt "$REFRESH_EPOCH" ]; then
      future_reflog_event_detected=1
      continue
    fi
    day_identifier="$(/bin/date -r "$epoch" +%Y-%m-%d 2>/dev/null)" || continue
    [ "$day_identifier" = "$TODAY" ] || continue
    local_hour="$(/bin/date -r "$epoch" +%H 2>/dev/null)" || continue
    local_minute="$(/bin/date -r "$epoch" +%M 2>/dev/null)" || continue
    block_minute=0
    [ "$local_minute" -ge 30 ] && block_minute=30
    focus_block=$((epoch / 1800))
    activity_subject="${message#*: }"
    message_fingerprint="$(printf '%s' "$activity_subject" | /usr/bin/cksum)"
    message_fingerprint="${message_fingerprint%% *}"

    object_is_automated=0
    git_commit_is_automated "$git_dir" "$new_object_id" && object_is_automated=1
    if [ "$actor_is_automated" -eq 1 ] || [ "$object_is_automated" -eq 1 ]; then
      actor_is_automated=1
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$epoch" "$old_object_id" "$new_object_id" "$kind" "$message_fingerprint" "$focus_block" "$actor_is_automated" >> "$repo_activity_events_file"

  done < "$repo_reflog_file"
}

build_rewrite_candidates() {
  local git_dir="$1"
  local old_object_id="$2"
  local new_object_id="$3"
  local git_log_exit_code
  local candidate_object_id
  local candidate_subject
  local candidate_fingerprint

  : > "$rewrite_log_file"
  : > "$rewrite_candidates_file"
  trap - ERR
  if run_command_with_timeout "$REPOSITORY_PARSE_TIMEOUT_SECONDS" env \
     GIT_CONFIG_NOSYSTEM=1 \
     GIT_CONFIG_GLOBAL=/dev/null \
     GIT_OPTIONAL_LOCKS=0 \
     "$GIT_BIN" --git-dir="$git_dir" log --reverse --format='%H%x09%s' \
       "$new_object_id..$old_object_id" > "$rewrite_log_file" 2>/dev/null; then
    git_log_exit_code=0
  else
    git_log_exit_code="$?"
  fi
  enable_error_trap
  [ "$git_log_exit_code" -eq 0 ] || return 1

  while IFS=$'\t' read -r candidate_object_id candidate_subject || [ -n "${candidate_object_id:-}" ]; do
    case "$candidate_object_id" in
      ""|*[!0-9a-fA-F]*)
        continue
        ;;
    esac
    { [ "${#candidate_object_id}" -eq 40 ] || [ "${#candidate_object_id}" -eq 64 ]; } || continue
    candidate_subject="$(printf '%s' "$candidate_subject" | tr '\t\r\n' '   ')"
    candidate_fingerprint="$(printf '%s' "$candidate_subject" | /usr/bin/cksum)"
    candidate_fingerprint="${candidate_fingerprint%% *}"
    printf '%s\t%s\n' "$candidate_object_id" "$candidate_fingerprint" >> "$rewrite_candidates_file"
  done < "$rewrite_log_file"
}

append_repo_activity_events_to_raw() {
  local repository_identity="$1"
  local display_name="$2"
  local reflog_path="$3"
  local git_dir="$4"
  local epoch
  local old_object_id
  local new_object_id
  local kind
  local message_fingerprint
  local focus_block
  local actor_is_automated
  local rewrite_candidate_index=0
  local rewrite_candidate_line
  local rewrite_match_line
  local rewrite_match_index
  local rewrite_original_oid

  : > "$rewrite_candidates_file"
  while IFS=$'\t' read -r epoch old_object_id new_object_id kind message_fingerprint focus_block actor_is_automated; do
    rewrite_original_oid="$EMPTY_CACHE_VALUE"
    if [ "$kind" = "rewriteStart" ]; then
      rewrite_candidate_index=0
      build_rewrite_candidates "$git_dir" "$old_object_id" "$new_object_id" || : > "$rewrite_candidates_file"
    elif [ "$kind" = "rewrite" ]; then
      rewrite_candidate_index=$((rewrite_candidate_index + 1))
      rewrite_candidate_line="$(sed -n "${rewrite_candidate_index}p" "$rewrite_candidates_file")"
      if [ -n "$rewrite_candidate_line" ]; then
        rewrite_original_oid="${rewrite_candidate_line%%$'\t'*}"
        rewrite_match_line="$(awk -F '\t' \
          -v first="$rewrite_candidate_index" \
          -v fingerprint="$message_fingerprint" \
          'NR >= first && $2 == fingerprint { print NR "\t" $1; exit }' \
          "$rewrite_candidates_file")"
        if [ -n "$rewrite_match_line" ]; then
          rewrite_match_index="${rewrite_match_line%%$'\t'*}"
          rewrite_original_oid="${rewrite_match_line#*$'\t'}"
          rewrite_candidate_index="$rewrite_match_index"
        fi
      fi
    fi

    activity_event_sequence=$((activity_event_sequence + 1))
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$repository_identity" "$display_name" "$reflog_path" "$epoch" "$old_object_id" "$new_object_id" "$kind" "$message_fingerprint" "$focus_block" "$actor_is_automated" "$activity_event_sequence" "$rewrite_original_oid" >> "$raw_activity_events_file"
  done < "$repo_activity_events_file"
}

normalize_activity_events() {
  : > "$normalized_activity_events_file"
  [ -s "$raw_activity_events_file" ] || return 0

  LC_ALL=C sort -t $'\t' -k1,1 -k4,4n -k11,11n "$raw_activity_events_file" > "$repo_reflog_file"
  awk -F '\t' -v window="$DUPLICATE_EVENT_WINDOW_SECONDS" -v empty="$EMPTY_CACHE_VALUE" '
    function deactivate(event_index, key) {
      live[event_index] = 0
      if ((key in active) && active[key] == event_index) {
        delete active[key]
      }
    }

    $10 != 0 && $7 != "rewriteStart" && $7 != "rewrite" && $7 != "rewriteFinish" { next }

    {
      identity = $1
      source = $3
      epoch = $4 + 0
      old_key = identity SUBSEP $5
      new_key = identity SUBSEP $6
      source_key = identity SUBSEP source
      duplicate_key = identity SUBSEP $5 SUBSEP $6 SUBSEP $7 SUBSEP $8

      if ($7 == "rewriteStart") {
        rewrite_generation[source_key]++
        rewrite_active[source_key] = 1
        next
      }

      if ($7 == "rewriteFinish") {
        rewrite_active[source_key] = 0
        next
      }

      if ($7 == "rewrite") {
        if ((source_key in rewrite_active) && rewrite_active[source_key] == 0) {
          next
        }
        if (!(source_key in rewrite_generation) || rewrite_generation[source_key] < 1) {
          rewrite_generation[source_key] = 1
          rewrite_active[source_key] = 1
        }
        current_generation = source_key SUBSEP rewrite_generation[source_key]
        rewritten_index = 0
        if ($12 != empty) {
          original_object_key = identity SUBSEP $12
          if ((original_object_key in active) && live[active[original_object_key]]) {
            rewritten_index = active[original_object_key]
          }
        } else {
          for (source_pass = 1; source_pass <= 2 && rewritten_index == 0; source_pass++) {
            for (candidate_index = 1; candidate_index <= count; candidate_index++) {
              if (live[candidate_index] &&
                  event_identity[candidate_index] == identity &&
                  (source_pass == 2 || event_source[candidate_index] == source) &&
                  event_subject[candidate_index] == $8 &&
                  active[identity SUBSEP event_oid[candidate_index]] == candidate_index &&
                  event_rewrite_generation[candidate_index] != current_generation) {
                rewritten_index = candidate_index
                break
              }
            }
          }
        }
        if (rewritten_index != 0) {
          previous_object_key = identity SUBSEP event_oid[rewritten_index]
          if ((previous_object_key in active) && active[previous_object_key] == rewritten_index) {
            delete active[previous_object_key]
          }
          event_oid[rewritten_index] = $6
          event_rewrite_generation[rewritten_index] = current_generation
          active[new_key] = rewritten_index
        }
        next
      }

      if ((new_key in object_epoch) && epoch >= object_epoch[new_key] && epoch - object_epoch[new_key] <= window) {
        next
      }
      if ((duplicate_key in duplicate_epoch) && epoch >= duplicate_epoch[duplicate_key] && epoch - duplicate_epoch[duplicate_key] <= window) {
        next
      }
      object_epoch[new_key] = epoch
      duplicate_epoch[duplicate_key] = epoch

      if ($7 == "amend" && (old_key in active)) {
        previous_index = active[old_key]
        deactivate(previous_index, old_key)
      }

      count++
      event_identity[count] = identity
      event_display[count] = $2
      event_source[count] = source
      event_epoch[count] = epoch
      event_oid[count] = $6
      event_kind[count] = $7
      event_block[count] = $9
      event_subject[count] = $8
      live[count] = 1
      active[new_key] = count
    }

    END {
      for (event_index = 1; event_index <= count; event_index++) {
        if (live[event_index]) {
          printf "%s\t%s\t%d\t%s\t%s\t%s\n", event_identity[event_index], event_display[event_index], event_epoch[event_index], event_oid[event_index], event_kind[event_index], event_block[event_index]
        }
      }
    }
  ' "$repo_reflog_file" > "$normalized_activity_events_file"
}

reset_activity_snapshot() {
  total_count=0
  latest_activity_timestamp=""
  recent_project_name=""
  readable_reflog_repo_count=0
  successful_reflog_repo_count=0
  failed_reflog_repo_count=0
  repository_count=0
  cache_hit_count=0
  reflog_unchanged_skip_count=0
  recomputed_repository_count=0
  retained_repository_count=0
  invalid_repository_count="$repository_scan_failure_count"
  recovery_has_missing_reflog=0
  activity_event_sequence=0
  : > "$focus_block_list_file"
  : > "$new_repo_stats_file"
  : > "$validated_repo_list_file"
  : > "$repository_identity_file"
  : > "$repository_records_file"
  : > "$unique_repository_records_file"
  : > "$raw_activity_events_file"
  : > "$normalized_activity_events_file"
}

emit_refresh_metrics() {
  local authorized_root_count
  authorized_root_count="$(awk 'END { print NR + 0 }' "$scan_roots_file")"

  local refresh_outcome="${refresh_outcome_override:-success}"
  if [ -z "$refresh_outcome_override" ] && [ "$invalid_repository_count" -gt 0 ]; then
    refresh_outcome="partial"
  fi

  printf 'TINYBUDDY_REFRESH_METRICS\tauthorized_root_count=%s\trepository_count=%s\tinvalid_repository_count=%s\trefresh_outcome=%s\tcache_hit_count=%s\treflog_unchanged_skip_count=%s\trecomputed_repository_count=%s\tretained_repository_count=%s\tshared_data_written=%s\n' \
    "$authorized_root_count" \
    "$repository_count" \
    "$invalid_repository_count" \
    "$refresh_outcome" \
    "$cache_hit_count" \
    "$reflog_unchanged_skip_count" \
    "$recomputed_repository_count" \
    "$retained_repository_count" \
    "$shared_data_rewritten"
}

build_scan_root_signature() {
  local signature_file="$1"
  local scan_root
  local root_signature
  local root_entries_file

  : > "$signature_file"

  while IFS= read -r scan_root; do
    if ! run_command_with_timeout "$SCAN_ROOT_TIMEOUT_SECONDS" /bin/test -d "$scan_root"; then
      printf 'ROOT\t%s\tmissing\n' "$scan_root" >> "$signature_file"
      continue
    fi

    if ! root_signature="$(run_command_with_timeout "$SCAN_ROOT_TIMEOUT_SECONDS" \
      "$STAT_BIN" -f 'ROOT\t%N\t%z\t%m\t%i' "$scan_root")"; then
      printf 'ROOT\t%s\ttimeout-or-error\n' "$scan_root" >> "$signature_file"
      continue
    fi
    printf '%s\n' "$root_signature" >> "$signature_file"
    root_entries_file="$(mktemp)"
    if run_command_with_timeout "$SCAN_ROOT_TIMEOUT_SECONDS" \
      "$FIND_BIN" "$scan_root" -mindepth 1 -maxdepth 1 \
      -exec "$STAT_BIN" -f 'ENTRY\t%N\t%z\t%m\t%i' {} \; \
      > "$root_entries_file" 2>> "$find_stderr_file"; then
      LC_ALL=C sort "$root_entries_file" >> "$signature_file"
    else
      printf 'ENTRIES\t%s\ttimeout-or-error\n' "$scan_root" >> "$signature_file"
    fi
    rm -f "$root_entries_file"
  done < "$scan_roots_file"
}

refresh_repository_list_from_scan() {
  local find_exit_code=0
  local scan_root

  : > "$repo_git_paths_file"
  : > "$repo_scan_file"

  while IFS= read -r scan_root; do
    if ! run_command_with_timeout "$SCAN_ROOT_TIMEOUT_SECONDS" /bin/test -d "$scan_root"; then
      log_error "authorized git scan root is not a readable directory; skipping one root"
      repository_scan_failed=1
      repository_scan_failure_count=$((repository_scan_failure_count + 1))
      continue
    fi

    run_command_with_timeout "$SCAN_ROOT_TIMEOUT_SECONDS" "$FIND_BIN" "$scan_root" \
      \( \
        -path "$USER_HOME/Library" -o \
        -path "$USER_HOME/.Trash" -o \
        -path "$USER_HOME/.cache" -o \
        -path "$USER_HOME/Movies" -o \
        -path "$USER_HOME/Music" -o \
        -path "$USER_HOME/Pictures" -o \
        -path '*/node_modules' -o \
        -path '*/.build' -o \
        -path '*/DerivedData' \
      \) -prune -o \
      -type d -name .git -print0 -prune -o \
      -type f -name .git -print0 >> "$repo_git_paths_file" 2>> "$find_stderr_file" || find_exit_code="$?"
  done < "$scan_roots_file"

  while IFS= read -r -d '' git_path; do
    printf '%s\n' "${git_path%/.git}"
  done < "$repo_git_paths_file" > "$repo_scan_file"

  if [ "$find_exit_code" -ne 0 ]; then
    repository_scan_failed=1
    repository_scan_failure_count=$((repository_scan_failure_count + 1))
    emit_runtime_diagnostics_once
    log_error "repository scan encountered inaccessible paths under authorized roots (find exit: $find_exit_code); continuing with readable results"
    emit_find_stderr_sample
  fi

  sort -u "$repo_scan_file" > "$repo_list_file"
}

write_repository_cache() {
  local cache_signature_file
  local cache_repository_file
  local cache_roots_file
  local cache_signature_destination
  cache_signature_file="$(mktemp)"

  /bin/mkdir -p "$CACHE_DIR"
  build_scan_root_signature "$cache_signature_file"
  cache_repository_file="$(mktemp "$CACHE_REPO_LIST_FILE.XXXXXX")"
  cache_roots_file="$(mktemp "$CACHE_SCAN_ROOTS_FILE.XXXXXX")"
  cache_signature_destination="$(mktemp "$CACHE_SCAN_ROOTS_SIGNATURE_FILE.XXXXXX")"
  cp "$validated_repo_list_file" "$cache_repository_file"
  cp "$scan_roots_file" "$cache_roots_file"
  cp "$cache_signature_file" "$cache_signature_destination"
  mv "$cache_repository_file" "$CACHE_REPO_LIST_FILE"
  mv "$cache_roots_file" "$CACHE_SCAN_ROOTS_FILE"
  mv "$cache_signature_destination" "$CACHE_SCAN_ROOTS_SIGNATURE_FILE"
  rm -f "$cache_signature_file"
}

cache_matches_current_roots() {
  local current_signature_file
  local cache_mtime
  local current_epoch
  local cache_age
  current_signature_file="$(mktemp)"

  if [ ! -f "$CACHE_REPO_LIST_FILE" ] || [ ! -f "$CACHE_SCAN_ROOTS_FILE" ] || [ ! -f "$CACHE_SCAN_ROOTS_SIGNATURE_FILE" ]; then
    rm -f "$current_signature_file"
    return 1
  fi

  cache_mtime="$("$STAT_BIN" -f '%m' "$CACHE_REPO_LIST_FILE" 2>/dev/null)" || {
    rm -f "$current_signature_file"
    return 1
  }
  current_epoch="$(/bin/date +%s)" || {
    rm -f "$current_signature_file"
    return 1
  }
  if [ "$current_epoch" -lt "$cache_mtime" ]; then
    rm -f "$current_signature_file"
    return 1
  fi
  cache_age=$((current_epoch - cache_mtime))
  if [ "$cache_age" -ge "$REPOSITORY_CACHE_MAX_AGE_SECONDS" ]; then
    rm -f "$current_signature_file"
    return 1
  fi

  if ! cmp -s "$scan_roots_file" "$CACHE_SCAN_ROOTS_FILE"; then
    rm -f "$current_signature_file"
    return 1
  fi

  build_scan_root_signature "$current_signature_file"
  if ! cmp -s "$current_signature_file" "$CACHE_SCAN_ROOTS_SIGNATURE_FILE"; then
    rm -f "$current_signature_file"
    return 1
  fi

  rm -f "$current_signature_file"
}

load_cached_repository_list() {
  cp "$CACHE_REPO_LIST_FILE" "$repo_list_file"
}

load_cached_repository_stats() {
  local expected_checksum
  local actual_checksum

  : > "$repo_stats_cache_file"
  [ -f "$CACHE_REPO_STATS_FILE" ] || return 0
  [ -f "$CACHE_REPO_STATS_CHECKSUM_FILE" ] || return 0

  expected_checksum="$(sed -n '1p' "$CACHE_REPO_STATS_CHECKSUM_FILE")" || return 0
  [ -n "$expected_checksum" ] || return 0
  if ! cp "$CACHE_REPO_STATS_FILE" "$repo_stats_cache_file"; then
    : > "$repo_stats_cache_file"
    return 0
  fi
  actual_checksum="$(/usr/bin/cksum < "$repo_stats_cache_file")" || {
    : > "$repo_stats_cache_file"
    return 0
  }
  if [ "$actual_checksum" != "$expected_checksum" ]; then
    : > "$repo_stats_cache_file"
  fi
}

write_repository_stats_cache() {
  local cache_stats_file
  local cache_checksum_file
  local cache_checksum
  /bin/mkdir -p "$CACHE_DIR"
  cache_stats_file="$(mktemp "$CACHE_REPO_STATS_FILE.XXXXXX")"
  cache_checksum_file="$(mktemp "$CACHE_REPO_STATS_CHECKSUM_FILE.XXXXXX")"
  cp "$new_repo_stats_file" "$cache_stats_file"
  cache_checksum="$(/usr/bin/cksum < "$cache_stats_file")"
  printf '%s\n' "$cache_checksum" > "$cache_checksum_file"
  mv "$cache_stats_file" "$CACHE_REPO_STATS_FILE"
  mv "$cache_checksum_file" "$CACHE_REPO_STATS_CHECKSUM_FILE"
}

read_reflog_signature() {
  local reflog_path="$1"
  local stat_signature
  local content_checksum
  (
    trap - ERR
    stat_signature="$(run_command_with_timeout "$REPOSITORY_READ_TIMEOUT_SECONDS" \
      "$STAT_BIN" -f '%m:%z:%i' "$reflog_path")" || exit $?
    content_checksum="$(run_command_with_timeout "$REPOSITORY_READ_TIMEOUT_SECONDS" \
      /usr/bin/cksum "$reflog_path")" || exit $?
    content_checksum="${content_checksum%% *}"
    printf '%s:%s\n' "$stat_signature" "$content_checksum"
  )
}

cached_reflog_events_match() {
  local repository_identity="$1"
  local git_dir="$2"
  local reflog_path="$3"
  local reflog_mtime="$4"

  awk -F '\t' \
    -v repository_identity="$repository_identity" \
    -v git_dir="$git_dir" \
    -v reflog_path="$reflog_path" \
    -v today="$TODAY" \
    -v time_scope="$TIME_SCOPE_IDENTIFIER" \
    -v reflog_mtime="$reflog_mtime" \
    -v empty="$EMPTY_CACHE_VALUE" '
      BEGIN { valid = 1 }
      function is_unsigned(value) {
        return value != "" && value !~ /[^0-9]/
      }
      function is_object_id(value) {
        return (length(value) == 40 || length(value) == 64) && value !~ /[^0-9a-fA-F]/
      }
      function is_focus_block(value, digits) {
        digits = value
        gsub(/[-T:]/, "", digits)
        return length(value) == 16 &&
          substr(value, 5, 1) == "-" &&
          substr(value, 8, 1) == "-" &&
          substr(value, 11, 1) == "T" &&
          substr(value, 14, 1) == ":" &&
          length(digits) == 12 && digits !~ /[^0-9]/
      }

      $1 == "v3" &&
      $2 == repository_identity &&
      $4 == git_dir &&
      $5 == reflog_path &&
      $6 == today &&
      $7 == time_scope &&
      $8 == reflog_mtime {
        found = 1
        if (NF != 15) {
          valid = 0
        } else if ($9 == empty) {
          empty_count++
          if ($10 != empty || $11 != empty || $12 != empty || $13 != empty || $14 != empty || $15 != empty) {
            valid = 0
          }
        } else {
          event_count++
          if (!is_unsigned($9) ||
                   !is_object_id($10) ||
                   !is_object_id($11) ||
                   ($12 != "commit" && $12 != "amend" && $12 != "merge" &&
                    $12 != "rewriteStart" && $12 != "rewrite" && $12 != "rewriteFinish") ||
                   !is_unsigned($13) ||
                   !is_unsigned($14) ||
                   ($15 != "0" && $15 != "1")) {
            valid = 0
          }
        }
      }
      END {
        if (empty_count > 1 || (empty_count > 0 && event_count > 0)) {
          valid = 0
        }
        exit found && valid != 0 ? 0 : 1
      }
    ' "$repo_stats_cache_file"
}

cached_reflog_entry_exists() {
  local repository_identity="$1"
  local git_dir="$2"
  local reflog_path="$3"

  awk -F '\t' \
    -v repository_identity="$repository_identity" \
    -v git_dir="$git_dir" \
    -v reflog_path="$reflog_path" \
    -v today="$TODAY" \
    -v time_scope="$TIME_SCOPE_IDENTIFIER" '
      $1 == "v3" &&
      $2 == repository_identity &&
      $4 == git_dir &&
      $5 == reflog_path &&
      $6 == today &&
      $7 == time_scope {
        found = 1
        exit
      }
      END { exit found ? 0 : 1 }
    ' "$repo_stats_cache_file"
}

append_cached_reflog_events() {
  local repository_identity="$1"
  local display_name="$2"
  local git_dir="$3"
  local reflog_path="$4"
  local reflog_mtime="$5"
  local schema
  local cached_identity
  local cached_display_name
  local cached_git_dir
  local cached_reflog_path
  local cached_day
  local cached_time_scope
  local cached_mtime
  local epoch
  local old_object_id
  local new_object_id
  local kind
  local message_fingerprint
  local focus_block
  local actor_is_automated

  awk -F '\t' \
    -v repository_identity="$repository_identity" \
    -v git_dir="$git_dir" \
    -v reflog_path="$reflog_path" \
    -v today="$TODAY" \
    -v time_scope="$TIME_SCOPE_IDENTIFIER" \
    -v reflog_mtime="$reflog_mtime" '
      $1 == "v3" &&
      $2 == repository_identity &&
      $4 == git_dir &&
      $5 == reflog_path &&
      $6 == today &&
      $7 == time_scope &&
      $8 == reflog_mtime
    ' "$repo_stats_cache_file" > "$repo_reflog_file"

  : > "$repo_activity_events_file"

  while IFS=$'\t' read -r schema cached_identity cached_display_name cached_git_dir cached_reflog_path cached_day cached_time_scope cached_mtime epoch old_object_id new_object_id kind message_fingerprint focus_block actor_is_automated; do
    [ "$epoch" = "$EMPTY_CACHE_VALUE" ] && continue
    if ! epoch="$(normalize_nonnegative_int64 "$epoch")"; then
      future_reflog_event_detected=1
      continue
    fi
    if [ "$epoch" -gt "$REFRESH_EPOCH" ]; then
      future_reflog_event_detected=1
      continue
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$epoch" "$old_object_id" "$new_object_id" "$kind" "$message_fingerprint" "$focus_block" "$actor_is_automated" >> "$repo_activity_events_file"
  done < "$repo_reflog_file"
}

commit_cached_reflog_events() {
  local cache_row
  while IFS= read -r cache_row; do
    printf '%s\n' "$cache_row" >> "$new_repo_stats_file"
  done < "$repo_reflog_file"
}

retain_last_valid_cached_reflog_events() {
  local repository_identity="$1"
  local display_name="$2"
  local git_dir="$3"
  local reflog_path="$4"
  local cached_signature

  cached_signature="$(awk -F '\t' \
    -v repository_identity="$repository_identity" \
    -v git_dir="$git_dir" \
    -v reflog_path="$reflog_path" \
    -v today="$TODAY" \
    -v time_scope="$TIME_SCOPE_IDENTIFIER" '
      $1 == "v3" &&
      $2 == repository_identity &&
      $4 == git_dir &&
      $5 == reflog_path &&
      $6 == today &&
      $7 == time_scope {
        print $8
        exit
      }
    ' "$repo_stats_cache_file")"

  [ -n "$cached_signature" ] || return 1
  cached_reflog_events_match \
    "$repository_identity" "$git_dir" "$reflog_path" "$cached_signature" || return 1
  append_cached_reflog_events \
    "$repository_identity" "$display_name" "$git_dir" "$reflog_path" "$cached_signature"
  commit_cached_reflog_events
  append_repo_activity_events_to_raw "$repository_identity" "$display_name" "$reflog_path" "$git_dir"
  retained_repository_count=$((retained_repository_count + 1))
}

write_reflog_events_to_cache() {
  local repository_identity="$1"
  local display_name="$2"
  local git_dir="$3"
  local reflog_path="$4"
  local reflog_mtime="$5"
  local epoch
  local old_object_id
  local new_object_id
  local kind
  local message_fingerprint
  local focus_block
  local actor_is_automated

  if [ ! -s "$repo_activity_events_file" ]; then
    printf 'v3\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$repository_identity" "$display_name" "$git_dir" "$reflog_path" "$TODAY" "$TIME_SCOPE_IDENTIFIER" "$reflog_mtime" \
      "$EMPTY_CACHE_VALUE" "$EMPTY_CACHE_VALUE" "$EMPTY_CACHE_VALUE" "$EMPTY_CACHE_VALUE" "$EMPTY_CACHE_VALUE" "$EMPTY_CACHE_VALUE" "$EMPTY_CACHE_VALUE" >> "$new_repo_stats_file"
    return
  fi

  while IFS=$'\t' read -r epoch old_object_id new_object_id kind message_fingerprint focus_block actor_is_automated; do
    printf 'v3\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$repository_identity" "$display_name" "$git_dir" "$reflog_path" "$TODAY" "$TIME_SCOPE_IDENTIFIER" "$reflog_mtime" \
      "$epoch" "$old_object_id" "$new_object_id" "$kind" "$message_fingerprint" "$focus_block" "$actor_is_automated" >> "$new_repo_stats_file"
  done < "$repo_activity_events_file"
}

process_repository_list() {
  local using_cached_repo_list="$1"
  local repo_root
  local canonical_repo_root
  local git_dir
  local common_dir
  local repository_identity
  local display_name
  local reflog_path
  local reflog_mtime
  local verified_reflog_signature
  local read_verified_signature_exit_code
  local parse_attempt
  local stable_reflog_read
  local event_epoch
  local event_object_id
  local event_kind
  local event_focus_block
  local recent_repository_identity=""

  reset_activity_snapshot
  : > "$validated_repo_list_file"

  while IFS= read -r repo_root; do
    current_repository_candidate="$repo_root"
    if [ ! -e "$repo_root" ]; then
      if [ "$using_cached_repo_list" -eq 1 ]; then
        log_error "cached repository path is no longer available; rebuilding repository cache"
        return 2
      fi
      record_invalid_repository "candidate-missing"
      continue
    fi

    trap - ERR
    if canonical_repo_root="$(resolve_existing_directory_path "$repo_root")"; then
      resolve_repo_root_exit_code=0
    else
      resolve_repo_root_exit_code="$?"
    fi
    enable_error_trap
    if [ "$resolve_repo_root_exit_code" -ne 0 ]; then
      if [ "$using_cached_repo_list" -eq 1 ]; then
        log_error "cached repository root is no longer available; rebuilding repository cache"
        return 2
      fi
      record_invalid_repository "repository-root-resolution-failed"
      continue
    fi
    repo_root="$canonical_repo_root"
    current_repository_candidate="$repo_root"

    if ! repository_candidate_is_allowed "$repo_root"; then
      continue
    fi

    trap - ERR
    if git_dir="$(resolve_git_dir "$repo_root")"; then
      resolve_git_dir_exit_code=0
    else
      resolve_git_dir_exit_code="$?"
    fi
    enable_error_trap
    if [ "$resolve_git_dir_exit_code" -ne 0 ]; then
      if [ "$using_cached_repo_list" -eq 1 ]; then
        log_error "cached repository metadata is no longer available; rebuilding repository cache"
        return 2
      fi
      record_invalid_repository "gitdir-resolution-failed"
      continue
    fi

    if ! path_is_within_authorized_roots "$git_dir"; then
      if [ "$using_cached_repo_list" -eq 1 ]; then
        log_error "cached repository metadata escaped authorized roots; rebuilding repository cache"
        return 2
      fi
      record_invalid_repository "gitdir-outside-authorized-root"
      log_error "resolved git metadata path escaped authorized roots; skipping one repository"
      continue
    fi

    if ! validate_git_metadata_layout "$git_dir"; then
      if [ "$using_cached_repo_list" -eq 1 ]; then
        log_error "cached repository metadata is no longer valid; rebuilding repository cache"
        return 2
      fi
      record_invalid_repository "gitdir-layout-incomplete"
      log_error "resolved git metadata is incomplete for one repository; skipping one repository"
      continue
    fi

    trap - ERR
    if common_dir="$(resolve_common_git_dir "$git_dir")"; then
      resolve_common_dir_exit_code=0
    else
      resolve_common_dir_exit_code="$?"
    fi
    enable_error_trap
    if [ "$resolve_common_dir_exit_code" -ne 0 ] || ! path_is_within_authorized_roots "$common_dir"; then
      if [ "$using_cached_repo_list" -eq 1 ]; then
        log_error "cached repository common metadata is no longer available; rebuilding repository cache"
        return 2
      fi
      record_invalid_repository "common-gitdir-resolution-failed"
      continue
    fi

    repository_identity="$common_dir"
    display_name="$(repository_display_name "$repo_root" "$common_dir")"
    if ! record_field_is_supported "$repository_identity" ||
       ! record_field_is_supported "$display_name" ||
       ! record_field_is_supported "$repo_root" ||
       ! record_field_is_supported "$git_dir"; then
      record_invalid_repository "unsupported-repository-path-characters"
      continue
    fi
    printf '%s\n' "$repository_identity" >> "$repository_identity_file"

    reflog_path="$git_dir/logs/HEAD"
    if [ ! -e "$reflog_path" ]; then
      if [ "$using_cached_repo_list" -eq 1 ]; then
        log_error "cached repository reflog is no longer available; rebuilding repository cache"
        return 2
      fi
      record_invalid_repository "reflog-missing"
      recovery_has_missing_reflog=1
      continue
    fi
    if [ ! -r "$reflog_path" ]; then
      record_invalid_repository "reflog-unreadable"
      log_error "git reflog path is not readable for one repository; preserving previous shared data"
      continue
    fi
    if [ ! -f "$reflog_path" ]; then
      readable_reflog_repo_count=$((readable_reflog_repo_count + 1))
      failed_reflog_repo_count=$((failed_reflog_repo_count + 1))
      record_invalid_repository "reflog-not-regular-file"
      log_error "git reflog path is not a regular file for one repository; preserving previous shared data"
      continue
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$repository_identity" "$display_name" "$repo_root" "$git_dir" "$reflog_path" >> "$repository_records_file"
    printf '%s\n' "$repo_root" >> "$validated_repo_list_file"
  done < "$repo_list_file"

  LC_ALL=C sort -u "$repository_identity_file" > "$repo_reflog_file"
  repository_count="$(awk 'END { print NR + 0 }' "$repo_reflog_file")"
  LC_ALL=C sort -t $'\t' -k1,1 -k5,5 -k3,3 "$repository_records_file" |
    awk -F '\t' '!seen[$1 SUBSEP $5]++' > "$unique_repository_records_file"
  LC_ALL=C sort -u "$validated_repo_list_file" > "$repo_reflog_file"
  cp "$repo_reflog_file" "$validated_repo_list_file"

  while IFS=$'\t' read -r repository_identity display_name repo_root git_dir reflog_path; do
    current_repository_candidate="$repo_root"
    readable_reflog_repo_count=$((readable_reflog_repo_count + 1))
    trap - ERR
    if reflog_mtime="$(read_reflog_signature "$reflog_path")"; then
      read_reflog_signature_exit_code=0
    else
      read_reflog_signature_exit_code="$?"
    fi
    enable_error_trap
    if [ "$read_reflog_signature_exit_code" -ne 0 ]; then
      failed_reflog_repo_count=$((failed_reflog_repo_count + 1))
      record_invalid_repository "reflog-mtime-failed"
      if retain_last_valid_cached_reflog_events "$repository_identity" "$display_name" "$git_dir" "$reflog_path"; then
        log_error "failed to read git reflog metadata for one repository; retained its last valid result"
      else
        log_error "failed to read git reflog metadata for one repository; no valid cached result was available"
      fi
      continue
    fi

    if cached_reflog_entry_exists "$repository_identity" "$git_dir" "$reflog_path"; then
      cache_hit_count=$((cache_hit_count + 1))
    fi
    if cached_reflog_events_match "$repository_identity" "$git_dir" "$reflog_path" "$reflog_mtime"; then
      append_cached_reflog_events "$repository_identity" "$display_name" "$git_dir" "$reflog_path" "$reflog_mtime"
      trap - ERR
      if verified_reflog_signature="$(read_reflog_signature "$reflog_path")"; then
        read_verified_signature_exit_code=0
      else
        read_verified_signature_exit_code="$?"
      fi
      enable_error_trap
      if [ "$read_verified_signature_exit_code" -eq 0 ] &&
         [ "$verified_reflog_signature" = "$reflog_mtime" ]; then
        successful_reflog_repo_count=$((successful_reflog_repo_count + 1))
        reflog_unchanged_skip_count=$((reflog_unchanged_skip_count + 1))
        commit_cached_reflog_events
        append_repo_activity_events_to_raw "$repository_identity" "$display_name" "$reflog_path" "$git_dir"
        continue
      fi
      if [ "$read_verified_signature_exit_code" -eq 0 ]; then
        reflog_mtime="$verified_reflog_signature"
      fi
    fi

    recomputed_repository_count=$((recomputed_repository_count + 1))
    parse_attempt=0
    stable_reflog_read=0
    while [ "$parse_attempt" -lt 2 ]; do
      parse_attempt=$((parse_attempt + 1))
      if ! append_reflog_events_for_today "$repository_identity" "$display_name" "$git_dir" "$reflog_path"; then
        break
      fi

      trap - ERR
      if verified_reflog_signature="$(read_reflog_signature "$reflog_path")"; then
        read_verified_signature_exit_code=0
      else
        read_verified_signature_exit_code="$?"
      fi
      enable_error_trap
      if [ "$read_verified_signature_exit_code" -ne 0 ]; then
        break
      fi
      if [ "$verified_reflog_signature" = "$reflog_mtime" ]; then
        stable_reflog_read=1
        break
      fi
      reflog_mtime="$verified_reflog_signature"
    done

    if [ "$stable_reflog_read" -ne 1 ]; then
      failed_reflog_repo_count=$((failed_reflog_repo_count + 1))
      record_invalid_repository "reflog-parse-failed"
      if retain_last_valid_cached_reflog_events "$repository_identity" "$display_name" "$git_dir" "$reflog_path"; then
        log_error "failed to obtain a stable git reflog read for one repository; retained its last valid result"
      else
        log_error "failed to obtain a stable git reflog read for one repository; continuing without that repository"
      fi
      continue
    fi
    successful_reflog_repo_count=$((successful_reflog_repo_count + 1))
    append_repo_activity_events_to_raw "$repository_identity" "$display_name" "$reflog_path" "$git_dir"
    write_reflog_events_to_cache "$repository_identity" "$display_name" "$git_dir" "$reflog_path" "$reflog_mtime"
  done < "$unique_repository_records_file"

  normalize_activity_events || return 1
  while IFS=$'\t' read -r repository_identity display_name event_epoch event_object_id event_kind event_focus_block; do
    total_count=$((total_count + 1))
    printf '%s\n' "$event_focus_block" >> "$focus_block_list_file"

    # Latest epoch wins; equal epochs use the canonical repository identity so
    # the recent-project result is independent of find/reflog iteration order.
    if [ -z "$latest_activity_timestamp" ] ||
       [ "$event_epoch" -gt "$latest_activity_timestamp" ] ||
       { [ "$event_epoch" -eq "$latest_activity_timestamp" ] && { [ -z "$recent_repository_identity" ] || [[ "$repository_identity" < "$recent_repository_identity" ]]; }; }; then
      latest_activity_timestamp="$event_epoch"
      recent_repository_identity="$repository_identity"
      recent_project_name="$display_name"
    fi
  done < "$normalized_activity_events_file"
}

write_plist_string() {
  local key="$1"
  local value="$2"
  /usr/bin/defaults write "$APP_GROUP_PREFERENCES_PLIST" "$key" -string "$value"
}

write_plist_integer() {
  local key="$1"
  local value="$2"
  /usr/bin/defaults write "$APP_GROUP_PREFERENCES_PLIST" "$key" -int "$value"
}

plist_integer_matches() {
  local key="$1"
  local value="$2"
  local extracted_value

  if ! extracted_value="$(/usr/bin/plutil -p "$APP_GROUP_PREFERENCES_PLIST" 2>/dev/null | awk -v key="$key" '
      index($0, "\"" key "\" => ") {
        sub(/^.*=> /, "", $0)
        print
        exit
      }
    ')"; then
    return 1
  fi

  [ "$extracted_value" = "$value" ]
}

read_plist_value() {
  local key="$1"
  local value

  if ! value="$(trap - ERR; /usr/libexec/PlistBuddy -c "Print :$key" "$APP_GROUP_PREFERENCES_PLIST" 2>/dev/null)"; then
    printf '%s\n' "$MISSING_PLIST_VALUE"
    return 0
  fi

  printf '%s\n' "$value"
}

write_plist_string_if_changed() {
  local key="$1"
  local value="$2"
  local current_value=""

  if current_value="$(read_plist_value "$key")" && [ "$current_value" = "$value" ]; then
    return
  fi

  shared_data_rewritten=1
  write_plist_string "$key" "$value"
}

write_plist_integer_if_changed() {
  local key="$1"
  local value="$2"
  local current_value=""

  if current_value="$(read_plist_value "$key")" &&
     [ "$current_value" = "$value" ] &&
     plist_integer_matches "$key" "$value"; then
    return
  fi

  shared_data_rewritten=1
  write_plist_integer "$key" "$value"
}

acquire_snapshot_write_lock() {
  local attempt=0
  local deadline=$((SECONDS + SNAPSHOT_WRITE_LOCK_TIMEOUT_SECONDS))
  local owner_name=""
  local owner_path=""
  local owner_pid=""
  local possible_owner=""

  while ! mkdir "$SNAPSHOT_WRITE_LOCK" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ $((attempt % 25)) -eq 0 ]; then
      owner_path=""
      for possible_owner in "$SNAPSHOT_WRITE_LOCK"/owner-*; do
        if [ -d "$possible_owner" ]; then
          owner_path="$possible_owner"
          break
        fi
      done

      owner_pid=""
      if [ -n "$owner_path" ]; then
        owner_name="${owner_path##*/}"
        owner_pid="${owner_name#owner-}"
      fi

      case "$owner_pid" in
        ""|*[!0-9]*)
          if [ "$attempt" -ge 100 ]; then
            # An owner-less lock means the previous process died between the
            # two mkdir calls. rmdir succeeds only while it remains empty, so
            # it cannot remove a lock whose live owner appeared concurrently.
            rmdir "$SNAPSHOT_WRITE_LOCK" 2>/dev/null || true
          fi
          ;;
        *)
          if ! kill -0 "$owner_pid" 2>/dev/null; then
            rmdir "$owner_path" 2>/dev/null || true
            rmdir "$SNAPSHOT_WRITE_LOCK" 2>/dev/null || true
          fi
          ;;
      esac
    fi
    if [ "$SECONDS" -ge "$deadline" ]; then
      log_error "timed out waiting for shared snapshot write lock"
      return 1
    fi
    sleep 0.01
  done

  if ! mkdir "$SNAPSHOT_WRITE_LOCK_OWNER" 2>/dev/null; then
    rmdir "$SNAPSHOT_WRITE_LOCK" 2>/dev/null || true
    return 1
  fi
  snapshot_write_lock_acquired=1
}

time_scope_token_is_current() {
  local observed_token

  if [ -z "${TINYBUDDY_TIME_SCOPE_FILE:-}" ] && [ -z "${TINYBUDDY_TIME_SCOPE_TOKEN:-}" ]; then
    return 0
  fi
  if [ -z "${TINYBUDDY_TIME_SCOPE_FILE:-}" ] || [ -z "${TINYBUDDY_TIME_SCOPE_TOKEN:-}" ]; then
    return 1
  fi
  observed_token="$(sed -n '1p' "$TINYBUDDY_TIME_SCOPE_FILE" 2>/dev/null)" || return 1
  [ "$observed_token" = "$TINYBUDDY_TIME_SCOPE_TOKEN" ]
}

write_trusted_snapshot_if_newer() {
  local encoded_project_name
  local current_snapshot=""
  local current_revision=""
  local normalized_current_revision=""
  local current_payload=""
  local proposed_payload

  encoded_project_name="$(printf '%s' "$recent_project_name" | /usr/bin/base64 | tr -d '\n')"
  if [ -n "${TINYBUDDY_TIME_SCOPE_TOKEN:-}" ]; then
    proposed_payload="$TODAY"$'\t'"$TIME_SCOPE_IDENTIFIER"$'\t'"$TINYBUDDY_TIME_SCOPE_TOKEN"$'\t'"$focus_block_count"$'\t'"$total_count"$'\t'"$encoded_project_name"
  else
    proposed_payload="$TODAY"$'\t'"$TIME_SCOPE_IDENTIFIER"$'\t'"$focus_block_count"$'\t'"$total_count"$'\t'"$encoded_project_name"
  fi

  if current_snapshot="$(read_plist_value "$TRUSTED_SNAPSHOT_KEY")"; then
    current_revision="${current_snapshot%%$'\t'*}"
    if [[ "$current_snapshot" == *$'\t'* ]]; then
      current_payload="${current_snapshot#*$'\t'}"
    fi

    normalized_current_revision="$(normalize_nonnegative_int64 "$current_revision" || true)"

    if [ -n "$normalized_current_revision" ] &&
       [ "$current_payload" = "$proposed_payload" ]; then
      return
    fi

    if [ -n "$normalized_current_revision" ] &&
       [ "$normalized_current_revision" -ge "$REFRESH_REVISION" ]; then
      if [ "$REFRESH_REVISION_IS_EXPLICIT" -eq 1 ]; then
        trusted_snapshot_stale=1
        refresh_outcome_override="skipped"
        echo "TinyBuddy git shared snapshot is newer; skipped stale write"
        return
      fi

      if [ "$normalized_current_revision" = "9223372036854775807" ]; then
        trusted_snapshot_stale=1
        log_error "trusted snapshot revision is exhausted; preserving previous shared data"
        return 75
      fi

      REFRESH_REVISION=$((10#$normalized_current_revision + 1))
    fi
  fi

  shared_data_rewritten=1
  write_plist_string "$TRUSTED_SNAPSHOT_KEY" "$REFRESH_REVISION"$'\t'"$proposed_payload"
}

handle_error() {
  local exit_code="$1"
  local line_number="$2"
  trap - ERR
  refresh_outcome_override="failed"
  emit_refresh_metrics || true
  log_error "failed with exit code $exit_code at line $line_number"
  exit "$exit_code"
}

enable_error_trap() {
  trap 'handle_error $? $LINENO' ERR
}

trap cleanup EXIT
enable_error_trap

if ! command -v "$GIT_BIN" >/dev/null 2>&1; then
  log_error "git executable not found in configured command search path"
  refresh_outcome_override="failed"
  emit_refresh_metrics
  exit 127
fi

case "$DUPLICATE_EVENT_WINDOW_SECONDS" in
  ""|*[!0-9]*)
    log_error "duplicate event window is invalid"
    refresh_outcome_override="failed"
    emit_refresh_metrics
    exit 64
    ;;
esac
if [ "$DUPLICATE_EVENT_WINDOW_SECONDS" -gt 3600 ]; then
  log_error "duplicate event window exceeds the supported maximum"
  refresh_outcome_override="failed"
  emit_refresh_metrics
  exit 64
fi

case "$REPOSITORY_CACHE_MAX_AGE_SECONDS" in
  ""|*[!0-9]*)
    log_error "repository cache maximum age is invalid"
    refresh_outcome_override="failed"
    emit_refresh_metrics
    exit 64
    ;;
esac
if [ "$REPOSITORY_CACHE_MAX_AGE_SECONDS" -gt 86400 ]; then
  log_error "repository cache maximum age exceeds the supported maximum"
  refresh_outcome_override="failed"
  emit_refresh_metrics
  exit 64
fi

case "$SCAN_ROOT_TIMEOUT_SECONDS:$REPOSITORY_READ_TIMEOUT_SECONDS:$REPOSITORY_PARSE_TIMEOUT_SECONDS" in
  *[!0-9:]*|:*|*:|*::* )
    log_error "git scan timeout configuration is invalid"
    refresh_outcome_override="failed"
    emit_refresh_metrics
    exit 64
    ;;
esac
if [ "$SCAN_ROOT_TIMEOUT_SECONDS" -lt 1 ] || [ "$SCAN_ROOT_TIMEOUT_SECONDS" -gt 300 ] ||
   [ "$REPOSITORY_READ_TIMEOUT_SECONDS" -lt 1 ] || [ "$REPOSITORY_READ_TIMEOUT_SECONDS" -gt 60 ] ||
   [ "$REPOSITORY_PARSE_TIMEOUT_SECONDS" -lt 1 ] || [ "$REPOSITORY_PARSE_TIMEOUT_SECONDS" -gt 300 ]; then
  log_error "git scan timeout configuration is outside the supported range"
  refresh_outcome_override="failed"
  emit_refresh_metrics
  exit 64
fi

case "$TODAY" in
  ????-??-??)
    case "${TODAY:0:4}${TODAY:5:2}${TODAY:8:2}" in
      *[!0-9]*)
        log_error "today identifier is invalid"
        refresh_outcome_override="failed"
        emit_refresh_metrics
        exit 64
        ;;
    esac
    ;;
  *)
    log_error "today identifier is invalid"
    refresh_outcome_override="failed"
    emit_refresh_metrics
    exit 64
    ;;
esac
if [ "$(/bin/date -j -f '%Y-%m-%d' "$TODAY" '+%Y-%m-%d' 2>/dev/null || true)" != "$TODAY" ]; then
  log_error "today identifier is invalid"
  refresh_outcome_override="failed"
  emit_refresh_metrics
  exit 64
fi

case "$TIME_SCOPE_IDENTIFIER" in
  ""|*[!A-Za-z0-9._+/:=-]*)
    log_error "time scope identifier is invalid"
    refresh_outcome_override="failed"
    emit_refresh_metrics
    exit 64
    ;;
esac
case "$SNAPSHOT_WRITE_LOCK_TIMEOUT_SECONDS" in
  ""|*[!0-9]*)
    log_error "snapshot write lock timeout is invalid"
    refresh_outcome_override="failed"
    emit_refresh_metrics
    exit 64
    ;;
esac
if [ "$SNAPSHOT_WRITE_LOCK_TIMEOUT_SECONDS" -lt 1 ] || [ "$SNAPSHOT_WRITE_LOCK_TIMEOUT_SECONDS" -gt 600 ]; then
  log_error "snapshot write lock timeout is outside the supported range"
  refresh_outcome_override="failed"
  emit_refresh_metrics
  exit 64
fi
if { [ -n "${TINYBUDDY_TIME_SCOPE_FILE:-}" ] && [ -z "${TINYBUDDY_TIME_SCOPE_TOKEN:-}" ]; } ||
   { [ -z "${TINYBUDDY_TIME_SCOPE_FILE:-}" ] && [ -n "${TINYBUDDY_TIME_SCOPE_TOKEN:-}" ]; }; then
  log_error "time scope file and token must be supplied together"
  refresh_outcome_override="failed"
  emit_refresh_metrics
  exit 64
fi
if [ -n "${TINYBUDDY_TIME_SCOPE_TOKEN:-}" ]; then
  case "$TINYBUDDY_TIME_SCOPE_TOKEN" in
    *[!A-Za-z0-9_-]*)
      log_error "time scope token is invalid"
      refresh_outcome_override="failed"
      emit_refresh_metrics
      exit 64
      ;;
  esac
fi

# Avoid here-strings because the signed sandboxed app can reject bash's
# implicit temporary-file creation, leaving the authorized root list empty.
printf '%s' "$SCAN_ROOTS" | while IFS= read -r scan_root || [ -n "$scan_root" ]; do
  if [ -n "$scan_root" ]; then
    printf '%s\n' "$scan_root" >> "$scan_roots_file"
  fi
done

valid_scan_roots_file="$(mktemp)"
while IFS= read -r scan_root; do
  normalized_scan_root="$(normalized_scan_root_path "$scan_root")"

  if is_broad_scan_root "$scan_root"; then
    log_error "authorized git scan root is too broad; skipping one root"
    continue
  fi

  if [[ "$normalized_scan_root" == *$'\n'* ]] || [[ "$normalized_scan_root" == *$'\r'* ]]; then
    log_error "authorized git scan root contains unsupported line breaks; skipping one root"
    continue
  fi

  printf '%s\n' "$normalized_scan_root" >> "$valid_scan_roots_file"
done < "$scan_roots_file"
LC_ALL=C sort -u "$valid_scan_roots_file" > "$scan_roots_file"

if [ ! -s "$scan_roots_file" ]; then
  log_error "no authorized git scan roots supplied; skipping refresh"
  refresh_outcome_override="skipped"
  emit_refresh_metrics
  exit 0
fi

# A refresh must be single-flight across cache construction and publication.
# Serializing only the final plist write allowed an older scan to receive a
# newer revision and overwrite a more recent scan's payload.
/bin/mkdir -p "$APP_GROUP_PREFERENCES_DIR"
acquire_snapshot_write_lock

had_cached_repository_list=0
if [ -s "$CACHE_REPO_LIST_FILE" ]; then
  had_cached_repository_list=1
fi

using_cached_repo_list=0
cache_was_reused=0
if cache_matches_current_roots; then
  load_cached_repository_list
  load_cached_repository_stats
  using_cached_repo_list=1
  cache_was_reused=1
else
  refresh_repository_list_from_scan
  if [ "$repository_scan_failed" -eq 1 ] && [ ! -s "$repo_list_file" ]; then
    log_error "repository scan failed; preserving previous shared data"
    refresh_outcome_override="failed"
    emit_refresh_metrics
    exit 1
  fi
  if [ "$had_cached_repository_list" -eq 1 ] && [ ! -s "$repo_list_file" ]; then
    log_error "repository rescan found no repositories; preserving previous shared data"
    refresh_outcome_override="failed"
    emit_refresh_metrics
    exit 1
  fi
  load_cached_repository_stats
fi

process_repository_list "$using_cached_repo_list" || process_result="$?"
if [ "${process_result:-0}" -ne 0 ]; then
  if [ "$process_result" -ne 2 ]; then
    emit_runtime_diagnostics_once
    refresh_outcome_override="failed"
    emit_refresh_metrics
    exit 1
  fi

  recovered_repository_list=0
  refresh_repository_list_from_scan
  if [ -s "$repo_list_file" ]; then
    recovery_process_result=0
    process_repository_list 0 || recovery_process_result="$?"
    if [ "$recovery_process_result" -eq 0 ] &&
       [ "$successful_reflog_repo_count" -gt 0 ] &&
       [ -s "$validated_repo_list_file" ]; then
      recovered_repository_list=1
      cache_was_reused=0
    fi
  fi
  if [ "$recovered_repository_list" -eq 0 ]; then
    emit_runtime_diagnostics_once
    log_error "cached repository paths are temporarily unavailable; preserving previous shared data"
    emit_find_stderr_sample
    refresh_outcome_override="failed"
    emit_refresh_metrics
    exit 1
  fi
fi

if [ "$invalid_repository_count" -gt 0 ] && [ "$successful_reflog_repo_count" -eq 0 ]; then
  emit_runtime_diagnostics_once
  log_error "all discovered repositories are invalid or unreadable; preserving previous shared data"
  refresh_outcome_override="failed"
  emit_refresh_metrics
  exit 1
fi

focus_block_count="$(sort -u "$focus_block_list_file" | awk 'END { print NR + 0 }')"

if [ ! -s "$repo_list_file" ]; then
  emit_runtime_diagnostics_once
  log_error "no git repositories discovered under authorized roots"
  emit_find_stderr_sample
fi

if [ "$readable_reflog_repo_count" -gt 0 ] && [ "$successful_reflog_repo_count" -eq 0 ]; then
  emit_runtime_diagnostics_once
  log_error "failed to read git reflog for every readable repository; preserving previous shared data"
  refresh_outcome_override="failed"
  emit_refresh_metrics
  exit 1
fi

if [ "$failed_reflog_repo_count" -gt 0 ] && [ "$successful_reflog_repo_count" -eq 0 ]; then
  emit_runtime_diagnostics_once
  log_error "failed to parse every readable git reflog; preserving previous shared data"
  refresh_outcome_override="failed"
  emit_refresh_metrics
  exit 1
fi

if [ "$future_reflog_event_detected" -eq 1 ]; then
  log_error "future git reflog activity detected; preserving previous shared data"
  refresh_outcome_override="failed"
  emit_refresh_metrics
  exit 1
fi

if [ "$failed_reflog_repo_count" -gt 0 ]; then
  emit_runtime_diagnostics_once
  log_error "partial refresh: one or more git reflogs failed; publishing other valid repositories"
fi

if ! time_scope_token_is_current; then
  log_error "time scope changed during refresh; preserving previous shared data"
  refresh_outcome_override="skipped"
  emit_refresh_metrics
  exit 0
fi
if [ ! -f "$APP_GROUP_PREFERENCES_PLIST" ]; then
  /usr/bin/plutil -create xml1 "$APP_GROUP_PREFERENCES_PLIST"
fi
write_trusted_snapshot_if_newer
if [ "$trusted_snapshot_stale" -eq 0 ]; then
  write_plist_string_if_changed "$DAY_KEY" "$TODAY"
  write_plist_integer_if_changed "$COUNT_KEY" "$total_count"
  write_plist_string_if_changed "$FOCUS_BLOCK_DAY_KEY" "$TODAY"
  write_plist_integer_if_changed "$FOCUS_BLOCK_COUNT_KEY" "$focus_block_count"
  write_plist_string_if_changed "$RECENT_PROJECT_DAY_KEY" "$TODAY"
  write_plist_string_if_changed "$RECENT_PROJECT_NAME_KEY" "$recent_project_name"
fi
if [ "$invalid_repository_count" -eq 0 ]; then
  if [ "$cache_was_reused" -eq 0 ]; then
    write_repository_cache
  fi
  write_repository_stats_cache
else
  log_error "partial refresh: retaining previous repository caches"
fi

if [ "$shared_data_rewritten" -eq 0 ]; then
  echo "TinyBuddy git shared data unchanged; skipped plist rewrite"
fi

emit_refresh_metrics
echo "Updated TinyBuddy git completion count: $total_count"
echo "Updated TinyBuddy git focus block count: $focus_block_count"
echo "Updated TinyBuddy recent project name: ${recent_project_name:-<none>}"
