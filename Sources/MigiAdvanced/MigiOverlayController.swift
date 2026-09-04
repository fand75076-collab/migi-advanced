import AppKit
import MetalKit

final class MigiOverlayController {
    private static let widthPreferenceKey = "petWidth"
    private static let heightPreferenceKey = "petHeight"
    private static let sizePreferenceVersionKey = "petSizePreferenceVersion"
    private static let currentSizePreferenceVersion = 3
    private static let compactDefaultSize = CGSize(width: 115, height: 135)
    private static let originXPreferenceKey = "anchorOriginX"
    private static let originYPreferenceKey = "anchorOriginY"

    private let panel: MigiPanel
    private let metalView: MigiFullSpriteView
    private let speechBubble = MigiSpeechBubbleController()
    private let screenGuard = MigiScreenGuard()
    private var anchorOrigin: CGPoint
    private var lastRoamOffset: CGPoint = .zero
    private var manualDragInProgress = false
    private var lastFrameFatigue: CGFloat = 0
    /// True while the pet is intentionally off-stage for a full-screen
    /// playback window (video, presentation). `show()` calls from the launch
    /// retry sequence or the reopen path must not fight the guard.
    private var isSuppressedForPlayback = false

    /// Latest rendered frame, forwarded for app-level observers (voice lines,
    /// sleep-ledger sampling). Ownership stays with the behavior controller.
    var onFrame: ((MigiBehaviorFrame) -> Void)?

    /// Current sleep-debt pressure (0…1), sampled from the render pipeline.
    var currentFatigue: Double { Double(lastFrameFatigue) }

    /// Restores the persisted canon sleep debt at launch (clamped 0...1).
    func restoreFatigue(_ value: Double) {
        metalView.restoreFatigue(value)
    }

    var isDemoModeEnabled: Bool {
        metalView.isDemoModeEnabled
    }

    init() {
        let initialSize = Self.initialSize()
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Migi Advanced requires a Metal-capable Mac.")
        }
        let view = MigiFullSpriteView(
            frame: CGRect(origin: .zero, size: initialSize),
            device: device
        )

        metalView = view
        panel = MigiPanel(
            contentRect: CGRect(origin: .zero, size: initialSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // No `.fullScreenAuxiliary`: the pet must not follow the user into a
        // native full-screen Space. MigiScreenGuard additionally hides it for
        // borderless full-screen players that never create a Space.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.contentView = metalView

        anchorOrigin = Self.persistedOrigin() ?? Self.defaultOrigin(for: initialSize)
        panel.setFrameOrigin(anchorOrigin)
        clampPanelToVisibleScreen()

        metalView.onBehaviorFrame = { [weak self] frame in
            self?.applyRoaming(frame.worldOffset)
            self?.lastFrameFatigue = frame.fatigue
            self?.onFrame?(frame)
        }
        metalView.onManualWindowMove = { [weak self] origin, isDragging in
            guard let self else { return }
            self.manualDragInProgress = isDragging
            self.rebaseAnchor(at: origin)
            self.speechBubble.updatePetFrame(self.panel.frame)
            if !isDragging {
                self.persistPosition()
            }
        }

        // The pet steps aside while another process owns the whole screen
        // (full-screen video, presentations) and returns on its own when
        // playback ends. Demo/QA runs are exempt for deterministic captures.
        screenGuard.configure(
            petFrameProvider: { [weak self] in
                self?.panel.frame ?? .zero
            },
            demoModeProvider: { [weak self] in
                self?.metalView.isDemoModeEnabled ?? false
            }
        )
        screenGuard.onChange = { [weak self] suppress in
            self?.setSuppressedForPlayback(suppress)
        }
        screenGuard.start()
    }

    func show() {
        guard !isSuppressedForPlayback else { return }
        clampPanelToVisibleScreen()
        panel.orderFrontRegardless()
        metalView.resumeRendering()
        speechBubble.updatePetFrame(panel.frame)
    }

    /// Remove the pet from the stage while a full-screen playback window is
    /// up. The panel is ordered out — hidden, not destroyed — so position,
    /// roam anchor, and behavior state survive; `show()` restores it.
    private func setSuppressedForPlayback(_ suppress: Bool) {
        guard suppress != isSuppressedForPlayback else { return }
        isSuppressedForPlayback = suppress
        if suppress {
            speechBubble.clearSpeech(immediate: true)
            panel.orderOut(nil)
        } else {
            show()
        }
    }

    func ingest(_ snapshot: CodexActivitySnapshot) {
        metalView.ingest(snapshot)
    }

    /// Echo the monitored Agent's reply as a speech bubble. Pass nil to fade it out.
    func showSpeech(_ text: String?, revision: UInt64?) {
        speechBubble.showSpeech(text, revision: revision, petFrame: panel.frame)
    }

    func clearSpeech(immediate: Bool = true) {
        speechBubble.clearSpeech(immediate: immediate)
    }

    func setDemoMode(_ enabled: Bool, fixedActivity: CodexActivity? = nil) {
        metalView.setDemoMode(enabled, fixedActivity: fixedActivity)
    }

    func setQADemoStateDuration(_ duration: TimeInterval) {
        metalView.setQADemoStateDuration(duration)
    }

    func requestQACapture(to url: URL) {
        metalView.requestQACapture(to: url)
    }

    func setQAGaze(_ point: CGPoint?) {
        metalView.setQAGaze(point)
    }

    func setQAClip(_ name: String?) {
        metalView.setQAClip(name)
    }

    func setQAFacing(_ facing: CGFloat?) {
        metalView.setQAFacing(facing)
    }

    func setQAWakePhase(_ phase: MigiWakePhase?) {
        metalView.setQAWakePhase(phase)
    }

    func setQAAgentTransition(_ rawValue: String) {
        metalView.setQAAgentTransition(rawValue)
    }

    func triggerQAInteraction() {
        metalView.triggerQAInteraction()
    }

    func setQAHoverAttention(_ enabled: Bool?) {
        metalView.setQAHoverAttention(enabled)
    }

    func resetPosition() {
        let visibleOrigin = Self.defaultOrigin(for: panel.frame.size)
        rebaseAnchor(at: visibleOrigin)
        panel.setFrameOrigin(visibleOrigin)
        clampPanelToVisibleScreen()
        // Suppressed playback sessions stay hidden even after a menu reset;
        // the guard's next poll re-shows the pet once playback ends.
        if !isSuppressedForPlayback {
            panel.orderFrontRegardless()
        }
        persistPosition()
        speechBubble.updatePetFrame(panel.frame)
    }

    func setPetSize(_ size: CGSize) {
        let oldFrame = panel.frame
        let newOrigin = CGPoint(
            x: oldFrame.midX - size.width / 2,
            y: oldFrame.minY
        )
        panel.setFrame(CGRect(origin: newOrigin, size: size), display: true)
        metalView.frame = CGRect(origin: .zero, size: size)
        rebaseAnchor(at: newOrigin)
        clampPanelToVisibleScreen()
        UserDefaults.standard.set(size.width, forKey: Self.widthPreferenceKey)
        UserDefaults.standard.set(size.height, forKey: Self.heightPreferenceKey)
        UserDefaults.standard.set(
            Self.currentSizePreferenceVersion,
            forKey: Self.sizePreferenceVersionKey
        )
        persistPosition()
        speechBubble.updatePetFrame(panel.frame)
    }

    private func applyRoaming(_ offset: CGPoint) {
        if manualDragInProgress {
            // Behavior time continues while AppKit owns the drag. Track its
            // newest logical offset without moving the panel so mouse-up can
            // atomically rebase the dragged origin and the next frame cannot
            // apply accumulated patrol motion as a jump.
            lastRoamOffset = offset
            return
        }
        var proposed = CGPoint(
            x: anchorOrigin.x + offset.x,
            y: anchorOrigin.y + offset.y
        )
        if let screen = panel.screen ?? NSScreen.main {
            proposed = pixelAlignedClampedOrigin(proposed, on: screen)
        }
        // Preserve the controller's logical offset even when the visible
        // origin is pixel-rounded or edge-clamped. Manual dragging subtracts
        // this value so releasing at a screen edge cannot snap the pet.
        lastRoamOffset = offset
        if !NSEqualPoints(panel.frame.origin, proposed) {
            panel.setFrameOrigin(proposed)
        }
        speechBubble.updatePetFrame(panel.frame)
    }

    private func rebaseAnchor(at visibleOrigin: CGPoint) {
        anchorOrigin = CGPoint(
            x: visibleOrigin.x - lastRoamOffset.x,
            y: visibleOrigin.y - lastRoamOffset.y
        )
    }

    private func clampPanelToVisibleScreen() {
        guard let screen = panel.screen ?? NSScreen.main else { return }
        let origin = pixelAlignedClampedOrigin(panel.frame.origin, on: screen)
        if !NSEqualPoints(panel.frame.origin, origin) {
            panel.setFrameOrigin(origin)
        }
        rebaseAnchor(at: origin)
    }

    private func pixelAlignedClampedOrigin(
        _ proposed: CGPoint,
        on screen: NSScreen
    ) -> CGPoint {
        let visible = screen.visibleFrame
        let scale = max(screen.backingScaleFactor, 1)
        let minimumX = ceil(visible.minX * scale) / scale
        let minimumY = ceil(visible.minY * scale) / scale
        let maximumX = max(
            minimumX,
            floor((visible.maxX - panel.frame.width) * scale) / scale
        )
        let maximumY = max(
            minimumY,
            floor((visible.maxY - panel.frame.height) * scale) / scale
        )
        let aligned = CGPoint(
            x: (proposed.x * scale).rounded() / scale,
            y: (proposed.y * scale).rounded() / scale
        )
        return CGPoint(
            x: min(max(aligned.x, minimumX), maximumX),
            y: min(max(aligned.y, minimumY), maximumY)
        )
    }

    private func persistPosition() {
        UserDefaults.standard.set(anchorOrigin.x, forKey: Self.originXPreferenceKey)
        UserDefaults.standard.set(anchorOrigin.y, forKey: Self.originYPreferenceKey)
    }

    static func persistedSize(defaults: UserDefaults = .standard) -> CGSize? {
        guard defaults.object(forKey: widthPreferenceKey) != nil,
              defaults.object(forKey: heightPreferenceKey) != nil
        else {
            return nil
        }
        let width = defaults.double(forKey: widthPreferenceKey)
        let height = defaults.double(forKey: heightPreferenceKey)
        guard width >= 90, width <= 520, height >= 105, height <= 620 else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    static func initialSize(defaults: UserDefaults = .standard) -> CGSize {
        guard defaults.integer(forKey: sizePreferenceVersionKey)
                >= currentSizePreferenceVersion
        else {
            let previousSize = persistedSize(defaults: defaults)
                ?? CGSize(width: 230, height: 270)
            if defaults.object(forKey: originXPreferenceKey) != nil {
                let centeredOriginX = defaults.double(forKey: originXPreferenceKey)
                    + (previousSize.width - compactDefaultSize.width) / 2
                defaults.set(centeredOriginX, forKey: originXPreferenceKey)
            }
            defaults.set(compactDefaultSize.width, forKey: widthPreferenceKey)
            defaults.set(compactDefaultSize.height, forKey: heightPreferenceKey)
            defaults.set(
                currentSizePreferenceVersion,
                forKey: sizePreferenceVersionKey
            )
            return compactDefaultSize
        }
        return persistedSize(defaults: defaults) ?? compactDefaultSize
    }

    private static func persistedOrigin() -> CGPoint? {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: originXPreferenceKey) != nil,
              defaults.object(forKey: originYPreferenceKey) != nil
        else {
            return nil
        }
        return CGPoint(
            x: defaults.double(forKey: originXPreferenceKey),
            y: defaults.double(forKey: originYPreferenceKey)
        )
    }

    private static func defaultOrigin(for size: CGSize) -> CGPoint {
        guard let visible = NSScreen.main?.visibleFrame else {
            return CGPoint(x: 80, y: 80)
        }
        let availableRoamWidth = max(
            80,
            min(520, visible.width - size.width - 72)
        )
        let roamRadius = max(0, availableRoamWidth * 0.5 - 108)
        return CGPoint(
            // The extra room is intentional: Migi can use its full rightward
            // patrol before reaching the screen edge instead of walking in place.
            x: visible.maxX - size.width - 36 - roamRadius,
            y: visible.minY + 28
        )
    }
}

final class MigiPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
