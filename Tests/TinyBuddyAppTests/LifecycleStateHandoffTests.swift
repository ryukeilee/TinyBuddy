import Foundation
import XCTest

/// Source-contract coverage for the app's exit/restart state hand-off.
///
/// `AppDelegate`'s lifecycle wiring depends on shared stores that are not
/// unit-instantiable, so these tests assert the durable ordering and the
/// presence of the synchronous termination paths directly in the source
/// (same convention as `WidgetTimelineSelfHealingTests`):
///
/// - Normal quit / logout must finalize the open session, synchronously
///   commit the final focus-history publication to the combined snapshot,
///   and only then archive the day image — so HUD, Widget, and the archive
///   never keep a stale "focusing" state across a restart.
/// - SIGTERM (update installers, scripts) must be converted into the normal
///   termination flow instead of dying without `applicationWillTerminate`.
final class LifecycleStateHandoffTests: XCTestCase {
    func testTerminationFinalizesSessionBeforeFinalArchive() throws {
        let source = try appSource()
        let block = try terminationBlock(in: source)

        let terminate = try XCTUnwrap(block.range(of: "focusSessionBridge?.handleTerminate()"))
        let flush = try XCTUnwrap(block.range(of: "flushFinalFocusPublicationForTermination()"))
        let archive = try XCTUnwrap(block.range(of: "historyArchivalCoordinator.handleTermination()"))

        // The finalize (journal write) must precede the synchronous combined
        // snapshot commit, which must precede the final day archival.
        XCTAssertLessThan(terminate.lowerBound, flush.lowerBound)
        XCTAssertLessThan(flush.lowerBound, archive.lowerBound)
        // The flush is only legal outside a reset (the reset removes the
        // session journal and must not recreate pre-reset sessions).
        XCTAssertTrue(block.contains("if !isPerformingReset"))
    }

    func testTerminationFlushUsesJournaledSynchronizationPath() throws {
        let source = try appSource()
        let block = try flushBlock(in: source)

        // The final flush mirrors the startup replay path: same revision-bound
        // publication and the same status derivation, so a termination that is
        // killed mid-commit still leaves a durable replay candidate.
        XCTAssertTrue(block.contains("engine.focusHistoryPublication()"))
        XCTAssertTrue(block.contains("synchronizeFocusHistoryPublication("))
        XCTAssertTrue(block.contains("FocusHistoryPublicationStatus.status(for: publication)"))
    }

    func testSigtermIsConvertedToGracefulTerminationAtPrimaryStartup() throws {
        let source = try appSource()

        // The handler must only be installed after the process became the
        // primary instance (a secondary exits immediately without resources).
        let launchBlock = try launchBlock(in: source)
        let installCall = try XCTUnwrap(launchBlock.range(of: "installTerminationSignalHandlers()"))
        let primaryGuard = try XCTUnwrap(launchBlock.range(of: "guard role == .primary"))
        XCTAssertGreaterThan(installCall.lowerBound, primaryGuard.lowerBound)

        // Delivery must use a retained DispatchSource on the main queue. A raw
        // POSIX callback cannot safely call Dispatch or AppKit because neither
        // is async-signal-safe.
        XCTAssertTrue(source.contains("signal(SIGTERM, SIG_IGN)"))
        XCTAssertTrue(source.contains("DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)"))
        XCTAssertFalse(source.contains("signal(SIGTERM) {"))
        XCTAssertTrue(source.contains("NSApp.terminate(nil)"))
    }

    // MARK: - Source extraction

    private func terminationBlock(in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "func applicationWillTerminate"))
        let end = try XCTUnwrap(
            source.range(of: "func applicationDidBecomeActive")
        )
        return source[start.lowerBound..<end.lowerBound]
    }

    private func flushBlock(in source: String) throws -> Substring {
        let start = try XCTUnwrap(
            source.range(of: "private func flushFinalFocusPublicationForTermination()")
        )
        // The flush body ends where the next private method begins.
        let end = try XCTUnwrap(
            source.range(of: "private func synchronizeFocusHistoryPublication")
        )
        return source[start.lowerBound..<end.lowerBound]
    }

    private func launchBlock(in source: String) throws -> Substring {
        let start = try XCTUnwrap(source.range(of: "func applicationDidFinishLaunching"))
        let end = try XCTUnwrap(
            source.range(of: "private func reconcileProjectDiscovery")
        )
        return source[start.lowerBound..<end.lowerBound]
    }

    private func appSource() throws -> String {
        try String(
            contentsOf: repositoryURL.appendingPathComponent("Sources/TinyBuddy/TinyBuddyApp.swift"),
            encoding: .utf8
        )
    }

    private var repositoryURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
