import SwiftUI
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

@MainActor
final class PetViewRenderingTests: XCTestCase {
    func testHUDRendersAtStableSizeAcrossRepresentativeAccessibilityEnvironments() throws {
        let viewModel = makeViewModel()
        XCTAssertEqual(viewModel.developmentInterruptionSnapshot?.repositoryName, "TinyBuddy")
        let cases: [(name: String, colorScheme: ColorScheme, dynamicTypeSize: DynamicTypeSize)] = [
            ("dark-standard", .dark, .large),
            ("light-accessibility", .light, .accessibility1),
            ("dark-maximum-accessibility", .dark, .accessibility5)
        ]

        for testCase in cases {
            let content = PetView(viewModel: viewModel)
                .environment(\.colorScheme, testCase.colorScheme)
                .environment(\.dynamicTypeSize, testCase.dynamicTypeSize)
            let renderer = ImageRenderer(content: content)
            renderer.proposedSize = ProposedViewSize(width: 284, height: 520)
            renderer.scale = 1

            let image: CGImage = try XCTUnwrap(renderer.cgImage, testCase.name)
            XCTAssertEqual(image.width, 284, testCase.name)
            XCTAssertEqual(image.height, 520, testCase.name)
            let imageData = try XCTUnwrap(image.dataProvider?.data, testCase.name)
            let byteCount = CFDataGetLength(imageData)
            let bytes = try XCTUnwrap(CFDataGetBytePtr(imageData), testCase.name)
            XCTAssertGreaterThan(byteCount, 0, testCase.name)
            XCTAssertTrue(
                (1..<byteCount).contains { bytes[$0] != bytes[0] },
                "\(testCase.name) rendered a uniform image"
            )
        }
    }

    func testHUDRendersResumeCardActionFormsAcrossColorSchemes() throws {
        let project = TinyBuddyProject(
            id: TinyBuddyProjectID(rawValue: "proj-resume"),
            kind: .gitRepository,
            displayName: "TinyBuddy",
            repositoryFingerprint: "fingerprint",
            state: .active
        )
        let calendar = makeCalendar()
        let today = makeDate()
        let engine = FocusSessionEngine(
            clock: RenderingFakeClock(today),
            persisting: RenderingMemoryStore(),
            config: FocusSessionConfiguration(confirmationMinimumActiveDuration: 0),
            dayIdentifier: { renderingDayIdentifier(for: $0) },
            nextDayBoundary: { date in
                calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date))
            }
        )
        let availableViewModel = makeViewModel(
            registeredProjectsProvider: { [project] }
        )
        XCTAssertEqual(
            availableViewModel.developmentInterruptionResumeState,
            .available(project: project)
        )

        _ = engine.userActivity(
            in: FocusProjectContext(key: project.id.rawValue, displayName: project.displayName),
            at: today
        )
        let inProgressViewModel = makeViewModel(
            registeredProjectsProvider: { [project] },
            focusSessionEngine: engine
        )
        XCTAssertEqual(
            inProgressViewModel.developmentInterruptionResumeState,
            .inProgress(project: project, status: .active)
        )

        let cases: [(name: String, viewModel: PetViewModel)] = [
            ("available", availableViewModel),
            ("inProgress", inProgressViewModel)
        ]
        for entry in cases {
            for scheme in [ColorScheme.dark, ColorScheme.light] {
                let content = PetView(viewModel: entry.viewModel)
                    .environment(\.colorScheme, scheme)
                let renderer = ImageRenderer(content: content)
                renderer.proposedSize = ProposedViewSize(width: 284, height: 520)
                renderer.scale = 1

                let image: CGImage = try XCTUnwrap(
                    renderer.cgImage,
                    "\(entry.name)-\(scheme) failed to render"
                )
                XCTAssertEqual(image.width, 284, entry.name)
                XCTAssertEqual(image.height, 520, entry.name)
                let imageData = try XCTUnwrap(image.dataProvider?.data, entry.name)
                let byteCount = CFDataGetLength(imageData)
                let bytes = try XCTUnwrap(CFDataGetBytePtr(imageData), entry.name)
                XCTAssertGreaterThan(byteCount, 0, entry.name)
                XCTAssertTrue(
                    (1..<byteCount).contains { bytes[$0] != bytes[0] },
                    "\(entry.name)-\(scheme) rendered a uniform image"
                )
            }
        }
    }

    private func makeViewModel(
        registeredProjectsProvider: @escaping () -> [TinyBuddyProject] = { [] },
        focusSessionEngine: FocusSessionEngine? = nil
    ) -> PetViewModel {
        let suiteName = "TinyBuddyPetViewRenderingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        let timeZone = TimeZone(secondsFromGMT: 0)!
        let locale = Locale(identifier: "zh_CN")
        let now = makeDate()
        let timeEnvironment = TinyBuddyTimeEnvironment.fixed(
            now: now,
            timeZone: timeZone,
            locale: locale
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = locale
        let store = DailyStatsStore(
            userDefaults: defaults,
            calendar: calendar,
            dateProvider: { now }
        )
        let activityStore = GitTodayActivityStore(
            focusBlockCountStore: GitTodayFocusBlockCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { now },
                sharedFallbacksEnabled: false
            ),
            commitCountStore: GitTodayCommitCountStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { now },
                sharedFallbacksEnabled: false
            ),
            recentProjectStore: GitTodayRecentProjectStore(
                userDefaults: defaults,
                calendar: calendar,
                dateProvider: { now },
                sharedFallbacksEnabled: false
            ),
            timeEnvironment: timeEnvironment,
            timeScopeTokenProvider: { nil }
        )
        let activity = GitTodayActivitySnapshot(
            focusBlockCount: 2,
            commitCount: 5,
            recentProjectName: "TinyBuddyAccessibilityRendering"
        )
        let combinedSnapshotStore = store.makeCombinedSnapshotStore()
        _ = combinedSnapshotStore.updateActivitySlice(
            activity,
            fallbackSnapshot: store.loadSnapshot()
        )
        let refreshStatusStore = GitActivityRefreshStatusStore(
            userDefaults: defaults,
            timeEnvironment: timeEnvironment
        )
        refreshStatusStore.save(GitActivityRefreshStatus(
            refreshedAt: now,
            trigger: .launch,
            outcome: .succeeded,
            metrics: GitActivityRefreshMetrics(
                authorizedRootCount: 1,
                repositoryCount: 1
            )
        ))
        let onboardingStore = TinyBuddyOnboardingStore(
            userDefaults: defaults,
            sharedDefaults: defaults
        )
        _ = onboardingStore.markCompleted()
        let encode: (String) -> String = { Data($0.utf8).base64EncodedString() }
        defaults.set([
            "v1",
            encode("fingerprint"),
            encode("TinyBuddy"),
            encode("feature/resume"),
            "1", "2", "1", "0",
            encode("abc1234"),
            encode("Add interruption recovery"),
            String(Int(now.timeIntervalSince1970) - 7_200),
            String(Int(now.timeIntervalSince1970) - 3_600),
            String(Int(now.timeIntervalSince1970))
        ].joined(separator: "\t"), forKey: DevelopmentInterruptionSnapshotStore.Key.snapshot)

        let viewModel = PetViewModel(
            onboardingStore: onboardingStore,
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: refreshStatusStore,
            developmentInterruptionStore: DevelopmentInterruptionSnapshotStore(
                userDefaults: defaults
            ),
            notificationCenter: NotificationCenter(),
            timeEnvironment: timeEnvironment,
            registeredProjectsProvider: registeredProjectsProvider,
            widgetReloader: {}
        )
        if let focusSessionEngine {
            viewModel.setFocusSessionEngine(focusSessionEngine)
        }
        return viewModel
    }

    private func makeDate() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            year: 2026,
            month: 7,
            day: 18,
            hour: 9,
            minute: 8,
            second: 7
        ))!
    }

    private func makeCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}

private final class RenderingFakeClock: FocusClock, @unchecked Sendable {
    private let _now: Date
    var now: Date { _now }
    var monotonic: TimeInterval { _now.timeIntervalSinceReferenceDate }

    init(_ date: Date) {
        _now = date
    }
}

private final class RenderingMemoryStore: FocusSessionPersisting, @unchecked Sendable {
    private var data: [FocusSession] = []

    func load() -> [FocusSession]? { data }
    func save(_ sessions: [FocusSession]) -> Bool {
        data = sessions
        return true
    }
}

private func renderingDayIdentifier(for date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}
