import AppKit

struct HUDWindowOriginStore {
    enum Key {
        static let origin = "TinyBuddy.hudWindowOrigin.v1"
    }

    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func load() -> CGPoint? {
        guard let values = userDefaults.object(forKey: Key.origin) as? [String: Any],
              let x = number(in: values, for: "x"),
              let y = number(in: values, for: "y"),
              x.isFinite,
              y.isFinite else {
            return nil
        }

        return CGPoint(x: x, y: y)
    }

    func save(_ origin: CGPoint) {
        guard origin.x.isFinite, origin.y.isFinite else {
            return
        }

        userDefaults.set(["x": origin.x, "y": origin.y], forKey: Key.origin)
    }

    private func number(in values: [String: Any], for key: String) -> CGFloat? {
        guard let number = values[key] as? NSNumber else {
            return nil
        }

        return CGFloat(number.doubleValue)
    }
}

enum HUDWindowPositioning {
    static func correctedOrigin(for windowFrame: CGRect, visibleFrames: [CGRect]) -> CGPoint? {
        guard isValid(windowFrame) else {
            return nil
        }

        let validVisibleFrames = visibleFrames.filter(isValid)
        guard validVisibleFrames.isEmpty == false else {
            return nil
        }

        if validVisibleFrames.contains(where: { $0.contains(windowFrame) }) {
            return windowFrame.origin
        }

        let targetFrame = screenFrame(for: windowFrame, visibleFrames: validVisibleFrames)
        return clampedOrigin(for: windowFrame, in: targetFrame)
    }

    private static func screenFrame(for windowFrame: CGRect, visibleFrames: [CGRect]) -> CGRect {
        var largestIntersectionArea = CGFloat.zero
        var intersectionTarget: CGRect?

        for visibleFrame in visibleFrames {
            let intersection = windowFrame.intersection(visibleFrame)
            let area = intersection.width * intersection.height
            if area > largestIntersectionArea {
                largestIntersectionArea = area
                intersectionTarget = visibleFrame
            }
        }

        if let intersectionTarget {
            return intersectionTarget
        }

        var nearestFrame = visibleFrames[0]
        var nearestDistance = squaredDistance(between: windowFrame, and: nearestFrame)
        for visibleFrame in visibleFrames.dropFirst() {
            let distance = squaredDistance(between: windowFrame, and: visibleFrame)
            if distance < nearestDistance {
                nearestDistance = distance
                nearestFrame = visibleFrame
            }
        }
        return nearestFrame
    }

    private static func clampedOrigin(for windowFrame: CGRect, in visibleFrame: CGRect) -> CGPoint {
        let x: CGFloat
        if windowFrame.width <= visibleFrame.width {
            x = min(max(windowFrame.minX, visibleFrame.minX), visibleFrame.maxX - windowFrame.width)
        } else {
            x = visibleFrame.minX
        }

        let y: CGFloat
        if windowFrame.height <= visibleFrame.height {
            y = min(max(windowFrame.minY, visibleFrame.minY), visibleFrame.maxY - windowFrame.height)
        } else {
            y = visibleFrame.maxY - windowFrame.height
        }

        return CGPoint(x: x, y: y)
    }

    private static func squaredDistance(between lhs: CGRect, and rhs: CGRect) -> CGFloat {
        let horizontalDistance: CGFloat
        if lhs.maxX < rhs.minX {
            horizontalDistance = rhs.minX - lhs.maxX
        } else if rhs.maxX < lhs.minX {
            horizontalDistance = lhs.minX - rhs.maxX
        } else {
            horizontalDistance = 0
        }

        let verticalDistance: CGFloat
        if lhs.maxY < rhs.minY {
            verticalDistance = rhs.minY - lhs.maxY
        } else if rhs.maxY < lhs.minY {
            verticalDistance = lhs.minY - rhs.maxY
        } else {
            verticalDistance = 0
        }

        return horizontalDistance * horizontalDistance + verticalDistance * verticalDistance
    }

    private static func isValid(_ frame: CGRect) -> Bool {
        frame.isNull == false &&
            frame.isInfinite == false &&
            frame.width.isFinite &&
            frame.height.isFinite &&
            frame.minX.isFinite &&
            frame.minY.isFinite &&
            frame.maxX.isFinite &&
            frame.maxY.isFinite &&
            frame.width > 0 &&
            frame.height > 0
    }
}

@MainActor
final class HUDWindowPositionController {
    static let shared = HUDWindowPositionController()

    private let originStore: HUDWindowOriginStore
    private let notificationCenter: NotificationCenter
    private let workspaceNotificationCenter: NotificationCenter
    private let visibleFramesProvider: @MainActor () -> [CGRect]
    private weak var window: NSWindow?
    private var windowMoveObserver: NSObjectProtocol?
    private var applicationLifecycleObservers: [NSObjectProtocol] = []
    private var workspaceLifecycleObservers: [NSObjectProtocol] = []
    private var isStarted = false

    init(
        originStore: HUDWindowOriginStore = HUDWindowOriginStore(),
        notificationCenter: NotificationCenter = .default,
        workspaceNotificationCenter: NotificationCenter = NSWorkspace.shared.notificationCenter,
        visibleFramesProvider: @escaping @MainActor () -> [CGRect] = {
            NSScreen.screens.map(\.visibleFrame)
        }
    ) {
        self.originStore = originStore
        self.notificationCenter = notificationCenter
        self.workspaceNotificationCenter = workspaceNotificationCenter
        self.visibleFramesProvider = visibleFramesProvider
    }

    func start() {
        guard isStarted == false else {
            return
        }
        isStarted = true

        applicationLifecycleObservers = [
            notificationCenter.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.ensureWindowIsVisible()
                }
            }
        ]
        workspaceLifecycleObservers = [
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.ensureWindowIsVisible()
                }
            },
            workspaceNotificationCenter.addObserver(
                forName: NSWorkspace.screensDidWakeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.ensureWindowIsVisible()
                }
            }
        ]
    }

    func stop() {
        isStarted = false

        applicationLifecycleObservers.forEach(notificationCenter.removeObserver)
        applicationLifecycleObservers.removeAll()
        workspaceLifecycleObservers.forEach(workspaceNotificationCenter.removeObserver)
        workspaceLifecycleObservers.removeAll()
        removeWindowMoveObserver()
        window = nil
    }

    func attach(to window: NSWindow) {
        guard self.window !== window else {
            return
        }

        removeWindowMoveObserver()
        self.window = window
        observeMoves(of: window)
        restoreSavedOrigin(for: window)
    }

    func prepare(window: NSWindow) {
        if self.window !== window {
            attach(to: window)
        } else {
            ensureWindowIsVisible()
        }
    }

    func ensureWindowIsVisible() {
        guard let window else {
            return
        }

        applyCorrectedOrigin(for: window.frame, to: window)
    }

    private func restoreSavedOrigin(for window: NSWindow) {
        var candidateFrame = window.frame
        if let origin = originStore.load() {
            candidateFrame.origin = origin
        }

        applyCorrectedOrigin(for: candidateFrame, to: window)
    }

    private func applyCorrectedOrigin(for candidateFrame: CGRect, to window: NSWindow) {
        guard let origin = HUDWindowPositioning.correctedOrigin(
            for: candidateFrame,
            visibleFrames: visibleFramesProvider()
        ) else {
            return
        }

        if window.frame.origin != origin {
            window.setFrameOrigin(origin)
        }
        originStore.save(origin)
    }

    private func observeMoves(of window: NSWindow) {
        windowMoveObserver = notificationCenter.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak self, weak window] _ in
            Task { @MainActor [weak self, weak window] in
                guard let self, let window, self.window === window else {
                    return
                }
                self.originStore.save(window.frame.origin)
            }
        }
    }

    private func removeWindowMoveObserver() {
        if let windowMoveObserver {
            notificationCenter.removeObserver(windowMoveObserver)
            self.windowMoveObserver = nil
        }
    }
}
