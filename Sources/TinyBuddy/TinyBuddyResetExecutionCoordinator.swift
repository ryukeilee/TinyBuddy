import Foundation

/// Serializes the destructive boundary between live runtime work and reset
/// storage work. It deliberately has no UI or persistence knowledge, making
/// the required ordering directly testable.
@MainActor
final class TinyBuddyResetExecutionCoordinator {
    typealias RuntimeQuiescer = () -> Void
    typealias ResetPerformer = (TinyBuddyResetLevel) -> Result<TinyBuddyResetResult, TinyBuddyResetError>
    typealias WidgetReloader = () -> Void
    typealias Terminator = () -> Void
    typealias FailureReporter = (TinyBuddyResetError) -> Void

    private let quiesceRuntime: RuntimeQuiescer
    private let performReset: ResetPerformer
    private let reloadWidget: WidgetReloader
    private let terminate: Terminator
    private let reportFailure: FailureReporter
    private(set) var isExecuting = false

    init(
        quiesceRuntime: @escaping RuntimeQuiescer,
        performReset: @escaping ResetPerformer,
        reloadWidget: @escaping WidgetReloader,
        terminate: @escaping Terminator,
        reportFailure: @escaping FailureReporter
    ) {
        self.quiesceRuntime = quiesceRuntime
        self.performReset = performReset
        self.reloadWidget = reloadWidget
        self.terminate = terminate
        self.reportFailure = reportFailure
    }

    @discardableResult
    func execute(_ level: TinyBuddyResetLevel) -> Bool {
        guard !isExecuting else { return false }
        isExecuting = true
        quiesceRuntime()

        switch performReset(level) {
        case .success:
            reloadWidget()
            terminate()
        case .failure(let error):
            reportFailure(error)
        }
        return true
    }
}
