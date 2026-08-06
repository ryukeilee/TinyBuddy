import SwiftUI
import TinyBuddyCore

/// Settings tab for focus goal configuration, reminder toggles, and
/// notification permission status.
struct FocusGoalSettingsView: View {
    let engineProvider: () -> FocusSessionEngine?
    let coordinator: FocusGoalCoordinator
    let onConfigurationSaved: () -> Void

    @State private var dailyGoalMinutes: Double
    @State private var continuousThresholdMinutes: Double
    @State private var breakDurationMinutes: Double
    @State private var isBreakReminderEnabled: Bool
    @State private var isGoalCompletionEnabled: Bool
    @State private var quietModeStartHour: Double
    @State private var quietModeEndHour: Double
    @State private var notificationStatus: NotificationStatus = .unknown
    @State private var hasPendingChanges = false
    @State private var saveErrorMessage: String?

    private enum NotificationStatus: Equatable {
        case unknown
        case authorized
        case alertsDisabled
        case denied
        case notDetermined
    }

    init(
        engineProvider: @escaping () -> FocusSessionEngine?,
        coordinator: FocusGoalCoordinator,
        onConfigurationSaved: @escaping () -> Void = {}
    ) {
        self.engineProvider = engineProvider
        self.coordinator = coordinator
        self.onConfigurationSaved = onConfigurationSaved
        let config = coordinator.configuration
        _dailyGoalMinutes = State(initialValue: Double(config.dailyFocusGoalMinutes))
        _continuousThresholdMinutes = State(initialValue: Double(config.continuousFocusThresholdMinutes))
        _breakDurationMinutes = State(initialValue: Double(config.breakDurationMinutes))
        _isBreakReminderEnabled = State(initialValue: config.isBreakReminderEnabled)
        _isGoalCompletionEnabled = State(initialValue: config.isGoalCompletionEnabled)
        _quietModeStartHour = State(initialValue: Double(config.quietModeStartHour ?? 22))
        _quietModeEndHour = State(initialValue: Double(config.quietModeEndHour ?? 8))
    }

    var body: some View {
        Form {
            // MARK: Daily Goal
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("每日专注目标: \(Int(dailyGoalMinutes)) 分钟")
                        .bold()
                    Slider(
                        value: $dailyGoalMinutes,
                        in: 15...600,
                        step: 15
                    ) {
                        Text("每日目标")
                    } onEditingChanged: { _ in
                        markChanged()
                    }
                    Text("建议每天 \(Int(dailyGoalMinutes)) 分钟专注")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            } header: {
                Label("每日专注目标", systemImage: "target")
            } footer: {
                Text("保存后会按当前目标重新呈现历史达标进度；已确认会话的时长、次数和归属不会被改写。")
            }

            // MARK: Break Reminder
            Section {
                Toggle("启用休息提醒", isOn: $isBreakReminderEnabled)
                    .onChange(of: isBreakReminderEnabled) { _, _ in markChanged() }

                if isBreakReminderEnabled {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("连续专注阈值: \(Int(continuousThresholdMinutes)) 分钟")
                        Slider(
                            value: $continuousThresholdMinutes,
                            in: 10...180,
                            step: 5
                        ) {
                            Text("连续专注阈值")
                        } onEditingChanged: { _ in
                            markChanged()
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("建议休息时长: \(Int(breakDurationMinutes)) 分钟")
                        Slider(
                            value: $breakDurationMinutes,
                            in: 1...60,
                            step: 1
                        ) {
                            Text("休息时长")
                        } onEditingChanged: { _ in
                            markChanged()
                        }
                    }
                }
            } header: {
                Label("休息提醒", systemImage: "cup.and.saucer")
            } footer: {
                Text("连续专注达到阈值时发送休息提醒。空闲、锁屏、暂停后重新计时。")
            }

            // MARK: Goal Completion
            Section {
                Toggle("目标完成提醒", isOn: $isGoalCompletionEnabled)
                    .onChange(of: isGoalCompletionEnabled) { _, _ in markChanged() }
            } header: {
                Label("目标完成", systemImage: "checkmark.circle")
            } footer: {
                Text("达到每日目标后发送一次完成通知，不会重复提醒。")
            }

            // MARK: Quiet Hours
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text("静默时段起始: \(hourLabel(Int(quietModeStartHour)))")
                    Slider(value: $quietModeStartHour, in: 0...23, step: 1) {
                        Text("开始")
                    } onEditingChanged: { _ in
                        markChanged()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("静默时段结束: \(hourLabel(Int(quietModeEndHour)))")
                    Slider(value: $quietModeEndHour, in: 0...23, step: 1) {
                        Text("结束")
                    } onEditingChanged: { _ in
                        markChanged()
                    }
                }
            } header: {
                Label("静默时段", systemImage: "moon.fill")
            } footer: {
                Text("静默时段内不会发送任何提醒通知。")
            }

            // MARK: Notification Permission
            Section {
                HStack {
                    Label("通知权限", systemImage: notificationIcon)
                    Spacer()
                    switch notificationStatus {
                    case .unknown, .notDetermined:
                        Button("请求权限") {
                            Task { await requestNotificationPermission() }
                        }
                    case .authorized:
                        Text("已授权")
                            .foregroundColor(.green)
                    case .alertsDisabled:
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("已授权，但系统提醒已关闭")
                                .foregroundColor(.orange)
                            Button("前往系统设置") {
                                FocusNotificationManager.openSystemSettings()
                            }
                            .controlSize(.small)
                        }
                    case .denied:
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("已拒绝")
                                .foregroundColor(.red)
                            Button("前往系统设置") {
                                FocusNotificationManager.openSystemSettings()
                            }
                            .controlSize(.small)
                        }
                    }
                }
            } header: {
                Label("通知设置", systemImage: "bell.badge")
            } footer: {
                switch notificationStatus {
                case .denied:
                    Text("通知权限被拒绝后，核心专注功能不受影响，但无法接收提醒。可在系统设置中重新开启。")
                case .alertsDisabled:
                    Text("通知权限已授予，但系统已关闭本应用的横幅或提醒。可在系统设置中重新开启。")
                default:
                    Text("授权后即可在专注目标达成或达到连续专注阈值时接收提醒。")
                }
            }

            // MARK: Save
            if hasPendingChanges {
                Section {
                    if let saveErrorMessage {
                        Text(saveErrorMessage)
                            .foregroundColor(.red)
                            .font(.callout)
                    }
                    HStack {
                        Spacer()
                        Button("保存设置") {
                            saveConfiguration()
                        }
                        .buttonStyle(.borderedProminent)
                        Spacer()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task {
            await refreshNotificationStatus()
        }
        .onAppear {
            reloadConfigurationIfIdle()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await refreshNotificationStatus() }
        }
    }

    // MARK: - Helpers

    private var notificationIcon: String {
        switch notificationStatus {
        case .unknown: return "bell"
        case .authorized: return "bell.fill"
        case .denied, .alertsDisabled: return "bell.slash.fill"
        case .notDetermined: return "bell"
        }
    }

    private func hourLabel(_ hour: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let calendar = Calendar.current
        if let date = calendar.date(from: DateComponents(hour: hour)) {
            return formatter.string(from: date)
        }
        return "\(hour):00"
    }

    private func markChanged() {
        hasPendingChanges = true
    }

    /// Re-syncs the form fields from the persisted configuration when the view
    /// reappears (for example the Settings window is reopened). Skipped while
    /// the user has unsaved edits so in-progress changes are never clobbered.
    private func reloadConfigurationIfIdle() {
        guard !hasPendingChanges else { return }
        let config = coordinator.configuration
        dailyGoalMinutes = Double(config.dailyFocusGoalMinutes)
        continuousThresholdMinutes = Double(config.continuousFocusThresholdMinutes)
        breakDurationMinutes = Double(config.breakDurationMinutes)
        isBreakReminderEnabled = config.isBreakReminderEnabled
        isGoalCompletionEnabled = config.isGoalCompletionEnabled
        quietModeStartHour = Double(config.quietModeStartHour ?? 22)
        quietModeEndHour = Double(config.quietModeEndHour ?? 8)
    }

    private func refreshNotificationStatus() async {
        let state = await FocusNotificationManager().permissionState()
        switch state {
        case .authorized:
            notificationStatus = .authorized
        case .alertsDisabled:
            notificationStatus = .alertsDisabled
        case .denied:
            notificationStatus = .denied
        case .notDetermined:
            notificationStatus = .notDetermined
        case .unknown:
            notificationStatus = .unknown
        }
    }

    private func requestNotificationPermission() async {
        let state = await FocusNotificationManager().requestAuthorization()
        switch state {
        case .authorized:
            notificationStatus = .authorized
        case .alertsDisabled:
            notificationStatus = .alertsDisabled
        case .denied:
            notificationStatus = .denied
        case .notDetermined:
            notificationStatus = .notDetermined
        case .unknown:
            notificationStatus = .unknown
        }
    }

    private func saveConfiguration() {
        let config = FocusGoalConfiguration(
            dailyFocusGoalMinutes: Int(dailyGoalMinutes),
            continuousFocusThresholdMinutes: Int(continuousThresholdMinutes),
            breakDurationMinutes: Int(breakDurationMinutes),
            isBreakReminderEnabled: isBreakReminderEnabled,
            isGoalCompletionEnabled: isGoalCompletionEnabled,
            quietModeStartHour: Int(quietModeStartHour),
            quietModeEndHour: Int(quietModeEndHour)
        )
        let saved = coordinator.saveConfiguration(config)
        coordinator.resetEvaluationCache()
        guard saved else {
            // Keep the edits and surface the failure so the user can retry.
            saveErrorMessage = "保存失败：设置未能写入，请重试。"
            return
        }
        saveErrorMessage = nil
        // Reuse the session-derived cache to re-evaluate historical goal
        // progress; this does not rescan sessions or schedule background work.
        onConfigurationSaved()
        hasPendingChanges = false
    }
}
