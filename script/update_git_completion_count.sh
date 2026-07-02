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
SCAN_ROOTS="${TINYBUDDY_GIT_SCAN_ROOTS:-${TINYBUDDY_GIT_SCAN_ROOT:-}}"
TODAY="$(date +%F)"
PATH="/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin:${PATH:-}"

total_count=0
latest_activity_timestamp=""
recent_project_name=""
scan_roots_file="$(mktemp)"
valid_scan_roots_file=""
repo_list_file="$(mktemp)"
repo_scan_file="$(mktemp)"
repo_reflog_file="$(mktemp)"
repo_git_paths_file="$(mktemp)"
find_stderr_file="$(mktemp)"
focus_block_list_file="$(mktemp)"
diagnostics_emitted=0

log_error() {
  echo "TinyBuddy refresh script: $*" >&2
}

cleanup() {
  rm -f "$scan_roots_file" "$valid_scan_roots_file" "$repo_list_file" "$repo_scan_file" "$repo_reflog_file" "$repo_git_paths_file" "$find_stderr_file" "$focus_block_list_file"
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

resolve_git_dir() {
  local repo_root="$1"
  local dot_git_path="$repo_root/.git"
  local gitdir_line
  local git_dir

  if [ -d "$dot_git_path" ]; then
    (
      cd "$dot_git_path" 2>/dev/null && pwd -P
    )
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

  (
    cd "$git_dir" 2>/dev/null && pwd -P
  )
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

handle_error() {
  local exit_code="$1"
  local line_number="$2"
  log_error "failed with exit code $exit_code at line $line_number"
  exit "$exit_code"
}

trap cleanup EXIT
trap 'handle_error $? $LINENO' ERR

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
  exit 0
fi

find_exit_code=0
while IFS= read -r scan_root; do
  if [ ! -d "$scan_root" ]; then
    log_error "authorized git scan root is not a readable directory; skipping one root"
    continue
  fi

  find "$scan_root" \
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
    \( -name .git -type d -o -name .git -type f \) -print0 >> "$repo_git_paths_file" 2>> "$find_stderr_file" || find_exit_code="$?"
done < "$scan_roots_file"

while IFS= read -r -d '' git_path; do
  dirname "$git_path"
done < "$repo_git_paths_file" > "$repo_scan_file"

if [ "$find_exit_code" -ne 0 ]; then
  emit_runtime_diagnostics_once
  log_error "repository scan encountered inaccessible paths under authorized roots (find exit: $find_exit_code); continuing with readable results"
  emit_find_stderr_sample
fi

sort -u "$repo_scan_file" > "$repo_list_file"

while IFS= read -r repo_root; do
  git_dir="$(resolve_git_dir "$repo_root")" || continue
  if ! path_is_within_authorized_roots "$git_dir"; then
    log_error "resolved git metadata path escaped authorized roots; skipping one repository"
    continue
  fi

  reflog_path="$git_dir/logs/HEAD"
  if [ ! -r "$reflog_path" ]; then
    continue
  fi

  repo_count=0
  repo_latest_timestamp=""
  : > "$repo_reflog_file"
  git --git-dir="$git_dir" --work-tree="$repo_root" \
    reflog show HEAD --date=iso-strict-local --format='%gd%x09%gs' 2>/dev/null | awk -F '\t' -v today="$TODAY" '
      $1 ~ ("^HEAD@\\{" today "T") && $2 ~ /^commit( \(.+\))?:|^merge([[:space:]][^:]*)?:/ {
        count++
        timestamp = $1
        sub(/^HEAD@\{/, "", timestamp)
        sub(/\}$/, "", timestamp)
        if (timestamp > latest) {
          latest = timestamp
        }
        split(timestamp, parts, "T")
        split(parts[2], timeParts, ":")
        hour = timeParts[1] + 0
        minute = timeParts[2] + 0
        blockMinute = (minute >= 30) ? 30 : 0
        printf "BLOCK\t%sT%02d:%02d\n", today, hour, blockMinute
      }
      END {
        printf "COUNT\t%d\n", count + 0
        if (latest != "") {
          printf "LATEST\t%s\n", latest
        }
      }
    ' > "$repo_reflog_file"

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

  total_count=$((total_count + repo_count))

  if [ -n "$repo_latest_timestamp" ] && { [ -z "$latest_activity_timestamp" ] || [ "$repo_latest_timestamp" > "$latest_activity_timestamp" ]; }; then
    latest_activity_timestamp="$repo_latest_timestamp"
    recent_project_name="$(basename "$repo_root")"
  fi
done < "$repo_list_file"

focus_block_count="$(sort -u "$focus_block_list_file" | awk 'END { print NR + 0 }')"

if [ ! -s "$repo_list_file" ]; then
  emit_runtime_diagnostics_once
  log_error "no git repositories discovered under authorized roots"
  emit_find_stderr_sample
fi

/bin/mkdir -p "$APP_GROUP_PREFERENCES_DIR"
if [ ! -f "$APP_GROUP_PREFERENCES_PLIST" ]; then
  /usr/bin/plutil -create xml1 "$APP_GROUP_PREFERENCES_PLIST"
fi

write_plist_string "$DAY_KEY" "$TODAY"
write_plist_integer "$COUNT_KEY" "$total_count"
write_plist_string "$FOCUS_BLOCK_DAY_KEY" "$TODAY"
write_plist_integer "$FOCUS_BLOCK_COUNT_KEY" "$focus_block_count"
write_plist_string "$RECENT_PROJECT_DAY_KEY" "$TODAY"
write_plist_string "$RECENT_PROJECT_NAME_KEY" "$recent_project_name"

echo "Updated TinyBuddy git completion count: $total_count"
echo "Updated TinyBuddy git focus block count: $focus_block_count"
echo "Updated TinyBuddy recent project name: ${recent_project_name:-<none>}"
