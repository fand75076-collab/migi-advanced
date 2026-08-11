import AppKit
import ServiceManagement
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let failureNotificationsPreferenceKey = "failureNotificationsEnabled"
    private static let monitoringModePreferenceKey = "agentMonitoringMode"
    private static let speechBubblesPreferenceKey = "speechBubblesEnabled"

    private let stateMonitor = CodexStateMonitor()
    private var overlayController: MigiOverlayController?
    private var statusItem: NSStatusItem?
    private var stateMenuItem: NSMenuItem?
    private var demoMenuItem: NSMenuItem?
    private var monitoringModeMenuItems: [AgentMonitoringMode: NSMenuItem] = [:]
    private var speechBubblesMenuItem: NSMenuItem?
    private var failureNotificationsMenuItem: NSMenuItem?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var hideObserver: NSObjectProtocol?
    private var selectedMonitoringGeneration: UInt64 = 0
    private var selectedMonitoringMode: AgentMonitoringMode = {
        let rawValue = UserDefaults.standard.string(
            forKey: monitoringModePreferenceKey
        )
        return rawValue.flatMap(AgentMonitoringMode.init(rawValue:)) ?? .codex
    }()
    private var previousLiveActivity: CodexActivity = .idle
    private var lastFailureNotificationAt = Date.distantPast
    private var suppressedSpeechRevision: UInt64?
    private var latestLiveSnapshot = CodexActivitySnapshot(
        activity: .idle,
        detail: "Idle",
        observedAt: Date(),
        sourcePath: nil
    )

    private var speechBubblesEnabled: Bool {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: Self.speechBubblesPreferenceKey) == nil {
            return true
        }
        return defaults.bool(forKey: Self.speechBubblesPreferenceKey)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(showExistingInstance),
            name: MigiInstanceControl.notificationName,
            object: MigiInstanceControl.notificationObject,
            suspensionBehavior: .deliverImmediately
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let overlayController = MigiOverlayController()
        self.overlayController = overlayController

        installStatusItem()
        configureDemoFromArguments()
        selectedMonitoringGeneration = stateMonitor.setMonitoringMode(
            selectedMonitoringMode
        )

        stateMonitor.onChange = { [weak self] snapshot in
            guard let self,
                  snapshot.monitoringGeneration == self.selectedMonitoringGeneration
            else {
                return
            }

            self.handleFailureTransition(snapshot)
            self.latestLiveSnapshot = snapshot
            self.overlayController?.ingest(snapshot)
            self.routeSpeechBubble(snapshot)
            if self.overlayController?.isDemoModeEnabled == false {
                self.refreshStateMenu(for: snapshot)
            }
        }
        stateMonitor.start()
        stateMonitor.pollNow()

        hideObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification,
            object: NSApplication.shared,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
                NSApplication.shared.unhideWithoutActivation()
                self?.overlayController?.show()
            }
        }

        // Background launchers can hide a just-started UIElement app at the end
        // of their launch transaction. Reassert visibility without activation.
        for delay in [0.0, 0.45, 1.25, 3.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                NSApplication.shared.unhideWithoutActivation()
                self?.overlayController?.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        stateMonitor.stop()
        DistributedNotificationCenter.default().removeObserver(
            self,
            name: MigiInstanceControl.notificationName,
            object: MigiInstanceControl.notificationObject
        )
        if let hideObserver {
            NotificationCenter.default.removeObserver(hideObserver)
        }
    }

    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows flag: Bool
    ) -> Bool {
        // Finder sends a reopen event when the desktop alias is double-clicked
        // while this LSUIElement app is already running. Re-present the
        // nonactivating panel explicitly; there is no ordinary app window for
        // AppKit to surface on our behalf.
        sender.unhideWithoutActivation()
        overlayController?.show()
        return false
    }

    @objc private func showExistingInstance(_ notification: Notification) {
        NSApplication.shared.unhideWithoutActivation()
        overlayController?.show()
    }

    private func installStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.title = "◉"
        statusItem.button?.toolTip = "Migi Advanced"

        let menu = NSMenu()
        let title = NSMenuItem(title: "Migi Advanced · 原生浮层", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let state = NSMenuItem(title: "Codex：待机", action: nil, keyEquivalent: "")
        state.isEnabled = false
        menu.addItem(state)
        stateMenuItem = state

        menu.addItem(.separator())

        let demo = NSMenuItem(
            title: "状态演示（循环）",
            action: #selector(toggleDemoMode(_:)),
            keyEquivalent: "d"
        )
        demo.target = self
        menu.addItem(demo)
        demoMenuItem = demo

        let monitoringMode = NSMenuItem(
            title: "感知来源",
            action: nil,
            keyEquivalent: ""
        )
        let monitoringModeMenu = NSMenu(title: "感知来源")
        for mode in AgentMonitoringMode.allCases {
            let item = NSMenuItem(
                title: mode.menuLabel,
                action: #selector(selectMonitoringMode(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = mode.rawValue
            monitoringModeMenu.addItem(item)
            monitoringModeMenuItems[mode] = item
        }
        monitoringMode.submenu = monitoringModeMenu
        menu.addItem(monitoringMode)
        refreshMonitoringModeMenu()

        let speechBubbles = NSMenuItem(
            title: "显示 Agent 回复气泡",
            action: #selector(toggleSpeechBubbles(_:)),
            keyEquivalent: ""
        )
        speechBubbles.target = self
        speechBubbles.toolTip = "把当前感知来源已经写入本机会话日志的回复显示在桌面；不会联网。"
        menu.addItem(speechBubbles)
        speechBubblesMenuItem = speechBubbles
        refreshSpeechBubblesMenu()

        let failureNotifications = NSMenuItem(
            title: "异常时通知",
            action: #selector(toggleFailureNotifications(_:)),
            keyEquivalent: ""
        )
        failureNotifications.target = self
        menu.addItem(failureNotifications)
        failureNotificationsMenuItem = failureNotifications
        refreshFailureNotificationsMenu()

        let launchAtLogin = NSMenuItem(
            title: "登录时启动",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        launchAtLogin.target = self
        menu.addItem(launchAtLogin)
        launchAtLoginMenuItem = launchAtLogin
        refreshLaunchAtLoginMenu()

        let center = NSMenuItem(
            title: "回到屏幕右下角",
            action: #selector(resetPosition),
            keyEquivalent: "r"
        )
        center.target = self
        menu.addItem(center)

        let small = NSMenuItem(title: "尺寸：小", action: #selector(setSmallSize), keyEquivalent: "")
        small.target = self
        menu.addItem(small)
        let medium = NSMenuItem(title: "尺寸：中", action: #selector(setMediumSize), keyEquivalent: "")
        medium.target = self
        menu.addItem(medium)
        let large = NSMenuItem(title: "尺寸：大", action: #selector(setLargeSize), keyEquivalent: "")
        large.target = self
        menu.addItem(large)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "退出 Migi Advanced",
            action: #selector(quitApplication),
            keyEquivalent: "q"
        )
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    @objc private func toggleDemoMode(_ sender: NSMenuItem) {
        let enabled = !(overlayController?.isDemoModeEnabled ?? false)
        overlayController?.setDemoMode(enabled)
        demoMenuItem?.state = enabled ? .on : .off
        stateMenuItem?.title = enabled
            ? "\(selectedMonitoringMode.menuLabel)：状态演示"
            : stateMenuTitle(for: latestLiveSnapshot)
    }

    @objc private func selectMonitoringMode(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = AgentMonitoringMode(rawValue: rawValue)
        else {
            return
        }

        selectedMonitoringMode = mode
        suppressedSpeechRevision = latestLiveSnapshot.spokenRevision
        overlayController?.clearSpeech(immediate: true)
        UserDefaults.standard.set(
            mode.rawValue,
            forKey: Self.monitoringModePreferenceKey
        )
        selectedMonitoringGeneration = stateMonitor.setMonitoringMode(mode)
        stateMonitor.pollNow()
        refreshMonitoringModeMenu()
        if overlayController?.isDemoModeEnabled == false {
            stateMenuItem?.title = "\(mode.menuLabel)：正在感知"
        }
    }

    @objc private func toggleSpeechBubbles(_ sender: NSMenuItem) {
        let enabled = !speechBubblesEnabled
        UserDefaults.standard.set(enabled, forKey: Self.speechBubblesPreferenceKey)
        if !enabled {
            suppressedSpeechRevision = latestLiveSnapshot.spokenRevision
            overlayController?.clearSpeech(immediate: true)
        }
        // Enabling deliberately does not replay the last snapshot. A new
        // utterance revision will be shown the next time the monitor sees one.
        refreshSpeechBubblesMenu()
    }

    @objc private func toggleFailureNotifications(_ sender: NSMenuItem) {
        let defaults = UserDefaults.standard
        let currentlyEnabled = defaults.bool(
            forKey: Self.failureNotificationsPreferenceKey
        )
        guard !currentlyEnabled else {
            defaults.set(false, forKey: Self.failureNotificationsPreferenceKey)
            refreshFailureNotificationsMenu()
            return
        }

        UNUserNotificationCenter.current().requestAuthorization(
            options: [.alert, .sound]
        ) { [weak self] granted, error in
            DispatchQueue.main.async {
                defaults.set(
                    granted,
                    forKey: Self.failureNotificationsPreferenceKey
                )
                self?.failureNotificationsMenuItem?.toolTip = error?.localizedDescription
                    ?? (granted ? nil : "系统未授予通知权限")
                self?.refreshFailureNotificationsMenu()
            }
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let service = SMAppService.mainApp
        do {
            switch service.status {
            case .enabled, .requiresApproval:
                try service.unregister()
            case .notRegistered, .notFound:
                try service.register()
            @unknown default:
                try service.register()
            }
            refreshLaunchAtLoginMenu()
        } catch {
            launchAtLoginMenuItem?.title = "登录时启动（操作失败）"
            launchAtLoginMenuItem?.toolTip = error.localizedDescription
        }
    }

    @objc private func resetPosition() {
        overlayController?.resetPosition()
    }

    @objc private func setSmallSize() {
        overlayController?.setPetSize(CGSize(width: 115, height: 135))
    }

    @objc private func setMediumSize() {
        overlayController?.setPetSize(CGSize(width: 140, height: 165))
    }

    @objc private func setLargeSize() {
        overlayController?.setPetSize(CGSize(width: 170, height: 200))
    }

    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func configureDemoFromArguments() {
        let arguments = CommandLine.arguments.dropFirst()
        if let durationArgument = arguments.first(where: {
            $0.hasPrefix("--qa-demo-state-duration=")
        }),
           let duration = Double(
               durationArgument.dropFirst("--qa-demo-state-duration=".count)
           )
        {
            overlayController?.setQADemoStateDuration(duration)
        }

        if let clipArgument = arguments.first(where: { $0.hasPrefix("--qa-clip=") }) {
            let clipName = String(clipArgument.dropFirst("--qa-clip=".count))
            overlayController?.setQAClip(clipName)
        }

        if let facingArgument = arguments.first(where: { $0.hasPrefix("--qa-facing=") }) {
            let rawValue = facingArgument.dropFirst("--qa-facing=".count)
            switch rawValue {
            case "left":
                overlayController?.setQAFacing(-1)
            case "right":
                overlayController?.setQAFacing(1)
            default:
                break
            }
        }

        if let wakeArgument = arguments.first(where: {
            $0.hasPrefix("--qa-wake-phase=")
        }) {
            let rawValue = String(
                wakeArgument.dropFirst("--qa-wake-phase=".count)
            )
            if let phase = MigiWakePhase(qaArgument: rawValue) {
                overlayController?.setQAWakePhase(phase)
                demoMenuItem?.state = .on
                stateMenuItem?.title = "Codex：渐醒演示 \(rawValue)"
            }
        }

        if let fixedArgument = arguments.first(where: { $0.hasPrefix("--demo-state=") }) {
            let rawValue = String(fixedArgument.dropFirst("--demo-state=".count))
            if let activity = CodexActivity(rawValue: rawValue) {
                overlayController?.setDemoMode(true, fixedActivity: activity)
                demoMenuItem?.state = .on
                stateMenuItem?.title = "Codex：演示 \(activity.menuLabel)"
            }
        } else if arguments.contains("--demo") {
            overlayController?.setDemoMode(true)
            demoMenuItem?.state = .on
            stateMenuItem?.title = "Codex：状态演示"
        }

        if let transitionArgument = arguments.first(where: {
            $0.hasPrefix("--qa-agent-transition=")
        }) {
            let rawValue = String(
                transitionArgument.dropFirst("--qa-agent-transition=".count)
            )
            overlayController?.setQAAgentTransition(rawValue)
            demoMenuItem?.state = .on
            stateMenuItem?.title = "Agent 交接演示：\(rawValue)"
        }

        if let captureArgument = arguments.first(where: { $0.hasPrefix("--qa-capture=") }) {
            let path = String(captureArgument.dropFirst("--qa-capture=".count))
            if path.hasPrefix("/") {
                let delay = arguments
                    .first(where: { $0.hasPrefix("--qa-capture-delay=") })
                    .flatMap { Double($0.dropFirst("--qa-capture-delay=".count)) }
                    .map { min(max($0, 0), 10) }
                    ?? 0
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.overlayController?.requestQACapture(
                        to: URL(fileURLWithPath: path)
                    )
                }
            }
        }

        if let exitArgument = arguments.first(where: { $0.hasPrefix("--qa-exit-after=") }),
           let requestedDelay = Double(
               exitArgument.dropFirst("--qa-exit-after=".count)
           )
        {
            let exitDelay = min(max(requestedDelay, 1), 30)
            DispatchQueue.main.asyncAfter(deadline: .now() + exitDelay) {
                NSApplication.shared.terminate(nil)
            }
        }

        if let gazeArgument = arguments.first(where: { $0.hasPrefix("--qa-gaze=") }) {
            let raw = gazeArgument.dropFirst("--qa-gaze=".count)
            let components = raw.split(separator: ",", maxSplits: 1).compactMap { Double($0) }
            if components.count == 2 {
                overlayController?.setQAGaze(
                    CGPoint(x: components[0], y: components[1])
                )
            }
        }

        if arguments.contains("--qa-tap")
            || arguments.contains("--qa-interaction=tap")
        {
            overlayController?.triggerQAInteraction()
        }

        if let hoverArgument = arguments.first(where: {
            $0.hasPrefix("--qa-hover=")
        }) {
            let rawValue = hoverArgument.dropFirst("--qa-hover=".count)
            switch rawValue {
            case "1", "true", "on":
                overlayController?.setQAHoverAttention(true)
            case "0", "false", "off":
                overlayController?.setQAHoverAttention(false)
            default:
                break
            }
        }
    }

    /// Echo an agent's reply as a speech bubble, but only for the agent the user
    /// is currently monitoring. In "all" mode every sourced turn is echoed; in
    /// a single-agent mode only that agent's replies show.
    private func routeSpeechBubble(_ snapshot: CodexActivitySnapshot) {
        guard speechBubblesEnabled else {
            if let revision = snapshot.spokenRevision {
                suppressedSpeechRevision = revision
            }
            overlayController?.clearSpeech(immediate: true)
            return
        }

        let mode = selectedMonitoringMode
        let source = snapshot.spokenAgent
        let agentMatches: Bool
        switch mode {
        case .all:
            agentMatches = true
        case .codex:
            agentMatches = source == .codex
        case .grok:
            agentMatches = source == .grok
        case .zcode:
            agentMatches = source == .zcode
        }
        guard agentMatches,
              let text = snapshot.spokenText,
              let revision = snapshot.spokenRevision
        else {
            overlayController?.showSpeech(nil, revision: nil)
            return
        }
        guard revision != suppressedSpeechRevision else { return }
        overlayController?.showSpeech(text, revision: revision)
    }

    private func handleFailureTransition(_ snapshot: CodexActivitySnapshot) {
        defer {
            previousLiveActivity = snapshot.activity
        }
        guard snapshot.activity == .failed,
              previousLiveActivity != .failed,
              UserDefaults.standard.bool(
                  forKey: Self.failureNotificationsPreferenceKey
              ),
              snapshot.observedAt.timeIntervalSince(lastFailureNotificationAt) >= 30
        else {
            return
        }

        lastFailureNotificationAt = snapshot.observedAt
        let content = UNMutableNotificationContent()
        let source = snapshot.sourceAgent?.menuLabel ?? selectedMonitoringMode.menuLabel
        let copy = MigiFailureNotificationCopy.make(
            source: source,
            detail: snapshot.detail,
            relationshipStage: snapshot.relationshipProfile.stage,
            failureDisposition: snapshot.failureDisposition
        )
        content.title = copy.title
        content.subtitle = copy.subtitle
        content.body = copy.body
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "migi-failure-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }

    private func refreshStateMenu(for snapshot: CodexActivitySnapshot) {
        stateMenuItem?.title = stateMenuTitle(for: snapshot)
    }

    private func stateMenuTitle(for snapshot: CodexActivitySnapshot) -> String {
        let source = snapshot.sourceAgent?.menuLabel ?? selectedMonitoringMode.menuLabel
        return "\(source)：\(snapshot.activity.menuLabel)"
    }

    private func refreshMonitoringModeMenu() {
        for (mode, item) in monitoringModeMenuItems {
            item.state = mode == selectedMonitoringMode ? .on : .off
        }
    }

    private func refreshSpeechBubblesMenu() {
        speechBubblesMenuItem?.state = speechBubblesEnabled ? .on : .off
    }

    private func refreshFailureNotificationsMenu() {
        let enabled = UserDefaults.standard.bool(
            forKey: Self.failureNotificationsPreferenceKey
        )
        failureNotificationsMenuItem?.state = enabled ? .on : .off
    }

    private func refreshLaunchAtLoginMenu() {
        guard let launchAtLoginMenuItem else { return }
        launchAtLoginMenuItem.toolTip = nil
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginMenuItem.title = "登录时启动"
            launchAtLoginMenuItem.state = .on
        case .requiresApproval:
            launchAtLoginMenuItem.title = "登录时启动（需系统批准）"
            launchAtLoginMenuItem.state = .mixed
        case .notRegistered, .notFound:
            launchAtLoginMenuItem.title = "登录时启动"
            launchAtLoginMenuItem.state = .off
        @unknown default:
            launchAtLoginMenuItem.title = "登录时启动"
            launchAtLoginMenuItem.state = .off
        }
    }
}

private extension CodexActivity {
    var menuLabel: String {
        switch self {
        case .idle: return "待机"
        case .thinking: return "思考"
        case .tool: return "使用工具"
        case .waiting: return "等待用户"
        case .review: return "审阅"
        case .failed: return "异常"
        }
    }
}

private extension MigiWakePhase {
    init?(qaArgument: String) {
        switch qaArgument {
        case "awake":
            self = .awake
        case "deepSleep", "deep-sleep":
            self = .deepSleep
        case "dreamDisturbance", "dream-disturbance":
            self = .dreamDisturbance
        case "lookAround", "look-around":
            self = .lookAround
        default:
            return nil
        }
    }
}

private extension MonitoredAgent {
    var menuLabel: String {
        switch self {
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .zcode: return "ZCode"
        }
    }
}

private extension AgentMonitoringMode {
    var menuLabel: String {
        switch self {
        case .codex: return "Codex"
        case .grok: return "Grok"
        case .zcode: return "ZCode"
        case .all: return "全部 Agent"
        }
    }
}
