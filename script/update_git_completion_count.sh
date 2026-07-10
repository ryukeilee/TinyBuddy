#!/usr/bin/env bash
set -Eeuo pipefail

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
TODAY="${TINYBUDDY_TODAY:-$(date +%F)}"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:${PATH:-}"
FIND_BIN="${TINYBUDDY_FIND_BIN:-find}"
STAT_BIN="${TINYBUDDY_STAT_BIN:-stat}"
PERL_BIN="${TINYBUDDY_PERL_BIN:-perl}"
CACHE_DIR="${TINYBUDDY_GIT_REPOSITORY_CACHE_DIR:-$APP_GROUP_PREFERENCES_DIR/.tinybuddy-git-repository-cache}"
CACHE_REPO_LIST_FILE="$CACHE_DIR/repositories.txt"
CACHE_REPO_STATS_FILE="$CACHE_DIR/repository-stats.tsv"
CACHE_SCAN_ROOTS_FILE="$CACHE_DIR/authorized-roots.txt"
CACHE_SCAN_ROOTS_SIGNATURE_FILE="$CACHE_DIR/authorized-roots.signature"
EMPTY_CACHE_VALUE="__TINYBUDDY_EMPTY__"
REFRESH_REVISION="${TINYBUDDY_REFRESH_REVISION:-$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000000')}"
SNAPSHOT_WRITE_LOCK="$APP_GROUP_PREFERENCES_DIR/.tinybuddy-git-snapshot-write.lock"

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
find_stderr_file="$(mktemp)"
focus_block_list_file="$(mktemp)"
diagnostics_emitted=0
shared_data_rewritten=0
repository_count=0
cache_hit_count=0
reflog_unchanged_skip_count=0
recomputed_repository_count=0
repository_scan_failed=0
invalid_repository_count=0
snapshot_write_lock_acquired=0
trusted_snapshot_stale=0

log_error() {
  echo "TinyBuddy refresh script: $*" >&2
}

cleanup() {
  if [ "$snapshot_write_lock_acquired" -eq 1 ]; then
    rmdir "$SNAPSHOT_WRITE_LOCK" 2>/dev/null || true
  fi
  rm -f "$scan_roots_file" "$valid_scan_roots_file" "$repo_list_file" "$repo_scan_file" "$repo_reflog_file" "$repo_git_paths_file" "$repo_stats_cache_file" "$new_repo_stats_file" "$validated_repo_list_file" "$find_stderr_file" "$focus_block_list_file"
}

emit_runtime_diagnostics_once() {
  if [ "$diagnostics_emitted" -eq 1 ]; then
    return
  fi

  diagnostics_emitted=1

  local git_path
  local scan_roots_count
  git_path="$(command -v git 2>/dev/null || true)"
  scan_roots_count="$(awk 'END { print NR + 0 }' "$scan_roots_file")"
  log_error "diagnostics: script=$0 pwd=$(pwd) home=$HOME user_home=$USER_HOME scan_roots_count=$scan_roots_count path=$PATH git=${git_path:-<missing>} app_group_plist=$APP_GROUP_PREFERENCES_PLIST"
}

emit_find_stderr_sample() {
  if [ ! -s "$find_stderr_file" ]; then
    return
  fi

  local sample
  sample="$(sed -n '1,8p' "$find_stderr_file" | tr '\n' '|' | sed 's/|$//')"
  if [ -n "$sample" ]; then
    log_error "find stderr sample: $sample"
  fi
}

normalized_scan_root_path() {
  local path="$1"
  local resolved_path="$path"

  if [ -d "$path" ]; then
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
    */.pnpm-store|*/.pnpm-store/*|\
    */.swiftpm|*/.swiftpm/*|\
    */.tmp|*/.tmp/*|\
    */__fixtures__|*/__fixtures__/*|\
    */caches|*/caches/*|\
    */carthage|*/carthage/*|\
    */deriveddata|*/deriveddata/*|\
    */deps|*/deps/*|\
    */fixtures|*/fixtures/*|\
    */node_modules|*/node_modules/*|\
    */pods|*/pods/*|\
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
  invalid_repository_count=0
  : > "$focus_block_list_file"
  : > "$new_repo_stats_file"
  : > "$validated_repo_list_file"
}

emit_refresh_metrics() {
  local authorized_root_count
  authorized_root_count="$(awk 'END { print NR + 0 }' "$scan_roots_file")"

  printf 'TINYBUDDY_REFRESH_METRICS\tauthorized_root_count=%s\trepository_count=%s\tcache_hit_count=%s\treflog_unchanged_skip_count=%s\trecomputed_repository_count=%s\tshared_data_written=%s\n' \
    "$authorized_root_count" \
    "$repository_count" \
    "$cache_hit_count" \
    "$reflog_unchanged_skip_count" \
    "$recomputed_repository_count" \
    "$shared_data_rewritten"
}

build_scan_root_signature() {
  local signature_file="$1"
  local scan_root

  : > "$signature_file"

  while IFS= read -r scan_root; do
    if [ ! -d "$scan_root" ]; then
      printf 'ROOT\t%s\tmissing\n' "$scan_root" >> "$signature_file"
      continue
    fi

    "$STAT_BIN" -f 'ROOT\t%N\t%z\t%m\t%i' "$scan_root" >> "$signature_file"
    "$FIND_BIN" "$scan_root" -mindepth 1 -maxdepth 1 -exec "$STAT_BIN" -f 'ENTRY\t%N\t%z\t%m\t%i' {} \; \
      2>> "$find_stderr_file" | LC_ALL=C sort >> "$signature_file"
  done < "$scan_roots_file"
}

refresh_repository_list_from_scan() {
  local find_exit_code=0
  local scan_root

  : > "$repo_git_paths_file"
  : > "$repo_scan_file"

  while IFS= read -r scan_root; do
    if [ ! -d "$scan_root" ]; then
      log_error "authorized git scan root is not a readable directory; skipping one root"
      continue
    fi

    "$FIND_BIN" "$scan_root" \
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
    emit_runtime_diagnostics_once
    log_error "repository scan encountered inaccessible paths under authorized roots (find exit: $find_exit_code); continuing with readable results"
    emit_find_stderr_sample
  fi

  sort -u "$repo_scan_file" > "$repo_list_file"
}

write_repository_cache() {
  local cache_signature_file
  cache_signature_file="$(mktemp)"

  /bin/mkdir -p "$CACHE_DIR"
  build_scan_root_signature "$cache_signature_file"
  cp "$repo_list_file" "$CACHE_REPO_LIST_FILE"
  cp "$scan_roots_file" "$CACHE_SCAN_ROOTS_FILE"
  cp "$cache_signature_file" "$CACHE_SCAN_ROOTS_SIGNATURE_FILE"
  rm -f "$cache_signature_file"
}

cache_matches_current_roots() {
  local current_signature_file
  current_signature_file="$(mktemp)"

  if [ ! -f "$CACHE_REPO_LIST_FILE" ] || [ ! -f "$CACHE_SCAN_ROOTS_FILE" ] || [ ! -f "$CACHE_SCAN_ROOTS_SIGNATURE_FILE" ]; then
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
  if [ -f "$CACHE_REPO_STATS_FILE" ]; then
    cp "$CACHE_REPO_STATS_FILE" "$repo_stats_cache_file"
  else
    : > "$repo_stats_cache_file"
  fi
}

write_repository_stats_cache() {
  /bin/mkdir -p "$CACHE_DIR"
  cp "$new_repo_stats_file" "$CACHE_REPO_STATS_FILE"
}

read_reflog_mtime() {
  local reflog_path="$1"
  (
    trap - ERR
    "$STAT_BIN" -f '%m' "$reflog_path"
  )
}

append_cached_focus_blocks() {
  local encoded_focus_blocks="$1"

  if [ "$encoded_focus_blocks" = "$EMPTY_CACHE_VALUE" ] || [ -z "$encoded_focus_blocks" ]; then
    return
  fi

  printf '%s\n' "$encoded_focus_blocks" | tr ',' '\n' >> "$focus_block_list_file"
}

write_repository_stats_entry() {
  local repo_root="$1"
  local git_dir="$2"
  local reflog_path="$3"
  local reflog_mtime="$4"
  local repo_count="$5"
  local repo_latest_timestamp="${6:-}"
  local encoded_focus_blocks="${7:-}"

  case "$repo_root$git_dir$reflog_path$repo_latest_timestamp$encoded_focus_blocks" in
    *$'\t'*|*$'\n'*|*$'\r'*)
      return
      ;;
  esac

  if [ -z "$repo_latest_timestamp" ]; then
    repo_latest_timestamp="$EMPTY_CACHE_VALUE"
  fi

  if [ -z "$encoded_focus_blocks" ]; then
    encoded_focus_blocks="$EMPTY_CACHE_VALUE"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$repo_root" \
    "$git_dir" \
    "$reflog_path" \
    "$TODAY" \
    "$reflog_mtime" \
    "$repo_count" \
    "$repo_latest_timestamp" \
    "$encoded_focus_blocks" >> "$new_repo_stats_file"
}

process_repository_list() {
  local using_cached_repo_list="$1"
  local repo_root
  local git_dir
  local reflog_path
  local reflog_mtime
  local repo_count
  local repo_latest_timestamp
  local repo_focus_blocks
  local cached_repo_stats
  local cached_repo_root
  local cached_git_dir
  local cached_reflog_path
  local cached_day
  local cached_reflog_mtime
  local cached_repo_count
  local cached_repo_latest_timestamp
  local cached_repo_focus_blocks

  reset_activity_snapshot

  while IFS= read -r repo_root; do
    if [ ! -e "$repo_root" ]; then
      if [ "$using_cached_repo_list" -eq 1 ]; then
        log_error "cached repository path is no longer available; rebuilding repository cache"
        return 2
      fi
      invalid_repository_count=$((invalid_repository_count + 1))
      continue
    fi

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
      invalid_repository_count=$((invalid_repository_count + 1))
      continue
    fi

    if ! path_is_within_authorized_roots "$git_dir"; then
      if [ "$using_cached_repo_list" -eq 1 ]; then
        log_error "cached repository metadata escaped authorized roots; rebuilding repository cache"
        return 2
      fi
      invalid_repository_count=$((invalid_repository_count + 1))
      log_error "resolved git metadata path escaped authorized roots; skipping one repository"
      continue
    fi

    if ! validate_git_metadata_layout "$git_dir"; then
      if [ "$using_cached_repo_list" -eq 1 ]; then
        log_error "cached repository metadata is no longer valid; rebuilding repository cache"
        return 2
      fi
      invalid_repository_count=$((invalid_repository_count + 1))
      log_error "resolved git metadata is incomplete for one repository; skipping one repository"
      continue
    fi

    repository_count=$((repository_count + 1))
    reflog_path="$git_dir/logs/HEAD"
    if [ ! -e "$reflog_path" ]; then
      if [ "$using_cached_repo_list" -eq 1 ]; then
        log_error "cached repository reflog is no longer available; rebuilding repository cache"
        return 2
      fi
      continue
    fi
    if [ ! -r "$reflog_path" ]; then
      continue
    fi
    if [ ! -f "$reflog_path" ]; then
      readable_reflog_repo_count=$((readable_reflog_repo_count + 1))
      failed_reflog_repo_count=$((failed_reflog_repo_count + 1))
      log_error "git reflog path is not a regular file for one repository; preserving previous shared data"
      continue
    fi

    readable_reflog_repo_count=$((readable_reflog_repo_count + 1))
    repo_count=0
    repo_latest_timestamp=""
    repo_focus_blocks=""
    trap - ERR
    if reflog_mtime="$(read_reflog_mtime "$reflog_path")"; then
      read_reflog_mtime_exit_code=0
    else
      read_reflog_mtime_exit_code="$?"
    fi
    enable_error_trap
    if [ "$read_reflog_mtime_exit_code" -ne 0 ]; then
      failed_reflog_repo_count=$((failed_reflog_repo_count + 1))
      log_error "failed to read git reflog metadata for one repository; preserving previous shared data"
      continue
    fi

    cached_repo_stats="$(awk -F '\t' -v repo_root="$repo_root" '$1 == repo_root { print; exit }' "$repo_stats_cache_file")"
    if [ -n "$cached_repo_stats" ]; then
      cache_hit_count=$((cache_hit_count + 1))
      IFS=$'\t' read -r cached_repo_root cached_git_dir cached_reflog_path cached_day cached_reflog_mtime cached_repo_count cached_repo_latest_timestamp cached_repo_focus_blocks <<< "$cached_repo_stats"

      if [ "$cached_repo_root" = "$repo_root" ] &&
         [ "$cached_git_dir" = "$git_dir" ] &&
         [ "$cached_reflog_path" = "$reflog_path" ] &&
         [ "$cached_day" = "$TODAY" ] &&
         [ "$cached_reflog_mtime" = "$reflog_mtime" ]; then
        successful_reflog_repo_count=$((successful_reflog_repo_count + 1))
        reflog_unchanged_skip_count=$((reflog_unchanged_skip_count + 1))
        repo_count="$cached_repo_count"
        if [ "$cached_repo_latest_timestamp" != "$EMPTY_CACHE_VALUE" ]; then
          repo_latest_timestamp="$cached_repo_latest_timestamp"
        fi
        append_cached_focus_blocks "$cached_repo_focus_blocks"
        write_repository_stats_entry "$repo_root" "$git_dir" "$reflog_path" "$reflog_mtime" "$repo_count" "$repo_latest_timestamp" "$cached_repo_focus_blocks"
        printf '%s\n' "$repo_root" >> "$validated_repo_list_file"
        total_count=$((total_count + repo_count))

        if [ -n "$repo_latest_timestamp" ] && { [ -z "$latest_activity_timestamp" ] || [[ "$repo_latest_timestamp" > "$latest_activity_timestamp" ]]; }; then
          latest_activity_timestamp="$repo_latest_timestamp"
          recent_project_name="$(basename "$repo_root")"
        fi
        continue
      fi
    fi

    recomputed_repository_count=$((recomputed_repository_count + 1))
    : > "$repo_reflog_file"
    if ! "$PERL_BIN" -MPOSIX=strftime -e '
        use strict;
        use warnings;

        my $today = shift @ARGV;
        my $count = 0;
        my $latest_epoch = 0;

        while (my $line = <>) {
            chomp $line;
            my ($metadata, $message) = split /\t/, $line, 2;
            next unless defined $message;
            next unless $message =~ /^commit( \(.+\))?:|^merge(\s+[^:]*)?:/;

            my @parts = split / /, $metadata;
            next if @parts < 2;

            my $epoch = $parts[-2];
            next unless defined $epoch && $epoch =~ /^\d+$/;

            my @local = localtime($epoch);
            my $day_identifier = sprintf("%04d-%02d-%02d", $local[5] + 1900, $local[4] + 1, $local[3]);
            next unless $day_identifier eq $today;

            $count++;
            $latest_epoch = $epoch if $epoch > $latest_epoch;

            my $block_minute = $local[1] >= 30 ? 30 : 0;
            printf "BLOCK\t%sT%02d:%02d\n", $day_identifier, $local[2], $block_minute;
        }

        printf "COUNT\t%d\n", $count;
        if ($latest_epoch > 0) {
            printf "LATEST\t%s\n", strftime("%Y-%m-%dT%H:%M:%S%z", localtime($latest_epoch));
        }
      ' "$TODAY" "$reflog_path" > "$repo_reflog_file"; then
      failed_reflog_repo_count=$((failed_reflog_repo_count + 1))
      log_error "failed to parse git reflog for one repository; preserving previous shared data"
      continue
    fi
    successful_reflog_repo_count=$((successful_reflog_repo_count + 1))

    while IFS=$'\t' read -r record_kind record_value; do
      case "$record_kind" in
        COUNT)
          repo_count="$record_value"
          ;;
        BLOCK)
          printf '%s\n' "$record_value" >> "$focus_block_list_file"
          ;;
        LATEST)
          repo_latest_timestamp="$record_value"
          ;;
      esac
    done < "$repo_reflog_file"

    repo_focus_blocks="$(awk -F '\t' '$1 == "BLOCK" { print $2 }' "$repo_reflog_file" | sort -u | paste -sd, -)"
    write_repository_stats_entry "$repo_root" "$git_dir" "$reflog_path" "$reflog_mtime" "$repo_count" "$repo_latest_timestamp" "$repo_focus_blocks"
    printf '%s\n' "$repo_root" >> "$validated_repo_list_file"

    total_count=$((total_count + repo_count))

    if [ -n "$repo_latest_timestamp" ] && { [ -z "$latest_activity_timestamp" ] || [[ "$repo_latest_timestamp" > "$latest_activity_timestamp" ]]; }; then
      latest_activity_timestamp="$repo_latest_timestamp"
      recent_project_name="$(basename "$repo_root")"
    fi
  done < "$repo_list_file"
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

  if ! value="$(/usr/libexec/PlistBuddy -c "Print :$key" "$APP_GROUP_PREFERENCES_PLIST" 2>/dev/null)"; then
    return 1
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

  while ! mkdir "$SNAPSHOT_WRITE_LOCK" 2>/dev/null; do
    attempt=$((attempt + 1))
    if [ "$attempt" -ge 200 ]; then
      log_error "timed out waiting for shared snapshot write lock"
      return 1
    fi
    sleep 0.01
  done

  snapshot_write_lock_acquired=1
}

write_trusted_snapshot_if_newer() {
  local encoded_project_name
  local current_snapshot=""
  local current_revision=""
  local current_payload=""
  local proposed_payload

  encoded_project_name="$(printf '%s' "$recent_project_name" | /usr/bin/base64 | tr -d '\n')"
  proposed_payload="$TODAY"$'\t'"$focus_block_count"$'\t'"$total_count"$'\t'"$encoded_project_name"

  if current_snapshot="$(read_plist_value "$TRUSTED_SNAPSHOT_KEY")"; then
    current_revision="${current_snapshot%%$'\t'*}"
    if [[ "$current_snapshot" == *$'\t'* ]]; then
      current_payload="${current_snapshot#*$'\t'}"
    fi

    if [ "$current_payload" = "$proposed_payload" ]; then
      return
    fi

    if [[ "$current_revision" =~ ^[0-9]+$ ]] &&
       [ "$current_revision" -ge "$REFRESH_REVISION" ]; then
      trusted_snapshot_stale=1
      echo "TinyBuddy git shared snapshot is newer; skipped stale write"
      return
    fi
  fi

  shared_data_rewritten=1
  write_plist_string "$TRUSTED_SNAPSHOT_KEY" "$REFRESH_REVISION"$'\t'"$proposed_payload"
}

handle_error() {
  local exit_code="$1"
  local line_number="$2"
  log_error "failed with exit code $exit_code at line $line_number"
  exit "$exit_code"
}

enable_error_trap() {
  trap 'handle_error $? $LINENO' ERR
}

trap cleanup EXIT
enable_error_trap

if ! command -v git >/dev/null 2>&1; then
  log_error "git executable not found in PATH=$PATH"
  exit 127
fi

# Avoid here-strings here because the signed sandboxed app can reject bash's
# implicit temp file creation for `<<<`, leaving the authorized root list empty.
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
mv "$valid_scan_roots_file" "$scan_roots_file"

if [ ! -s "$scan_roots_file" ]; then
  log_error "no authorized git scan roots supplied; skipping refresh"
  emit_refresh_metrics
  exit 0
fi

had_cached_repository_list=0
if [ -s "$CACHE_REPO_LIST_FILE" ]; then
  had_cached_repository_list=1
fi

using_cached_repo_list=0
if cache_matches_current_roots; then
  load_cached_repository_list
  load_cached_repository_stats
  using_cached_repo_list=1
else
  refresh_repository_list_from_scan
  if [ "$repository_scan_failed" -eq 1 ]; then
    log_error "repository scan failed; preserving previous shared data"
    emit_refresh_metrics
    exit 1
  fi
  if [ "$had_cached_repository_list" -eq 1 ] && [ ! -s "$repo_list_file" ]; then
    log_error "repository rescan found no repositories; preserving previous shared data"
    emit_refresh_metrics
    exit 1
  fi
  write_repository_cache
  load_cached_repository_stats
fi

process_repository_list "$using_cached_repo_list" || process_result="$?"
if [ "${process_result:-0}" -ne 0 ]; then
  if [ "$process_result" -ne 2 ]; then
    exit 1
  fi

  refresh_repository_list_from_scan
  if [ "$repository_scan_failed" -eq 0 ] && [ -s "$repo_list_file" ]; then
    process_repository_list 0
    if [ "$failed_reflog_repo_count" -eq 0 ] && [ -s "$validated_repo_list_file" ]; then
      cp "$validated_repo_list_file" "$repo_list_file"
      write_repository_cache
      write_repository_stats_cache
    fi
  fi
  emit_runtime_diagnostics_once
  log_error "cached repository paths are temporarily unavailable; preserving previous shared data"
  emit_find_stderr_sample
  emit_refresh_metrics
  exit 1
fi

if [ "$had_cached_repository_list" -eq 1 ] && [ "$invalid_repository_count" -gt 0 ]; then
  emit_runtime_diagnostics_once
  log_error "one or more previously known repositories are invalid; preserving previous shared data"
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
  emit_refresh_metrics
  exit 1
fi

if [ "$failed_reflog_repo_count" -gt 0 ]; then
  emit_runtime_diagnostics_once
  log_error "failed to parse one or more readable git reflogs; preserving previous shared data"
  emit_refresh_metrics
  exit 1
fi

/bin/mkdir -p "$APP_GROUP_PREFERENCES_DIR"
if [ ! -f "$APP_GROUP_PREFERENCES_PLIST" ]; then
  /usr/bin/plutil -create xml1 "$APP_GROUP_PREFERENCES_PLIST"
fi

acquire_snapshot_write_lock
write_trusted_snapshot_if_newer
if [ "$trusted_snapshot_stale" -eq 0 ]; then
  write_plist_string_if_changed "$DAY_KEY" "$TODAY"
  write_plist_integer_if_changed "$COUNT_KEY" "$total_count"
  write_plist_string_if_changed "$FOCUS_BLOCK_DAY_KEY" "$TODAY"
  write_plist_integer_if_changed "$FOCUS_BLOCK_COUNT_KEY" "$focus_block_count"
  write_plist_string_if_changed "$RECENT_PROJECT_DAY_KEY" "$TODAY"
  write_plist_string_if_changed "$RECENT_PROJECT_NAME_KEY" "$recent_project_name"
fi
write_repository_stats_cache

if [ "$shared_data_rewritten" -eq 0 ]; then
  echo "TinyBuddy git shared data unchanged; skipped plist rewrite"
fi

emit_refresh_metrics
echo "Updated TinyBuddy git completion count: $total_count"
echo "Updated TinyBuddy git focus block count: $focus_block_count"
echo "Updated TinyBuddy recent project name: ${recent_project_name:-<none>}"
