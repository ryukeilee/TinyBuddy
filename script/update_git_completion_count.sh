#!/usr/bin/env bash
set -euo pipefail

APP_GROUP_ID="group.com.ryukeili.TinyBuddy"
APP_GROUP_CONTAINER="$HOME/Library/Group Containers/$APP_GROUP_ID"
APP_GROUP_PREFERENCES_DIR="$APP_GROUP_CONTAINER/Library/Preferences"
APP_GROUP_PREFERENCES_PLIST="$APP_GROUP_PREFERENCES_DIR/$APP_GROUP_ID.plist"
DAY_KEY="tinybuddy.gitTodayCommitCount.dayIdentifier"
COUNT_KEY="tinybuddy.gitTodayCommitCount.count"
SCAN_ROOT="${TINYBUDDY_GIT_SCAN_ROOT:-$HOME}"
TODAY="$(date +%F)"

total_count=0
repo_list_file="$(mktemp)"
trap 'rm -f "$repo_list_file"' EXIT

while IFS= read -r -d '' git_path; do
  dirname "$git_path"
done < <(
  find "$SCAN_ROOT" \
    \( \
      -path "$HOME/Library" -o \
      -path "$HOME/.Trash" -o \
      -path "$HOME/.cache" -o \
      -path "$HOME/Movies" -o \
      -path "$HOME/Music" -o \
      -path "$HOME/Pictures" -o \
      -path '*/node_modules' -o \
      -path '*/.build' -o \
      -path '*/DerivedData' \
    \) -prune -o \
    \( -name .git -type d -o -name .git -type f \) -print0 2>/dev/null
) | sort -u > "$repo_list_file"

while IFS= read -r repo_root; do
  if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    continue
  fi

  repo_count="$(
    git -C "$repo_root" \
      reflog \
      show \
      HEAD \
      --date=iso-strict-local \
      --format='%gd%x09%gs' \
      2>/dev/null | awk -F '\t' -v today="$TODAY" '
        $1 ~ ("^HEAD@\\{" today "T") && $2 ~ /^commit( \(.+\))?:|^merge([[:space:]][^:]*)?:/ {
          count++
        }
        END {
          print count + 0
        }
      '
  )"
  total_count=$((total_count + repo_count))
done < "$repo_list_file"

/bin/mkdir -p "$APP_GROUP_PREFERENCES_DIR"
/usr/bin/defaults write "$APP_GROUP_PREFERENCES_PLIST" "$DAY_KEY" -string "$TODAY"
/usr/bin/defaults write "$APP_GROUP_PREFERENCES_PLIST" "$COUNT_KEY" -int "$total_count"

echo "Updated TinyBuddy git completion count: $total_count"
