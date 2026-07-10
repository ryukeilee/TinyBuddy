# Companion Hub Activity Refresh Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use `executing-plans` to implement this plan task-by-task. Repository instructions prohibit recursive delegation; do not spawn subagents. Also use `systematic-debugging`, `test-driven-development`, `tinybuddy-verification`, and `verification-before-completion` as applicable.

**Goal:** Make Companion Hub publish correct same-day focus, completion, and recent-project data immediately after a successful activity refresh and restore the same state across view/lifecycle/app reconstruction.

**Architecture:** Keep the script-generated trusted activity snapshot as source of truth and the combined snapshot as the app/widget presentation checkpoint. Make date evaluation injectable and consistent, publish a dedicated notification only after a combined activity slice is committed, and have `PetViewModel` reload through its existing snapshot publication path.

**Tech Stack:** Swift 5.9, SwiftUI, Combine/`ObservableObject`, Foundation notifications and calendars, XCTest, Swift Package Manager.

---

## File map

- Modify `Sources/TinyBuddyCore/GitTodayActivitySnapshot.swift`: inject date/calendar context into aggregate trusted/fallback reads.
- Modify `Sources/TinyBuddy/GitActivityRefreshCoordinator.swift`: define and post the committed-activity notification after successful persistence.
- Modify `Sources/TinyBuddy/PetViewModel.swift`: observe the committed-activity notification and republish persisted state.
- Modify `Tests/TinyBuddyCoreTests/GitTodayActivityStoreTests.swift`: cover controlled cross-day reads, trusted writes, empty state, and reconstruction.
- Modify `Tests/TinyBuddyAppTests/GitActivityRefreshCoordinatorTests.swift`: cover notification timing, complete activity slices, empty project, and foreground refresh.
- Modify `Tests/TinyBuddyAppTests/PetViewModelTests.swift`: cover immediate automatic publication and reconstruction/restart recovery.

### Task 1: Establish deterministic date aggregation

- [ ] Add failing tests in `Tests/TinyBuddyCoreTests/GitTodayActivityStoreTests.swift` using a fixed Gregorian calendar and mutable date closure. Prove that a trusted non-zero snapshot is returned on its day, becomes an empty/fallback-today result after midnight, and a new-day trusted write restores all three fields.
- [ ] Run the narrow test and capture the expected failure caused by `GitTodayActivityStore.todayIdentifier()` still using ambient time:

```bash
swift test --filter GitTodayActivityStoreTests
```

- [ ] Extend `GitTodayActivityStore` with stored dependencies and defaults preserving production callers:

```swift
private let calendar: Calendar
private let dateProvider: () -> Date

public init(
    trustedSnapshotStore: GitTodayActivityTrustedSnapshotStore,
    focusBlockStore: GitTodayFocusBlockCountStore,
    commitCountStore: GitTodayCommitCountStore,
    recentProjectStore: GitTodayRecentProjectStore,
    calendar: Calendar = .current,
    dateProvider: @escaping () -> Date = Date.init
) { /* assign every dependency */ }

private func todayIdentifier() -> String {
    let components = calendar.dateComponents([.year, .month, .day], from: dateProvider())
    return String(format: "%04d-%02d-%02d", components.year!, components.month!, components.day!)
}
```

Use the repository's existing day-identifier formatting helper if one already exists rather than duplicating it. Ensure the convenience initializer supplies the same date/calendar context to all default stores where their APIs permit it.

- [ ] Rerun `swift test --filter GitTodayActivityStoreTests`; expected result: all selected tests pass.

### Task 2: Publish only committed activity changes

- [ ] Add failing coordinator tests proving: a successful `updateActivitySlice` posts exactly one dedicated notification after the persisted snapshot is readable; a script/read/persistence failure posts none; a valid `recentProjectName == nil` is committed as an explicit empty project without fabricating a name; a foreground-triggered refresh follows the same path.
- [ ] Run:

```bash
swift test --filter GitActivityRefreshCoordinatorTests
```

Expected before implementation: notification assertions fail because no committed-activity notification exists.

- [ ] In `Sources/TinyBuddy/GitActivityRefreshCoordinator.swift`, define a distinct notification alongside existing names:

```swift
extension Notification.Name {
    static let gitActivitySnapshotDidChange = Notification.Name("TinyBuddy.gitActivitySnapshotDidChange")
}
```

- [ ] In the main-thread success path, post only after `combinedSnapshotStore.updateActivitySlice(...)` has produced the accepted/persisted presentation checkpoint. Do not tie publication to Widget reload policy:

```swift
statusNotificationCenter.post(name: .gitActivitySnapshotDidChange, object: nil)
```

Do not post on script failure, unavailable counts, rejected/stale revision, or persistence failure. Preserve an existing valid same-day project on failure, while allowing a successful complete snapshot to carry `nil` as the legitimate empty-project state.

- [ ] Rerun `swift test --filter GitActivityRefreshCoordinatorTests`; expected result: all selected tests pass.

### Task 3: Republish the committed snapshot in Companion Hub

- [ ] Add a failing `PetViewModelTests` case that constructs the model with an isolated notification center and initial zero/empty state, writes a non-zero combined activity slice with project `TinyBuddy`, posts `.gitActivitySnapshotDidChange`, drains the main actor, and asserts `hudPresentation.focusCount`, `completionCount`, and recent-project display state update without `.gitActivityRefreshStatusDidChange`, Widget reload, app activation, or model reconstruction.
- [ ] Add tests that reconstruct `PetViewModel` from the same isolated persistence after the update, and that post the app-active lifecycle notification after replacing the trusted snapshot. Assert all three fields remain consistent. Include a legitimate empty-project case.
- [ ] Run:

```bash
swift test --filter PetViewModelTests
```

Expected before implementation: the automatic publication test remains on its initial values.

- [ ] Register an observer in `PetViewModel.init` using the injected notification center:

```swift
notificationCenter.addObserver(
    forName: .gitActivitySnapshotDidChange,
    object: nil,
    queue: .main
) { [weak self] _ in
    self?.reloadPublishedSnapshot()
}
```

Route the callback through the same existing `publishAndLoadCombinedSnapshot` path used at initialization/activation, retain observer tokens according to the file's existing lifecycle pattern, and keep all `@Published` mutations on `@MainActor`. Do not add timers, view IDs, or `objectWillChange.send()` workarounds.

- [ ] Rerun `swift test --filter PetViewModelTests`; expected result: all selected tests pass.

### Task 4: Integrated regression and completion audit

- [ ] Add or refine a focused integration-style app test spanning trusted activity write → coordinator refresh → committed notification → `PetViewModel` publication. Assert non-zero focus/completion and recent project, then reconstruct stores/model to simulate restart and assert the same snapshot.
- [ ] Run the three affected suites together and address only failures attributable to this change:

```bash
swift test --filter GitTodayActivityStoreTests
swift test --filter GitActivityRefreshCoordinatorTests
swift test --filter PetViewModelTests
```

- [ ] Run the repository-required complete suite once:

```bash
swift test
```

Expected: exit 0 with all tests passing.

- [ ] Inspect the final diff and safety checks:

```bash
git diff --check
git status --short
rg -n "Timer|scheduledTimer|objectWillChange\.send|\.id\(" Sources/TinyBuddy Sources/TinyBuddyCore
```

Confirm no new polling, hard-coded activity values, forced redraw, signing changes, generated files, or unrelated edits. Preserve the user-owned design and plan documents. Do not commit or push without explicit authorization.

- [ ] Return an evidence packet containing result, changed files, narrow diff summary, exact test outcomes, remaining risks/manual checks, and final status. If runtime UI behavior cannot be automated, identify the smallest manual confirmation point without claiming it was performed.
