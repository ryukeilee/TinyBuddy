import SwiftUI
import XCTest
@testable import TinyBuddy
@testable import TinyBuddyCore

@MainActor
final class PetViewRenderingTests: XCTestCase {
    func testHUDRendersAtStableSizeAcrossRepresentativeAccessibilityEnvironments() throws {
        let viewModel = makeViewModel()
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

    private func makeViewModel() -> PetViewModel {
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

        return PetViewModel(
            onboardingStore: onboardingStore,
            store: store,
            activityStore: activityStore,
            combinedSnapshotStore: combinedSnapshotStore,
            refreshStatusStore: refreshStatusStore,
            notificationCenter: NotificationCenter(),
            timeEnvironment: timeEnvironment,
            widgetReloader: {}
        )
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
}
