#!/usr/bin/env bash
# Measures only the resident menu projection, with no installed-app mutation.
# --baseline exports a revision and instruments its original repeating timer.
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [ "$#" -eq 0 ]; then
    cd "$ROOT_DIR"
    TINYBUDDY_MENU_BENCHMARK=1 ./script/swiftpm.sh test --filter ManualFocusMenuBarResourceTests
elif [ "$#" -eq 2 ] && [ "$1" = --baseline ]; then
    BENCHMARK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/TinyBuddyMenuBaseline.XXXXXX")"
    trap 'rm -rf "$BENCHMARK_DIR"' EXIT
    git -C "$ROOT_DIR" archive "$2" | tar -x -C "$BENCHMARK_DIR"
    cp "$ROOT_DIR/Tests/TinyBuddyAppTests/ManualFocusMenuBarResourceTests.swift" \
        "$BENCHMARK_DIR/Tests/TinyBuddyAppTests/"
    python3 - "$BENCHMARK_DIR/Sources/TinyBuddy/ManualFocusMenuBarController.swift" <<'PY'
import pathlib
import sys
path = pathlib.Path(sys.argv[1])
source = path.read_text()
assert 'scheduleRefresh' not in source, 'Baseline must use the original 2-second repeating timer'
source = source.replace(
    '    private var engine: FocusSessionEngine?',
    '    private let scheduleRefresh: (TimeInterval, Bool, @escaping @MainActor () -> Void) -> Timer\n    private var engine: FocusSessionEngine?',
    1,
)
source = source.replace(
    '        registeredProjectsProvider: @escaping () -> [TinyBuddyProject] = { [] }',
    '''        registeredProjectsProvider: @escaping () -> [TinyBuddyProject] = { [] },
        scheduleRefresh: @escaping (TimeInterval, Bool, @escaping @MainActor () -> Void) -> Timer = { interval, repeats, action in
            Timer.scheduledTimer(withTimeInterval: interval, repeats: repeats) { _ in
                MainActor.assumeIsolated { action() }
            }
        }''',
    1,
)
source = source.replace('        self.recentProjectNameProvider = recentProjectNameProvider',
                        '        self.scheduleRefresh = scheduleRefresh\n        self.recentProjectNameProvider = recentProjectNameProvider', 1)
original = '''        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
            }
        }'''
assert original in source, 'Baseline timer layout changed; do not silently measure a different path'
source = source.replace(original, '''        refreshTimer = scheduleRefresh(2.0, true) { [weak self] in
            self?.refresh()
        }''', 1)
path.write_text(source)
PY
    cd "$BENCHMARK_DIR"
    TINYBUDDY_MENU_BENCHMARK=1 ./script/swiftpm.sh test --filter ManualFocusMenuBarResourceTests
else
    echo "usage: script/benchmark_menu_refresh.sh [--baseline git-ref]" >&2
    exit 2
fi
