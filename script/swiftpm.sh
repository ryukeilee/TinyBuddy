#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/script/local_build_env.sh"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <swift-subcommand> [args...]" >&2
  exit 2
fi

cd "$ROOT_DIR"

exec swift "$@" \
  --disable-sandbox \
  --scratch-path "$TINYBUDDY_SWIFTPM_SCRATCH_PATH" \
  --cache-path "$TINYBUDDY_SWIFTPM_CACHE_PATH" \
  --config-path "$TINYBUDDY_SWIFTPM_CONFIG_PATH" \
  --security-path "$TINYBUDDY_SWIFTPM_SECURITY_PATH" \
  --manifest-cache local
