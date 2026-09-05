import AppKit
import MetalKit
import simd

/// Draws identity-locked Migi key art as one continuously moving tissue field.
///
/// Authored cells remain the source of truth for anatomy, props and direction.
/// Metal adds only bounded regional motion, slow eye-surface tracking and
/// root-to-tip tissue replacement between semantic poses; it never rebuilds
/// Migi from detachable template parts.
final class MigiFullSpriteView: MTKView, MTKViewDelegate {
    private static let inFlightBufferCount = 3
    private static let maximumQACaptureAttempts = 3
    private static let ordinaryHandoffDuration =
        MigiAnimationTiming.semanticHandoffDuration
    private static let urgentHandoffDuration: TimeInterval = 0.16
    private static let sleepHandoffDuration: TimeInterval = 0.52
    private static let authoredFrameHandoffDuration: TimeInterval = 0.085
    private static let hoverDwellDuration: TimeInterval = 0.30
    private static let hoverReleaseDuration: TimeInterval = 0.20
    /// Trailing eyes close a beat behind the leading eye instead of every
    /// visible eye blinking in lockstep.
    private static let blinkStaggerPerEye: TimeInterval = 0.045
    /// Seconds per second used to ease between converged and split gaze.
    private static let gazeConvergenceResponse: Double = 2.6
    /// Ambient split gaze would make deterministic QA captures
    /// non-reproducible, so QA runs keep every eye converged.
    private static let isDeterministicQARun = CommandLine.arguments.contains {
        $0 == "--demo"
            || $0.hasPrefix("--demo-state=")
            || $0.hasPrefix("--qa-")
    }

    var onBehaviorFrame: ((MigiBehaviorFrame) -> Void)?
    var onManualWindowMove: ((CGPoint, Bool) -> Void)?

    private let commandQueue: MTLCommandQueue
    private let texturePipeline: MTLRenderPipelineState
    private let transitionTexturePipeline: MTLRenderPipelineState
    private let colorPipeline: MTLRenderPipelineState
    private let spriteTexture: MTLTexture
    private let atlas: V4AtlasManifest
    private let behavior = MigiFullSpriteView.configureBehavior(
        MigiFullSpriteView.makeRuntimeBehavior()
    )

    private var lastDrawTime = ProcessInfo.processInfo.systemUptime
    private var gaze = SIMD2<Double>(0, 0)
    private var gazeVelocity = SIMD2<Double>(0, 0)
    /// 1 = every eye tracks the shared pointer target; 0 = canon split gaze
    /// where branch eyes autonomously scan their own sectors.
    private var gazeConvergence: Double = 1
    private var activeAgentCount = 1
    private var eyeTrackingStates: [String: V4EyeTrackingState] = [:]
    private var blinkStartedAt: TimeInterval?
    private var blinkReleaseStartedAt: TimeInterval?
    private var activeFrameRate = 60
    private var frameRateGovernor = MigiFrameRateGovernor()
    private var trackedEyesAreChasing = false
    private var clipPlaybackClock = MigiClipPlaybackClock()
    private var breathingPhase = MigiBreathingPhase()
    private var activeBufferSlot = -1
    private let bufferSlotLock = NSLock()
    private var bufferSlotsInUse = Array(
        repeating: false,
        count: MigiFullSpriteView.inFlightBufferCount
    )
    private var reusableSpriteMesh = FullSpriteMesh()
    private var reusableEyeMesh = FullColorMesh()
    private var spriteVertexBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var spriteIndexBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var eyeVertexBuffers: [MTLBuffer?] = [nil, nil, nil]
    private var forcedGazeTarget: SIMD2<Double>?
    private var forcedClipName: String?
    private var forcedQAMirroring: Bool?
    private var forcedWakePhase: MigiWakePhase?
    private var activeClipName: String?
    private var activeClipStartedAt: TimeInterval = 0
    private var lastRequestedMirroring: Bool?
    private var activeTurnPlayback: V4TurnPlayback?
    private var failedDefenseStartedAt: TimeInterval?
    private var lastWakePhase: MigiWakePhase = .awake
    private var lastSpriteSelection: V4SpriteSelection?
    private var wakeHandoff: V4SpriteHandoff?
    private var ordinaryHandoff: V4SpriteHandoff?
    private var authoredFrameHandoff: V4SpriteHandoff?
    private var lastPresentationIdentity: V4PresentationIdentity?
    private var demoMode = false
    private var fixedDemoActivity: CodexActivity?
    private var demoStartTime: TimeInterval?
    private var demoStateDuration: TimeInterval = 8
    private var lastDemoIndex = -1
    private var qaAgentTransition: MigiQAAgentTransition?
    private var qaAgentTransitionStartedAt: TimeInterval?
    private var qaAgentTransitionWasSent = false
    private var latestLiveSnapshot = CodexActivitySnapshot(
        activity: .idle,
        detail: "Idle",
        observedAt: Date(),
        sourcePath: nil
    )
    private var pendingQACapture: QACaptureRequest?
    private var dragStartMouse: CGPoint?
    private var dragStartWindowOrigin: CGPoint?
    private var pointerGesture = MigiPointerGesture()
    private var tapStartedOnSprite = false
    private var hoverTrackingArea: NSTrackingArea?
    private var pointerIsInsidePanel = false
    private var pointerEnteredSpriteAt: TimeInterval?
    private var hoverReleaseUntil: TimeInterval = 0
    private var hoverAttentionIsActive = false
    private var forcedHoverAttention: Bool?
    private var pendingQAInteractionAfterDemoSetup = false
    /// Sustained pointer dwell past this count earns the canon stare-back.
    private static let stareDwellDuration: TimeInterval = 3.0
    private var stareSent = false
    /// 0...1 rising while the user physically manhandles the panel.
    private var dragDispleasure: CGFloat = 0
    /// Latest controller-provided sleep-debt pressure, kept for deformation.
    private var currentFatigue: CGFloat = 0
    /// True while Migi reads a book pose: branch eyes stop tracking the
    /// pointer and sweep the page line by line instead.
    private var readingScanActive = false

    var isDemoModeEnabled: Bool { demoMode }
    override var isOpaque: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    private static func makeRuntimeBehavior() -> MigiBehaviorController {
        let isDeterministicQA = CommandLine.arguments.contains {
            $0 == "--demo"
                || $0.hasPrefix("--demo-state=")
                || $0.hasPrefix("--qa-")
        }
        let seed: UInt64 =
            isDeterministicQA
                ? 0x4D49_4749
                : UInt64.random(in: UInt64.min...UInt64.max)
        let initialFacing: CGFloat =
            isDeterministicQA ? -1 : ((seed & 1) == 0 ? -1 : 1)
        return MigiBehaviorController(
            seed: seed,
            initialFacing: initialFacing
        )
    }

    private static func configureBehavior(
        _ controller: MigiBehaviorController
    ) -> MigiBehaviorController {
        controller.allowsWorkPoseBlinks = !Self.isDeterministicQARun
        return controller
    }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        guard let device,
              let queue = device.makeCommandQueue()
        else {
            fatalError("Unable to initialize Metal.")
        }

        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            fatalError("Unable to compile Migi v4 Metal shaders: \(error)")
        }

        let sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
        texturePipeline = Self.makePipeline(
            device: device,
            library: library,
            vertex: "fullSpriteVertex",
            fragment: "fullSpriteFragment",
            sampleCount: sampleCount
        )
        transitionTexturePipeline = Self.makePipeline(
            device: device,
            library: library,
            vertex: "fullSpriteVertex",
            fragment: "fullSpritePremultipliedFragment",
            sampleCount: sampleCount,
            blendMode: .additivePremultiplied
        )
        colorPipeline = Self.makePipeline(
            device: device,
            library: library,
            vertex: "fullColorVertex",
            fragment: "fullColorFragment",
            sampleCount: sampleCount
        )
        let resources = Self.loadAtlasResources(device: device)
        spriteTexture = resources.texture
        atlas = resources.manifest
        commandQueue = queue

        super.init(frame: frameRect, device: device)

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        layer?.isOpaque = false
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        // Starting MTKView's display link before this view belongs to a
        // window can fail with an empty display list, leaving a permanently
        // transparent panel. MigiOverlayController resumes rendering only
        // after the panel has been ordered onto a real screen.
        isPaused = true
        self.sampleCount = sampleCount
        delegate = self
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func ingest(_ snapshot: CodexActivitySnapshot) {
        latestLiveSnapshot = snapshot
        if !demoMode {
            behavior.ingest(snapshot)
        }
    }

    /// Restores the persisted canon sleep debt at launch (clamped 0...1).
    func restoreFatigue(_ value: Double) {
        behavior.restoreFatigue(value)
    }

    func setDemoMode(_ enabled: Bool, fixedActivity: CodexActivity? = nil) {
        demoMode = enabled
        forcedWakePhase = nil
        qaAgentTransition = nil
        qaAgentTransitionStartedAt = nil
        qaAgentTransitionWasSent = false
        fixedDemoActivity = enabled ? fixedActivity : nil
        demoStartTime = nil
        lastDemoIndex = -1
        if enabled, let fixedActivity {
            behavior.force(
                demoSnapshot(for: fixedActivity),
                resetFatigue: Self.isDeterministicQARun
            )
        } else if !enabled {
            behavior.force(latestLiveSnapshot, resetFatigue: Self.isDeterministicQARun)
        }
    }

    func setQADemoStateDuration(_ duration: TimeInterval) {
        guard duration.isFinite else { return }
        demoStateDuration = min(max(duration, 0.25), 8)
    }

    func requestQACapture(to url: URL) {
        guard url.isFileURL else { return }
        pendingQACapture = QACaptureRequest(
            destinationURL: url,
            failedAttempts: 0
        )
        DispatchQueue.main.async { [weak self] in
            self?.draw()
        }
    }

    func setQAGaze(_ point: CGPoint?) {
        forcedGazeTarget = point.map {
            var value = SIMD2<Double>(Double($0.x), Double($0.y))
            let length = simd_length(value)
            if length > 1 {
                value /= length
            }
            return value
        }
        if let forcedGazeTarget {
            gaze = forcedGazeTarget
            gazeVelocity = .zero
        }
    }

    #if DEBUG
    /// Opt-in visual regression uses the production meshes, shaders and GPU
    /// readback at a controlled clock, without showing or moving a desktop pet.
    func captureMotionQAFrame(
        _ frame: MigiBehaviorFrame,
        time: TimeInterval,
        deltaTime: TimeInterval,
        gazeTarget: SIMD2<Double>,
        destination: URL
    ) throws -> (clip: String, column: Int, fps: Int, eyes: Int, eyelids: [Double]) {
        forcedGazeTarget = gazeTarget
        gazeConvergence = 1
        let chasing: Bool
        if frame.suppressesPointerGaze {
            gaze = .zero
            gazeVelocity = .zero
            chasing = false
        } else {
            chasing = updateGaze(deltaTime: deltaTime, behavior: frame)
        }
        let selection = selectSprite(for: frame, time: time)
        updateWakeHandoff(for: selection, behavior: frame, time: time)
        updateFrameRate(for: frame, selection: selection, gazeIsChasing: chasing, time: time)
        let scene = makeScene(
            selection: selection, behavior: frame,
            time: time, deltaTime: deltaTime
        )
        guard let commandBuffer = commandQueue.makeCommandBuffer(),
              let gpuScene = prepareGPUScene(scene, slot: 0)
        else {
            throw NSError(domain: "MigiMotionQA", code: 1)
        }
        let result = encodeQACapture(
            scene: gpuScene, pixelWidth: 230, pixelHeight: 270,
            commandBuffer: commandBuffer,
            request: QACaptureRequest(destinationURL: destination, failedAttempts: 0)
        )
        guard case let .success(submission) = result else {
            throw NSError(domain: "MigiMotionQA", code: 2)
        }
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        guard commandBuffer.status == .completed else {
            throw commandBuffer.error ?? NSError(domain: "MigiMotionQA", code: 3)
        }
        finishQACapture(submission, commandBuffer: commandBuffer)
        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw NSError(domain: "MigiMotionQA", code: 4)
        }
        let eyelids = selection.eyeAnchors.indices.map {
            Double(blinkCurve(time: time - Double(min($0, 3)) * Self.blinkStaggerPerEye))
        }
        return (selection.clipName, selection.column, activeFrameRate, selection.eyeAnchors.count, eyelids)
    }
    #endif

    func setQAClip(_ name: String?) {
        guard let name else {
            forcedClipName = nil
            activeClipName = nil
            return
        }
        guard atlas.clips[name] != nil else {
            fatalError("Invalid Migi QA clip: \(name)")
        }
        forcedClipName = name
        activeClipName = nil
    }

    func setQAFacing(_ facing: CGFloat?) {
        forcedQAMirroring = facing.map { $0 < 0 }
        lastRequestedMirroring = nil
        activeTurnPlayback = nil
    }

    func setQAWakePhase(_ phase: MigiWakePhase?) {
        forcedWakePhase = phase
        guard let phase else { return }
        demoMode = true
        qaAgentTransition = nil
        qaAgentTransitionStartedAt = nil
        qaAgentTransitionWasSent = false
        fixedDemoActivity = nil
        demoStartTime = nil
        lastDemoIndex = -1
        activeClipName = nil
        // A real wake sequence only begins when work arrives. Mirror that
        // production transition in QA so the final awake frame resolves into
        // the laptop pose instead of an impossible deep-sleep -> idle cut whose
        // much smaller silhouette looks like a scale pop. Deep sleep itself
        // remains idle so it can be held indefinitely for capture.
        let targetActivity: CodexActivity = phase == .deepSleep ? .idle : .thinking
        behavior.force(
            demoSnapshot(for: targetActivity),
            resetFatigue: Self.isDeterministicQARun
        )
        behavior.forceWakePhaseForQA(phase)
    }

    func setQAAgentTransition(_ rawValue: String) {
        guard let transition = MigiQAAgentTransition(rawValue: rawValue) else {
            fatalError("Invalid Migi QA Agent transition: \(rawValue)")
        }
        demoMode = true
        forcedWakePhase = nil
        fixedDemoActivity = nil
        demoStartTime = nil
        lastDemoIndex = -1
        qaAgentTransition = transition
        qaAgentTransitionStartedAt = nil
        qaAgentTransitionWasSent = false
        activeClipName = nil
        lastRequestedMirroring = nil
        activeTurnPlayback = nil
        behavior.force(
            qaAgentTransitionSnapshot(for: transition, afterTransition: false),
            resetFatigue: Self.isDeterministicQARun
        )
    }

    func triggerQAInteraction() {
        if demoMode, forcedWakePhase == nil, lastDemoIndex < 0 {
            // Fixed demo state is applied on the first render callback. Queue
            // the synthetic tap until after that force/reset so QA captures the
            // actual interaction instead of a normal idle cell.
            pendingQAInteractionAfterDemoSetup = true
        } else {
            behavior.ingestInteraction(.tap)
        }
        setFrameRate(60)
    }

    func setQAHoverAttention(_ enabled: Bool?) {
        forcedHoverAttention = enabled
        pointerEnteredSpriteAt = nil
        hoverReleaseUntil = 0
        hoverAttentionIsActive = enabled ?? false
        setFrameRate(60)
    }

    func resumeRendering() {
        // Toggle the display link so a previously hidden/reopened UIElement
        // app recovers even if its original CVDisplayLink creation failed.
        isPaused = true
        needsDisplay = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.isPaused = false
            self.draw()
        }
    }

    func draw(in view: MTKView) {
        autoreleasepool {
            let now = ProcessInfo.processInfo.systemUptime
            // Fifteen-Hz deep sleep needs a wider ceiling than the old 20-Hz
            // cap. The small jitter allowance prevents a late display-link
            // callback from slowing behavior time.
            let deltaTime = min(max(now - lastDrawTime, 1.0 / 240.0), 1.0 / 12.0)
            lastDrawTime = now

            updateDemoIfNeeded(time: now)

            let behaviorFrame = behavior.update(
                time: now,
                deltaTime: deltaTime,
                availableWidth: availableRoamWidth
            )
            onBehaviorFrame?(behaviorFrame)
            updateHoverAttention(
                time: now,
                behavior: behaviorFrame
            )

            let gazeIsChasing: Bool
            if behaviorFrame.suppressesPointerGaze {
                // Deep sleep and dream disturbance are pointer-independent.
                // Reset both position and momentum so the visible look-around
                // phase always wakes from a neutral gaze without an inherited
                // mouse-directed snap.
                gaze = .zero
                gazeVelocity = .zero
                gazeIsChasing = false
            } else {
                gazeIsChasing = updateGaze(
                    deltaTime: deltaTime,
                    behavior: behaviorFrame
                )
            }

            // Attention, sleep phases, forced QA gaze, and deterministic QA
            // runs converge every eye onto the pointer target; otherwise
            // branch eyes drift into their own slow scan. Being physically
            // dragged converges everything as well — Migi watches the hand
            // that holds it.
            activeAgentCount = behaviorFrame.activeAgentCount
            currentFatigue = behaviorFrame.fatigue
            readingScanActive =
                behaviorFrame.microAction == .read
                && behaviorFrame.prop == .book
                && behaviorFrame.wakePhase == .awake
                && !Self.isDeterministicQARun
            let dragTarget: CGFloat =
                (dragStartMouse != nil && pointerGesture.didDrag) ? 1 : 0
            let dragBlend = CGFloat(1 - exp(-deltaTime * 8))
            dragDispleasure += (dragTarget - dragDispleasure) * dragBlend
            let wantsConvergedGaze =
                forcedGazeTarget != nil
                || behaviorFrame.suppressesPointerGaze
                || behaviorFrame.isUserAttentionActive
                || hoverAttentionIsActive
                || dragDispleasure > 0.25
                || Self.isDeterministicQARun
            let convergenceStep =
                1 - exp(-deltaTime * Self.gazeConvergenceResponse)
            gazeConvergence +=
                ((wantsConvergedGaze ? 1.0 : 0.0) - gazeConvergence)
                * convergenceStep

            let selection = selectSprite(for: behaviorFrame, time: now)
            updateWakeHandoff(
                for: selection,
                behavior: behaviorFrame,
                time: now
            )
            updateFrameRate(
                for: behaviorFrame,
                selection: selection,
                gazeIsChasing: gazeIsChasing,
                time: now
            )
            // Reserve the GPU slot and drawable before spending CPU on the
            // deformed mesh; when the three in-flight buffers are still owned
            // by submitted command buffers, the whole scene build is skipped.
            guard let bufferSlot = reserveBufferSlot() else {
                return
            }
            var bufferSlotNeedsImmediateRelease = true
            defer {
                if bufferSlotNeedsImmediateRelease {
                    releaseBufferSlot(bufferSlot)
                }
            }

            guard let descriptor = currentRenderPassDescriptor,
                  let drawable = currentDrawable,
                  let commandBuffer = commandQueue.makeCommandBuffer()
            else {
                return
            }

            let scene = makeScene(
                selection: selection,
                behavior: behaviorFrame,
                time: now,
                deltaTime: deltaTime
            )

            guard let gpuScene = prepareGPUScene(scene, slot: bufferSlot),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else {
                return
            }

            encodeSprite(
                gpuScene.sprite,
                transitionCompositing: gpuScene.usesTransitionCompositing,
                with: encoder
            )
            if let eyes = gpuScene.eyes {
                encodeEyes(eyes, with: encoder)
            }
            encoder.endEncoding()

            var captureSubmission: QACaptureSubmission?
            if let request = pendingQACapture {
                switch encodeQACapture(
                    scene: gpuScene,
                    pixelWidth: drawable.texture.width,
                    pixelHeight: drawable.texture.height,
                    commandBuffer: commandBuffer,
                    request: request
                ) {
                case let .success(submission):
                    captureSubmission = submission
                    pendingQACapture = nil
                case let .failure(reason):
                    recordQACaptureFailure(for: request, reason: reason)
                }
            }

            commandBuffer.addCompletedHandler { [weak self] completedBuffer in
                guard let self else { return }
                self.releaseBufferSlot(bufferSlot)
                if let captureSubmission {
                    self.finishQACapture(
                        captureSubmission,
                        commandBuffer: completedBuffer
                    )
                }
            }
            bufferSlotNeedsImmediateRelease = false
            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [
                .mouseEnteredAndExited,
                .activeAlways,
                .inVisibleRect,
                .enabledDuringMouseDrag,
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        pointerIsInsidePanel = true
    }

    override func mouseExited(with event: NSEvent) {
        pointerIsInsidePanel = false
        pointerEnteredSpriteAt = nil
        if hoverAttentionIsActive {
            hoverReleaseUntil =
                ProcessInfo.processInfo.systemUptime
                    + Self.hoverReleaseDuration
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        let screenPoint = NSEvent.mouseLocation
        pointerGesture.begin(at: screenPoint, time: event.timestamp)
        dragStartMouse = screenPoint
        dragStartWindowOrigin = window.frame.origin
        tapStartedOnSprite = isPointOverInteractiveSprite(screenPoint)
        setFrameRate(60)
        onManualWindowMove?(window.frame.origin, true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let startMouse = dragStartMouse,
              let startOrigin = dragStartWindowOrigin
        else {
            return
        }
        let current = NSEvent.mouseLocation
        pointerGesture.update(to: current)
        guard pointerGesture.didDrag else {
            return
        }
        let origin = CGPoint(
            x: startOrigin.x + current.x - startMouse.x,
            y: startOrigin.y + current.y - startMouse.y
        )
        window.setFrameOrigin(origin)
        onManualWindowMove?(origin, true)
    }

    override func mouseUp(with event: NSEvent) {
        let screenPoint = NSEvent.mouseLocation
        let outcome = pointerGesture.end(
            at: screenPoint,
            time: event.timestamp
        )
        if let origin = window?.frame.origin {
            onManualWindowMove?(origin, false)
        }
        if outcome == .tap, tapStartedOnSprite {
            behavior.ingestInteraction(.tap)
            setFrameRate(60)
        }
        tapStartedOnSprite = false
        dragStartMouse = nil
        dragStartWindowOrigin = nil
    }

    private var availableRoamWidth: CGFloat {
        guard let window,
              let screen = window.screen ?? NSScreen.main
        else {
            return 240
        }
        return max(80, min(520, screen.visibleFrame.width - window.frame.width - 72))
    }

    private func updateDemoIfNeeded(time: TimeInterval) {
        guard demoMode else { return }
        if forcedWakePhase != nil {
            return
        }
        if let qaAgentTransition {
            if qaAgentTransitionStartedAt == nil {
                qaAgentTransitionStartedAt = time
            }
            let elapsed = max(
                time - (qaAgentTransitionStartedAt ?? time),
                0
            )
            if !qaAgentTransitionWasSent, elapsed >= 0.20 {
                qaAgentTransitionWasSent = true
                behavior.ingest(
                    qaAgentTransitionSnapshot(
                        for: qaAgentTransition,
                        afterTransition: true
                    )
                )
            }
            return
        }
        let activities: [CodexActivity] = [.idle, .thinking, .tool, .waiting, .review, .failed]
        if demoStartTime == nil {
            demoStartTime = time
        }
        if let fixedDemoActivity {
            let index = activities.firstIndex(of: fixedDemoActivity) ?? 0
            guard index != lastDemoIndex else { return }
            lastDemoIndex = index
            behavior.force(
                demoSnapshot(for: fixedDemoActivity),
                resetFatigue: Self.isDeterministicQARun
            )
            consumePendingQAInteractionAfterDemoSetup()
            return
        }

        let elapsed = max(0, time - (demoStartTime ?? time))
        let index = Int(elapsed / demoStateDuration) % activities.count
        guard index != lastDemoIndex else { return }
        lastDemoIndex = index
        behavior.force(
            demoSnapshot(for: activities[index]),
            resetFatigue: Self.isDeterministicQARun
        )
        consumePendingQAInteractionAfterDemoSetup()
    }

    private func consumePendingQAInteractionAfterDemoSetup() {
        guard pendingQAInteractionAfterDemoSetup else { return }
        pendingQAInteractionAfterDemoSetup = false
        behavior.ingestInteraction(.tap)
    }

    private func demoSnapshot(for activity: CodexActivity) -> CodexActivitySnapshot {
        CodexActivitySnapshot(
            activity: activity,
            detail: "状态演示",
            observedAt: Date(),
            sourcePath: nil
        )
    }

    private func qaAgentTransitionSnapshot(
        for transition: MigiQAAgentTransition,
        afterTransition: Bool
    ) -> CodexActivitySnapshot {
        let sourceAgent: MonitoredAgent
        let activeAgents: Set<MonitoredAgent>
        switch transition {
        case .join:
            sourceAgent = .codex
            activeAgents = afterTransition ? [.codex, .grok] : [.codex]
        case .handoff:
            sourceAgent = afterTransition ? .grok : .codex
            activeAgents = [.codex, .grok]
        case .leave:
            sourceAgent = .codex
            activeAgents = afterTransition ? [.codex] : [.codex, .grok]
        }
        return CodexActivitySnapshot(
            activity: .thinking,
            detail: "Agent transition QA: \(transition.rawValue)",
            observedAt: Date(),
            sourcePath: nil,
            sourceAgent: sourceAgent,
            monitoringGeneration: 1,
            activeAgents: activeAgents
        )
    }

    @discardableResult
    private func updateGaze(
        deltaTime: TimeInterval,
        behavior: MigiBehaviorFrame
    ) -> Bool {
        let rawTarget: SIMD2<Double>
        if let forcedGazeTarget {
            rawTarget = forcedGazeTarget
        } else {
            guard let window else { return false }
            let screenPoint = NSEvent.mouseLocation
            let windowPoint = window.convertPoint(fromScreen: screenPoint)
            let localPoint = convert(windowPoint, from: nil)
            let halfWidth = max(bounds.width * 0.5, 1)
            let halfHeight = max(bounds.height * 0.5, 1)
            rawTarget = SIMD2<Double>(
                Double((localPoint.x - bounds.midX) / halfWidth),
                Double((localPoint.y - bounds.midY) / halfHeight)
            )
        }
        var target = rawTarget
        let length = simd_length(target)
        if length > 1 {
            target /= length
        }

        // A deliberately slow, critically damped gaze avoids twitching and keeps
        // the body fixed even when the pointer jumps across the screen. A user
        // attention cue raises response modestly without enlarging the iris or
        // changing the authored body pose.
        let stiffness: Double
        if behavior.isUserAttentionActive {
            switch behavior.relationshipStage {
            case .cautious:
                stiffness = 4.6
            case .cooperative:
                stiffness = 5.0
            case .protective:
                stiffness = 5.4
            }
        } else if hoverAttentionIsActive {
            stiffness = 4.8
        } else {
            stiffness = 3.6
        }
        MigiDampedMotion.advance(
            value: &gaze, velocity: &gazeVelocity, target: target,
            stiffness: stiffness, deltaTime: deltaTime
        )

        return simd_length(target - gaze) > 0.012
            || simd_length(gazeVelocity) > 0.018
    }

    private func updateHoverAttention(
        time: TimeInterval,
        behavior: MigiBehaviorFrame
    ) {
        if let forcedHoverAttention {
            hoverAttentionIsActive =
                forcedHoverAttention && !behavior.suppressesPointerGaze
            if !hoverAttentionIsActive, stareSent {
                self.behavior.ingestStareAttention(nil)
                stareSent = false
            }
            return
        }

        guard !behavior.suppressesPointerGaze else {
            pointerEnteredSpriteAt = nil
            hoverReleaseUntil = 0
            hoverAttentionIsActive = false
            if stareSent {
                self.behavior.ingestStareAttention(nil)
                stareSent = false
            }
            return
        }

        let pointerIsOverSprite =
            pointerIsInsidePanel
                && isPointOverInteractiveSprite(NSEvent.mouseLocation)
        if pointerIsOverSprite {
            if pointerEnteredSpriteAt == nil {
                pointerEnteredSpriteAt = time
            }
            let dwell = time - (pointerEnteredSpriteAt ?? time)
            if dwell >= Self.hoverDwellDuration {
                hoverAttentionIsActive = true
                hoverReleaseUntil = 0
            }
            if !stareSent,
               dwell >= Self.stareDwellDuration,
               !Self.isDeterministicQARun
            {
                // Canon beat: held eye contact earns one deliberate turn
                // toward the watcher. The controller owns cooldown/phase gating.
                stareSent = true
                self.behavior.ingestStareAttention(
                    stareDirectionForCurrentPointer()
                )
            }
            return
        }

        pointerEnteredSpriteAt = nil
        if hoverAttentionIsActive, hoverReleaseUntil <= time {
            hoverReleaseUntil = time + Self.hoverReleaseDuration
        }
        hoverAttentionIsActive = time < hoverReleaseUntil

        if !hoverAttentionIsActive, stareSent {
            self.behavior.ingestStareAttention(nil)
            stareSent = false
        }
    }

    private func stareDirectionForCurrentPointer() -> CGFloat {
        guard let window else { return 1 }
        let centerX = window.frame.midX
        return NSEvent.mouseLocation.x < centerX ? -1 : 1
    }

    private func isPointOverInteractiveSprite(
        _ screenPoint: CGPoint
    ) -> Bool {
        guard let window,
              bounds.width > 0,
              bounds.height > 0
        else {
            return false
        }
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let point = convert(windowPoint, from: nil)
        guard bounds.contains(point) else { return false }

        let normalized = CGPoint(
            x: point.x / bounds.width,
            y: point.y / bounds.height
        )
        let clipName = lastSpriteSelection?.clipName
        let interactiveRect: CGRect
        switch clipName {
        case "normal-hand":
            // The resting right hand occupies the lower-center of its authored
            // cell. Excluding its transparent crown and corners prevents a
            // panel click from masquerading as contact with Migi.
            interactiveRect = CGRect(
                x: 0.18,
                y: 0.12,
                width: 0.66,
                height: 0.70
            )
        case "complete-sleep":
            interactiveRect = CGRect(
                x: 0.12,
                y: 0.12,
                width: 0.76,
                height: 0.68
            )
        default:
            let spriteSize = baseSpriteSize()
            interactiveRect = CGRect(
                x: 0.5 - spriteSize.width * 0.5,
                y: 0.5 - spriteSize.height * 0.5,
                width: spriteSize.width,
                height: spriteSize.height
            ).insetBy(dx: 0.015, dy: 0.015)
        }
        guard interactiveRect.contains(normalized) else { return false }

        // A rounded envelope removes the remaining fully transparent corners
        // while keeping thin authored tendrils near every edge reachable.
        let radius = min(
            interactiveRect.width,
            interactiveRect.height
        ) * 0.12
        let inner = interactiveRect.insetBy(dx: radius, dy: radius)
        if inner.contains(normalized)
            || CGRect(
                x: interactiveRect.minX + radius,
                y: interactiveRect.minY,
                width: max(interactiveRect.width - radius * 2, 0),
                height: interactiveRect.height
            ).contains(normalized)
            || CGRect(
                x: interactiveRect.minX,
                y: interactiveRect.minY + radius,
                width: interactiveRect.width,
                height: max(interactiveRect.height - radius * 2, 0)
            ).contains(normalized)
        {
            return true
        }

        let cornerCenter = CGPoint(
            x: normalized.x < interactiveRect.midX
                ? interactiveRect.minX + radius
                : interactiveRect.maxX - radius,
            y: normalized.y < interactiveRect.midY
                ? interactiveRect.minY + radius
                : interactiveRect.maxY - radius
        )
        return hypot(
            normalized.x - cornerCenter.x,
            normalized.y - cornerCenter.y
        ) <= radius
    }

    private func baseSpriteSize() -> CGSize {
        let viewAspect = bounds.height / max(bounds.width, 1)
        var height: CGFloat = 0.91
        var width = height * viewAspect
        if width > 0.96 {
            width = 0.96
            height = width / max(viewAspect, 0.001)
        }
        return CGSize(width: width, height: height)
    }

    private func updateFrameRate(
        for frame: MigiBehaviorFrame,
        selection: V4SpriteSelection,
        gazeIsChasing: Bool,
        time: TimeInterval
    ) {
        updateBlinkState(for: frame, time: time)
        let blinkIsAnimating = frame.blinkWanted
            || blinkReleaseStartedAt.map {
                time - $0 < 0.15 + 3 * Self.blinkStaggerPerEye
            } == true
        var highDetailMicroAction = false
        switch frame.microAction {
        case .rapidNotes, .fineMotor, .organDrift, .logicCount,
             .signalSampling, .agentHandoff, .agentTurn:
            highDetailMicroAction = true
        default:
            break
        }

        let target: Int
        if dragStartMouse != nil {
            target = 60
        } else if wakeHandoff != nil
                    || ordinaryHandoff != nil
                    || authoredFrameHandoff != nil
        {
            target = 60
        } else if frame.wakePhase == .deepSleep {
            target = 15
        } else if frame.wakePhase == .dreamDisturbance {
            target = 30
        } else if frame.isMoving
                    || frame.activity == .failed
                    || highDetailMicroAction
                    || (selection.pointerEyes
                        && (gazeIsChasing || trackedEyesAreChasing || blinkIsAnimating))
        {
            target = 60
        } else {
            target = 30
        }
        setFrameRate(frameRateGovernor.update(requested: target, time: time))
    }

    private func updateWakeHandoff(
        for selection: V4SpriteSelection,
        behavior: MigiBehaviorFrame,
        time: TimeInterval
    ) {
        let currentIdentity = V4PresentationIdentity(
            key: selection.transitionKey,
            mirrored: Self.presentationMirroring(
                selectionMirrored: selection.mirrored,
                turnTargetMirrored: activeTurnPlayback?.targetMirrored
            )
        )
        let presentationChanged =
            lastPresentationIdentity != nil
                && lastPresentationIdentity != currentIdentity
        let requiresImmediateSemanticPose =
            behavior.activity == .waiting || behavior.activity == .failed
        if requiresImmediateSemanticPose,
           presentationChanged,
           let previous = lastSpriteSelection
        {
            // High-salience states still arrive quickly, but tissue now changes
            // spatially instead of cutting the entire body on one display frame.
            wakeHandoff = nil
            authoredFrameHandoff = nil
            ordinaryHandoff = V4SpriteHandoff(
                previous: previous,
                startedAt: time,
                duration: Self.urgentHandoffDuration,
                kind: .urgent
            )
            activeClipStartedAt = max(
                activeClipStartedAt,
                time + Self.urgentHandoffDuration
            )
        } else if lastWakePhase == .lookAround,
           behavior.wakePhase == .awake,
           let previous = lastSpriteSelection
        {
            wakeHandoff = V4SpriteHandoff(
                previous: previous,
                startedAt: time,
                duration: MigiAnimationTiming.wakeHandoffDuration,
                kind: .wake
            )
            ordinaryHandoff = nil
            authoredFrameHandoff = nil
            activeClipStartedAt = max(
                activeClipStartedAt,
                time + MigiAnimationTiming.wakeHandoffDuration
            )
        } else if behavior.wakePhase != .awake,
                  presentationChanged,
                  let previous = lastSpriteSelection
        {
            wakeHandoff = nil
            authoredFrameHandoff = nil
            let duration =
                behavior.wakePhase == .deepSleep
                    ? Self.sleepHandoffDuration
                    : Self.ordinaryHandoffDuration
            ordinaryHandoff = V4SpriteHandoff(
                previous: previous,
                startedAt: time,
                duration: duration,
                kind: .sleep
            )
            activeClipStartedAt = max(activeClipStartedAt, time + duration)
        } else if wakeHandoff == nil,
                  presentationChanged,
                  activeTurnPlayback != nil || behavior.microAction == .agentTurn,
                  let previous = lastSpriteSelection
        {
            // Both the authored planted turn and the explicit agent-turn clip
            // own their own once-through clocks. Give their first cell a very
            // short tissue handoff without delaying or skipping the turn, and
            // do not spend 0.36 s of its clock in a semantic transition or
            // bind it to the next work clip's identity.
            ordinaryHandoff = nil
            authoredFrameHandoff = V4SpriteHandoff(
                previous: previous,
                startedAt: time,
                duration: Self.authoredFrameHandoffDuration,
                kind: .authoredFrame
            )
        } else if wakeHandoff == nil,
                  activeTurnPlayback == nil,
                  presentationChanged,
                  let previous = lastSpriteSelection
        {
            // Ordinary state and prop changes use a root-to-tip tissue front.
            // Rigid prop zones switch as one restrained unit near the midpoint.
            authoredFrameHandoff = nil
            ordinaryHandoff = V4SpriteHandoff(
                previous: previous,
                startedAt: time,
                duration: Self.ordinaryHandoffDuration,
                kind: .semantic
            )
            activeClipStartedAt = max(
                activeClipStartedAt,
                time + Self.ordinaryHandoffDuration
            )
        }

        if let wakeHandoff,
           time - wakeHandoff.startedAt >= wakeHandoff.duration
        {
            self.wakeHandoff = nil
        }
        if let ordinaryHandoff,
           time - ordinaryHandoff.startedAt >= ordinaryHandoff.duration
        {
            self.ordinaryHandoff = nil
        }
        if let authoredFrameHandoff,
           time - authoredFrameHandoff.startedAt >= authoredFrameHandoff.duration
        {
            self.authoredFrameHandoff = nil
        }

        // Same-presentation authored cells are animation frames, not semantic
        // morphs. They advance directly. Crossfading every cell drew two full
        // sprites with source-over blending, periodically reducing composite
        // opacity and producing duplicate eyes and limbs.

        lastWakePhase = behavior.wakePhase
        lastPresentationIdentity = currentIdentity
        lastSpriteSelection = selection
    }

    static func presentationMirroring(
        selectionMirrored: Bool,
        turnTargetMirrored: Bool?
    ) -> Bool {
        turnTargetMirrored ?? selectionMirrored
    }

    private func setFrameRate(_ target: Int) {
        guard target != activeFrameRate else { return }
        activeFrameRate = target
        preferredFramesPerSecond = target
    }

    private func selectSprite(
        for frame: MigiBehaviorFrame,
        time: TimeInterval
    ) -> V4SpriteSelection {
        let requestedMirroring =
            forcedQAMirroring ?? (frame.facing < 0)
        if let forcedClipName {
            return selection(
                named: forcedClipName,
                time: time,
                mirrored: requestedMirroring
            )
        }

        if frame.activity == .failed {
            guard frame.failureDisposition == .credibleThreat else {
                failedDefenseStartedAt = nil
                let diagnosis =
                    atlas.clips["calm-diagnosis"] != nil
                        ? "calm-diagnosis"
                        : "logic-count"
                return selection(
                    named: diagnosis,
                    time: time,
                    mirrored: requestedMirroring,
                    playbackIdentity: "routine-failure-diagnosis"
                )
            }

            if frame.microAction == .protectiveShield {
                failedDefenseStartedAt = nil
                let shieldName =
                    atlas.clips["protective-shield"] != nil
                        ? "protective-shield"
                        : "failed"
                return selection(
                    named: shieldName,
                    time: time,
                    mirrored: requestedMirroring,
                    playbackRate: frame.clipPlaybackRate,
                    playbackIdentity: "failed-protective-shield"
                )
            }

            if frame.microAction == .sharpenTip,
               let bladeClip = atlas.clips["sharpen-tip"]
            {
                if failedDefenseStartedAt == nil {
                    failedDefenseStartedAt = time
                }
                let elapsed = max(
                    time - (failedDefenseStartedAt ?? time),
                    0
                )
                let defenseDuration = Self.nonRepeatingPlaybackDuration(
                    for: bladeClip,
                    clipName: "sharpen-tip",
                    playbackRate: frame.clipPlaybackRate
                )
                if elapsed < defenseDuration {
                    return selection(
                        named: "sharpen-tip",
                        time: time,
                        mirrored: requestedMirroring,
                        playbackRate: frame.clipPlaybackRate,
                        playbackIdentity: "failed-defense"
                    )
                }
            }
            return selection(named: "failed", time: time, mirrored: requestedMirroring)
        }
        failedDefenseStartedAt = nil

        switch frame.prop {
        case .phone:
            return selection(named: "phone", time: time, mirrored: requestedMirroring)
        case .laptop:
            return selection(
                named: "laptop",
                time: time,
                mirrored: requestedMirroring,
                playbackRate: frame.clipPlaybackRate
            )
        case .book:
            return selection(
                named: "book",
                time: time,
                mirrored: requestedMirroring,
                playbackRate: frame.clipPlaybackRate
            )
        case .none:
            break
        }

        let microActionClip: String?
        switch frame.microAction {
        case .inspectHand:
            // Self-check owns its authored clip; palm-observer remains the
            // fallback for atlases that predate it.
            microActionClip =
                atlas.clips["inspect-hand"] != nil
                    ? "inspect-hand"
                    : "palm-observer"
        case .palmObserver:
            microActionClip =
                atlas.clips["palm-observer"] != nil
                    ? "palm-observer"
                    : "inspect-hand"
        case .sharpenTip:
            microActionClip = "sharpen-tip"
        case .protectiveShield:
            microActionClip =
                atlas.clips["protective-shield"] != nil
                    ? "protective-shield"
                    : "failed"
        case .rapidNotes:
            microActionClip = "rapid-notes"
        case .fineMotor:
            microActionClip = "fine-motor"
        case .organDrift:
            microActionClip = "organ-drift"
        case .logicCount:
            microActionClip = "logic-count"
        case .signalSampling:
            microActionClip =
                atlas.clips["signal-sampling"] != nil
                    ? "signal-sampling"
                    : "look-around"
        case .agentHandoff:
            microActionClip = "look-around"
        case .agentTurn:
            microActionClip = frame.facing < 0 ? "turn-left" : "turn-right"
        case .storagePocket:
            microActionClip =
                atlas.clips["storage-pocket"] != nil
                    ? "storage-pocket"
                    : "inspect-hand"
        case .recoveryCare:
            microActionClip =
                atlas.clips["recovery-care"] != nil
                    ? "recovery-care"
                    : "fine-motor"
        case .calmDiagnosis:
            microActionClip =
                atlas.clips["calm-diagnosis"] != nil
                    ? "calm-diagnosis"
                    : "logic-count"
        case .detachedScoutReturn, .subAgentScout:
            // 共享同一条离体侦察—回归原画;子代理版本由控制器的 60 秒冷却
            // 保证稀有度,与待机巡游的必然回归语义一致。
            microActionClip =
                atlas.clips["detached-scout-return"] != nil
                    ? "detached-scout-return"
                    : "patrol"
        case .stretch:
            microActionClip = "stretch"
        case .lookAround:
            microActionClip = "look-around"
        case .dormant:
            if frame.wakePhase != .deepSleep,
               atlas.clips["complete-sleep-wake"] != nil
            {
                microActionClip = "complete-sleep-wake"
            } else {
                microActionClip =
                    atlas.clips["complete-sleep"] != nil
                        ? "complete-sleep"
                        : "dormant"
            }
        case .none, .blink, .read, .checkPhone, .type:
            microActionClip = nil
        }
        if let microActionClip {
            let wakeIdentity: String
            switch frame.wakePhase {
            case .awake:
                wakeIdentity = "awake"
            case .deepSleep:
                wakeIdentity = "deep-sleep"
            case .dreamDisturbance:
                wakeIdentity = "dream-disturbance"
            case .lookAround:
                wakeIdentity = "wake-look-around"
            }
            let identity = frame.microAction == .agentHandoff
                ? "agent-handoff#\(wakeIdentity)"
                : "\(microActionClip)#\(wakeIdentity)"
            return selection(
                named: microActionClip,
                time: time,
                mirrored: requestedMirroring,
                playbackRate: frame.clipPlaybackRate,
                playbackIdentity: identity
            )
        }

        if frame.isMoving {
            let detachedScoutClip =
                frame.scoutPhase == .returning
                    && atlas.clips["detached-scout-return"] != nil
                    ? "detached-scout-return"
                    : "patrol"
            return selection(
                named: detachedScoutClip,
                time: time,
                mirrored: requestedMirroring
            )
        }
        let idleName =
            atlas.clips["normal-hand"] != nil ? "normal-hand" : "idle"
        return selection(
            named: idleName,
            time: time,
            mirrored: requestedMirroring
        )
    }

    private func selection(
        named name: String,
        time: TimeInterval,
        mirrored: Bool,
        playbackRate: Double = 1,
        playbackIdentity: String? = nil
    ) -> V4SpriteSelection {
        guard let requestedClip = atlas.clips[name],
              requestedClip.frameCount > 0,
              requestedClip.row >= 0,
              requestedClip.row < atlas.rows,
              requestedClip.columnOffset >= 0,
              requestedClip.columnOffset + requestedClip.frameCount <= atlas.columns
        else {
            fatalError("Invalid or missing Migi v4 clip: \(name)")
        }

        if activeTurnPlayback?.baseClipName != name {
            activeTurnPlayback = nil
        }
        if let previousMirroring = lastRequestedMirroring,
           previousMirroring != mirrored
        {
            let directionalTurnName = mirrored
                ? requestedClip.turnLeftClip
                : requestedClip.turnRightClip
            let turnName = directionalTurnName ?? requestedClip.turnClip
            if let turnName, atlas.clips[turnName] != nil {
                activeTurnPlayback = V4TurnPlayback(
                    baseClipName: name,
                    clipName: turnName,
                    startedAt: time,
                    targetMirrored: mirrored,
                    playbackRate: playbackRate,
                    reversed: mirrored
                        ? requestedClip.turnLeftReversed
                        : requestedClip.turnRightReversed
                )
            }
        }
        lastRequestedMirroring = mirrored

        if let turn = activeTurnPlayback,
           let turnClip = atlas.clips[turn.clipName]
        {
            let turnElapsed = max(time - turn.startedAt, 0)
            let turnDuration = Self.oncePlaybackDuration(
                for: turnClip,
                clipName: turn.clipName,
                playbackRate: turn.playbackRate
            )
            if turnElapsed < turnDuration {
                var frame = Self.frameIndex(
                    for: turnClip,
                    clipName: turn.clipName,
                    elapsed: turnElapsed,
                    playbackRate: turn.playbackRate,
                    forcedMode: .once
                )
                if turn.reversed {
                    frame = max(turnClip.frameCount - 1 - frame, 0)
                }
                return makeSpriteSelection(
                    clipName: turn.clipName,
                    clip: turnClip,
                    frame: frame,
                    mirrored: Self.resolvedMirroring(
                        for: turnClip,
                        named: turn.clipName,
                        requestedMirroring: turn.targetMirrored
                    ),
                    transitionKey: turn.baseClipName
                )
            }
            activeTurnPlayback = nil
        }

        let resolved = resolvedDirectionalClip(
            baseName: name,
            baseClip: requestedClip,
            requestedMirroring: mirrored
        )
        let identity =
            "\(playbackIdentity ?? name)#\(resolved.name)"
        if activeClipName != identity {
            activeClipName = identity
            activeClipStartedAt = time
        }
        let clipTime = clipPlaybackClock.sample(
            identity: identity,
            startedAt: activeClipStartedAt,
            time: time,
            targetRate: playbackRate
        )
        let frame = Self.frameIndex(
            for: resolved.clip,
            clipName: resolved.name,
            elapsed: clipTime,
            playbackRate: 1
        )
        return makeSpriteSelection(
            clipName: resolved.name,
            clip: resolved.clip,
            frame: frame,
            mirrored: resolved.mirrored,
            transitionKey: name
        )
    }

    private func resolvedDirectionalClip(
        baseName: String,
        baseClip: V4Clip,
        requestedMirroring: Bool
    ) -> (name: String, clip: V4Clip, mirrored: Bool) {
        let directionalName =
            requestedMirroring ? baseClip.leftClip : baseClip.rightClip
        if let directionalName, let directionalClip = atlas.clips[directionalName] {
            return (
                directionalName,
                directionalClip,
                Self.resolvedMirroring(
                    for: directionalClip,
                    named: directionalName,
                    requestedMirroring: false
                )
            )
        }
        return (
            baseName,
            baseClip,
            Self.resolvedMirroring(
                for: baseClip,
                named: baseName,
                requestedMirroring: requestedMirroring
            )
        )
    }

    private static let anatomicallyAnchoredClips: Set<String> = [
        "normal-hand", "palm-observer", "complete-sleep",
    ]

    private static func resolvedMirroring(
        for clip: V4Clip,
        named name: String,
        requestedMirroring: Bool
    ) -> Bool {
        // These are specifically Shinichi's right-hand topology, not a generic
        // left/right mascot pose. Enforce the anatomical side even if an older
        // handoff manifest accidentally omits mirror_policy=never.
        if Self.anatomicallyAnchoredClips.contains(name) {
            return false
        }
        switch clip.mirrorPolicy {
        case .automatic:
            return requestedMirroring
        case .never:
            return false
        case .always:
            return true
        }
    }

    private static func transitionRootAxis(
        named clipName: String
    ) -> V4TransitionRootAxis {
        // The generated hand families rest with Shinichi's wrist on the
        // screen-left side, whereas the autonomous body and shield/care poses
        // remain planted at the lower edge. A handoff uses the incoming
        // family's axis for both layers so outgoing and incoming visibility
        // stay complementary.
        switch clipName {
        case "normal-hand", "palm-observer", "signal-sampling",
             "calm-diagnosis", "storage-pocket", "complete-sleep",
             "complete-sleep-wake":
            return .left
        default:
            return .bottom
        }
    }

    private static func transitionRootDistance(
        for anchor: V4EyeAnchor,
        axis: V4TransitionRootAxis
    ) -> CGFloat {
        switch axis {
        case .bottom:
            return 1 - anchor.y
        case .left:
            return anchor.x
        }
    }

    private func makeSpriteSelection(
        clipName: String,
        clip: V4Clip,
        frame: Int,
        mirrored: Bool,
        transitionKey: String
    ) -> V4SpriteSelection {
        let authoredAnchors =
            clip.eyes.indices.contains(frame) ? clip.eyes[frame] : []
        let configuredFallbacks =
            clip.eyeFallbacks?.indices.contains(frame) == true
                ? clip.eyeFallbacks?[frame] ?? []
                : []
        let safeFallbacks =
            clip.containsProp
                ? Self.safePropEyeAnchors(named: clipName, frame: frame)
                : []
        let anchors =
            !authoredAnchors.isEmpty
                ? authoredAnchors
                : (!configuredFallbacks.isEmpty ? configuredFallbacks : safeFallbacks)
        let fallbackIsActive = authoredAnchors.isEmpty && !anchors.isEmpty
        return V4SpriteSelection(
            clipName: clipName,
            transitionKey: transitionKey,
            row: clip.row,
            column: clip.columnOffset + frame,
            mirrored: mirrored,
            containsProp: clip.containsProp,
            pointerEyes: !anchors.isEmpty && (clip.pointerEyes || fallbackIsActive),
            eyeAnchors: anchors,
            deformationProfile: Self.deformationProfile(
                named: clipName,
                clip: clip
            )
        )
    }

    private static func frameIndex(
        for clip: V4Clip,
        clipName: String,
        elapsed: TimeInterval,
        playbackRate: Double,
        forcedMode: V4PlaybackMode? = nil
    ) -> Int {
        let frameCount = max(clip.frameCount, 1)
        guard frameCount > 1 else { return 0 }
        let timeline = playbackTimeline(
            for: clip,
            clipName: clipName,
            playbackRate: playbackRate,
            forcedMode: forcedMode
        )
        return timeline.frame(at: elapsed)
    }

    private static func defaultPlaybackMode(named name: String) -> V4PlaybackMode {
        // The canonical blade row already contains enter, peak and retract art.
        // Play that authored action once instead of repeatedly reopening the
        // tissue during one write event. Every other legacy clip keeps its
        // original looping behavior unless the manifest opts in explicitly.
        name == "sharpen-tip" ? .enterHoldRetract : .loop
    }

    /// A clip's frame sequence and timing only depend on (clip, mode, rate),
    /// yet the render loop re-derived them every frame. Timelines are cached
    /// per quantized rate; canon and QA rates (1, 1.25, 0.75, 1.4) quantize
    /// exactly, so deterministic captures are unaffected.
    private struct V4PlaybackTimeline {
        var prefixSequence: [Int] = []
        var prefixDurations: [TimeInterval] = []
        var cycleSequence: [Int] = []
        var cycleDurations: [TimeInterval] = []
        var repeats: Bool
        var prefixDuration: TimeInterval = 0
        var fixedFrame: Int?

        func frame(at elapsed: TimeInterval) -> Int {
            if let fixedFrame { return fixedFrame }
            guard !cycleSequence.isEmpty,
                  cycleSequence.count == cycleDurations.count
            else {
                return 0
            }
            let safeElapsed = max(elapsed.isFinite ? elapsed : 0, 0)
            var cursor = safeElapsed
            if prefixDuration > 0 {
                if cursor < prefixDuration {
                    return frameForSequence(
                        prefixSequence,
                        explicitDurations: prefixDurations,
                        elapsed: cursor,
                        repeats: false
                    )
                }
                cursor -= prefixDuration
            }
            return frameForSequence(
                cycleSequence,
                explicitDurations: cycleDurations,
                elapsed: cursor,
                repeats: repeats
            )
        }
    }

    private static var playbackTimelineCache: [String: V4PlaybackTimeline] = [:]
    private static var frameDurationCache: [String: [TimeInterval]] = [:]

    private static func quantizedPlaybackRate(_ rate: Double) -> Double {
        let safeRate = max(rate.isFinite ? rate : 1, 0.05)
        return (safeRate * 20).rounded() / 20
    }

    private static func frameDurations(
        for clip: V4Clip,
        clipName: String,
        playbackRate: Double
    ) -> [TimeInterval] {
        let key = "\(clipName)#\(quantizedPlaybackRate(playbackRate))"
        if let cached = frameDurationCache[key] { return cached }
        let safeRate = quantizedPlaybackRate(playbackRate)
        let authored =
            clip.frameDurations?.count == clip.frameCount
                ? clip.frameDurations ?? []
                : Array(repeating: clip.frameDuration, count: clip.frameCount)
        let durations = authored.map {
            max(($0.isFinite ? $0 : clip.frameDuration) / safeRate, 0.01)
        }
        frameDurationCache[key] = durations
        return durations
    }

    private static func playbackTimeline(
        for clip: V4Clip,
        clipName: String,
        playbackRate: Double,
        forcedMode: V4PlaybackMode?
    ) -> V4PlaybackTimeline {
        let mode =
            forcedMode
                ?? clip.playbackMode
                ?? defaultPlaybackMode(named: clipName)
        let key = "\(clipName)#\(mode)#\(quantizedPlaybackRate(playbackRate))"
        if let cached = playbackTimelineCache[key] { return cached }
        let timeline = buildPlaybackTimeline(
            for: clip,
            clipName: clipName,
            mode: mode,
            playbackRate: playbackRate
        )
        playbackTimelineCache[key] = timeline
        return timeline
    }

    private static func buildPlaybackTimeline(
        for clip: V4Clip,
        clipName: String,
        mode: V4PlaybackMode,
        playbackRate: Double
    ) -> V4PlaybackTimeline {
        let frameCount = max(clip.frameCount, 1)
        let durations = frameDurations(
            for: clip,
            clipName: clipName,
            playbackRate: playbackRate
        )

        switch mode {
        case .hold:
            return V4PlaybackTimeline(
                cycleSequence: [],
                cycleDurations: [],
                repeats: false,
                fixedFrame: min(
                    max(clip.holdFrame ?? frameCount - 1, 0),
                    frameCount - 1
                )
            )
        case .once:
            return V4PlaybackTimeline(
                cycleSequence: Array(0..<frameCount),
                cycleDurations: durations,
                repeats: false
            )
        case .pingPong:
            var sequence = Array(0..<frameCount)
            if frameCount > 2 {
                sequence.append(contentsOf: stride(from: frameCount - 2, through: 1, by: -1))
            }
            return V4PlaybackTimeline(
                cycleSequence: sequence,
                cycleDurations: sequence.map { durations[$0] },
                repeats: true
            )
        case .enterHoldRetract:
            let defaultHoldFrame = clipName == "sharpen-tip"
                ? min(2, frameCount - 1)
                : frameCount - 1
            let holdFrame =
                min(max(clip.holdFrame ?? defaultHoldFrame, 0), frameCount - 1)
            let holdDuration =
                max(
                    clip.holdDuration
                        ?? (clipName == "sharpen-tip" ? 0.72 : 0.45),
                    0
                )
            var sequence = Array(0...holdFrame)
            var sequenceDurations = sequence.map { durations[$0] }
            sequence.append(holdFrame)
            sequenceDurations.append(holdDuration)
            if holdFrame + 1 < frameCount {
                sequence.append(contentsOf: (holdFrame + 1)..<frameCount)
                sequenceDurations.append(
                    contentsOf: durations[(holdFrame + 1)..<frameCount]
                )
            }
            return V4PlaybackTimeline(
                cycleSequence: sequence,
                cycleDurations: sequenceDurations,
                repeats: false
            )
        case .loop:
            if let range = clip.loopRange,
               range.count == 2
            {
                let start = min(max(range[0], 0), frameCount - 1)
                let end = min(max(range[1], start), frameCount - 1)
                if start > 0 {
                    let prefix = Array(0..<start)
                    let prefixDurations = prefix.map { durations[$0] }
                    return V4PlaybackTimeline(
                        prefixSequence: prefix,
                        prefixDurations: prefixDurations,
                        cycleSequence: Array(start...end),
                        cycleDurations: (start...end).map { durations[$0] },
                        repeats: true,
                        prefixDuration: prefixDurations.reduce(0, +)
                    )
                }
                return V4PlaybackTimeline(
                    cycleSequence: Array(start...end),
                    cycleDurations: (start...end).map { durations[$0] },
                    repeats: true
                )
            }
            return V4PlaybackTimeline(
                cycleSequence: Array(0..<frameCount),
                cycleDurations: durations,
                repeats: true
            )
        }
    }

    private static func oncePlaybackDuration(
        for clip: V4Clip,
        clipName: String,
        playbackRate: Double
    ) -> TimeInterval {
        frameDurations(
            for: clip,
            clipName: clipName,
            playbackRate: playbackRate
        ).reduce(0, +)
    }

    private static func nonRepeatingPlaybackDuration(
        for clip: V4Clip,
        clipName: String,
        playbackRate: Double
    ) -> TimeInterval {
        let base = oncePlaybackDuration(
            for: clip,
            clipName: clipName,
            playbackRate: playbackRate
        )
        let mode = clip.playbackMode ?? defaultPlaybackMode(named: clipName)
        guard mode == .enterHoldRetract else { return base }
        return base
            + max(
                clip.holdDuration
                    ?? (clipName == "sharpen-tip" ? 0.72 : 0.45),
                0
            )
    }

    private static func frameForSequence(
        _ sequence: [Int],
        durations: [TimeInterval],
        elapsed: TimeInterval,
        repeats: Bool
    ) -> Int {
        frameForSequence(
            sequence,
            explicitDurations: sequence.map { durations[$0] },
            elapsed: elapsed,
            repeats: repeats
        )
    }

    private static func frameForSequence(
        _ sequence: [Int],
        explicitDurations: [TimeInterval],
        elapsed: TimeInterval,
        repeats: Bool
    ) -> Int {
        guard let first = sequence.first,
              sequence.count == explicitDurations.count
        else {
            return 0
        }
        let total = explicitDurations.reduce(0, +)
        guard total > 0 else { return first }
        var cursor = repeats ? elapsed.truncatingRemainder(dividingBy: total) : elapsed
        if !repeats, cursor >= total {
            return sequence.last ?? first
        }
        for (index, duration) in explicitDurations.enumerated() {
            if cursor < duration {
                return sequence[index]
            }
            cursor -= duration
        }
        return sequence.last ?? first
    }

    private static var propEyeAnchorTableCache: [String: [[V4EyeAnchor]]] = [:]

    private static func safePropEyeAnchors(
        named name: String,
        frame: Int
    ) -> [V4EyeAnchor] {
        let table = propEyeAnchorTable(named: name)
        guard table.indices.contains(frame) else { return [] }
        return table[frame]
    }

    private static func propEyeAnchorTable(named name: String) -> [[V4EyeAnchor]] {
        if let cached = propEyeAnchorTableCache[name] { return cached }
        let table = buildPropEyeAnchorTable(named: name)
        propEyeAnchorTableCache[name] = table
        return table
    }

    private static func buildPropEyeAnchorTable(
        named name: String
    ) -> [[V4EyeAnchor]] {
        func eye(
            _ x: CGFloat,
            _ y: CGFloat,
            _ radius: CGFloat,
            _ id: String,
            _ gain: CGFloat,
            _ stiffness: CGFloat
        ) -> V4EyeAnchor {
            V4EyeAnchor(
                x: x,
                y: y,
                radius: radius,
                trackingID: id,
                trackingGain: gain,
                verticalGain: min(gain + 0.08, 1),
                trackingStiffness: stiffness
            )
        }

        let frames: [[V4EyeAnchor]]
        switch name {
        case "laptop":
            frames = [
                [eye(0.576, 0.451, 0.037, "main", 1, 12),
                 eye(0.212, 0.496, 0.027, "secondary", 0.76, 6.5)],
                [eye(0.580, 0.453, 0.037, "main", 1, 12),
                 eye(0.214, 0.500, 0.027, "secondary", 0.76, 6.5)],
                [eye(0.580, 0.449, 0.037, "main", 1, 12),
                 eye(0.216, 0.507, 0.027, "secondary", 0.76, 6.5)],
                [eye(0.580, 0.453, 0.037, "main", 1, 12),
                 eye(0.219, 0.502, 0.027, "secondary", 0.76, 6.5)],
            ]
        case "phone":
            frames = [
                [eye(0.690, 0.183, 0.043, "main", 1, 12),
                 eye(0.305, 0.281, 0.032, "secondary", 0.72, 6)],
                [eye(0.690, 0.174, 0.043, "main", 1, 12),
                 eye(0.301, 0.290, 0.032, "secondary", 0.72, 6)],
                [eye(0.752, 0.286, 0.043, "main", 1, 12),
                 eye(0.299, 0.281, 0.032, "secondary", 0.72, 6)],
                [eye(0.690, 0.185, 0.043, "main", 1, 12),
                 eye(0.301, 0.281, 0.032, "secondary", 0.72, 6)],
            ]
        case "book":
            frames = [
                [eye(0.656, 0.277, 0.041, "main", 1, 12),
                 eye(0.248, 0.388, 0.029, "secondary", 0.73, 6)],
                [eye(0.654, 0.268, 0.041, "main", 1, 12),
                 eye(0.248, 0.393, 0.029, "secondary", 0.73, 6)],
                [eye(0.652, 0.270, 0.041, "main", 1, 12),
                 eye(0.252, 0.384, 0.029, "secondary", 0.73, 6)],
                [eye(0.656, 0.279, 0.041, "main", 1, 12),
                 eye(0.250, 0.388, 0.029, "secondary", 0.73, 6)],
            ]
        case "rapid-notes":
            frames = [
                [eye(0.634, 0.154, 0.041, "main", 1, 13),
                 eye(0.212, 0.266, 0.029, "secondary", 0.70, 6)],
                [eye(0.636, 0.174, 0.041, "main", 1, 13),
                 eye(0.214, 0.279, 0.029, "secondary", 0.70, 6)],
                [eye(0.670, 0.210, 0.041, "main", 1, 13),
                 eye(0.246, 0.319, 0.029, "secondary", 0.70, 6)],
                [eye(0.636, 0.176, 0.041, "main", 1, 13),
                 eye(0.232, 0.283, 0.029, "secondary", 0.70, 6)],
            ]
        default:
            frames = []
        }
        return frames
    }

    private static var deformationProfileCache: [String: V4DeformationProfile] = [:]

    private static func deformationProfile(
        named name: String,
        clip: V4Clip
    ) -> V4DeformationProfile {
        // The atlas is immutable after load, so a clip name uniquely resolves
        // to one profile; cache it instead of rebuilding zone arrays per frame.
        if let cached = deformationProfileCache[name] { return cached }
        let profile = buildDeformationProfile(named: name, clip: clip)
        deformationProfileCache[name] = profile
        return profile
    }

    private static func buildDeformationProfile(
        named name: String,
        clip: V4Clip
    ) -> V4DeformationProfile {
        if let zones = clip.deformationZones, !zones.isEmpty {
            return V4DeformationProfile(
                tissueZones: zones,
                rigidZones: clip.rigidZones ?? []
            )
        }

        let mainStalk = V4DeformationZone(
            x: 0.54, y: 0.43, radiusX: 0.29, radiusY: 0.48, gain: 1
        )
        let secondaryStalk = V4DeformationZone(
            x: 0.23, y: 0.50, radiusX: 0.21, radiusY: 0.34, gain: 0.92
        )
        let base = V4DeformationZone(
            x: 0.45, y: 0.78, radiusX: 0.52, radiusY: 0.24, gain: 0.38
        )

        switch name {
        case "patrol-left", "idle-left":
            return V4DeformationProfile(
                tissueZones: [
                    V4DeformationZone(
                        x: 0.36, y: 0.43,
                        radiusX: 0.29, radiusY: 0.48, gain: 1
                    ),
                    V4DeformationZone(
                        x: 0.70, y: 0.50,
                        radiusX: 0.21, radiusY: 0.34, gain: 0.92
                    ),
                    V4DeformationZone(
                        x: 0.27, y: 0.58,
                        radiusX: 0.31, radiusY: 0.31, gain: 0.82
                    ),
                    V4DeformationZone(
                        x: 0.55, y: 0.78,
                        radiusX: 0.52, radiusY: 0.24, gain: 0.38
                    ),
                ],
                rigidZones: []
            )
        case "laptop":
            return V4DeformationProfile(
                tissueZones: [mainStalk, secondaryStalk, base],
                rigidZones: [
                    V4RigidZone(
                        minX: 0.60, minY: 0.65,
                        maxX: 1.0, maxY: 1.0,
                        feather: 0.045
                    )
                ]
            )
        case "phone":
            return V4DeformationProfile(
                tissueZones: [
                    V4DeformationZone(
                        x: 0.61, y: 0.32,
                        radiusX: 0.39, radiusY: 0.48, gain: 1
                    ),
                    secondaryStalk,
                    base,
                ],
                rigidZones: [
                    V4RigidZone(
                        minX: 0.57, minY: 0.41,
                        maxX: 0.84, maxY: 0.73,
                        feather: 0.04
                    )
                ]
            )
        case "book", "rapid-notes":
            return V4DeformationProfile(
                tissueZones: [mainStalk, secondaryStalk, base],
                rigidZones: [
                    V4RigidZone(
                        minX: 0.02, minY: 0.61,
                        maxX: 0.98, maxY: 0.91,
                        feather: 0.045
                    )
                ]
            )
        case "sharpen-tip":
            return V4DeformationProfile(
                tissueZones: [mainStalk, secondaryStalk, base],
                rigidZones: [
                    V4RigidZone(
                        minX: 0.47, minY: 0.18,
                        maxX: 1.0, maxY: 0.79,
                        feather: 0.035
                    )
                ]
            )
        default:
            if clip.containsProp {
                return V4DeformationProfile(
                    tissueZones: [mainStalk, secondaryStalk, base],
                    rigidZones: [
                        V4RigidZone(
                            minX: 0.52, minY: 0.52,
                            maxX: 1.0, maxY: 1.0,
                            feather: 0.05
                        )
                    ]
                )
            }
            return V4DeformationProfile(
                tissueZones: [
                    mainStalk,
                    secondaryStalk,
                    V4DeformationZone(
                        x: 0.73, y: 0.58,
                        radiusX: 0.31, radiusY: 0.31, gain: 0.82
                    ),
                    base,
                ],
                rigidZones: []
            )
        }
    }

    private func makeScene(
        selection: V4SpriteSelection,
        behavior: MigiBehaviorFrame,
        time: TimeInterval,
        deltaTime: TimeInterval
    ) -> V4SpriteScene {
        let phase = CGFloat(time)
        let breath = breathingPhase.advance(
            deltaTime: deltaTime, energy: behavior.bodyEnergy
        )
        let viewAspect = bounds.height / max(bounds.width, 1)
        var baseHeight: CGFloat = 0.91
        var baseWidth = baseHeight * viewAspect
        if baseWidth > 0.96 {
            baseWidth = 0.96
            baseHeight = baseWidth / max(viewAspect, 0.001)
        }
        // Prop-free tissue expands vertically while contracting laterally by
        // the reciprocal amount. This preserves perceived volume instead of
        // making the complete sprite inflate. Prop clips stay globally rigid;
        // their organic motion comes only from authored tissue zones.
        let globalBreath =
            selection.containsProp ? 0 : 0.0038 * breath
        let verticalScale = max(1 + globalBreath, 0.985)
        let size = CGSize(
            width: baseWidth / verticalScale,
            height: baseHeight * verticalScale
        )
        let center = CGPoint(
            x: 0.5,
            // Keep the lower baseline planted while breathing. Rigid prop
            // clips have no whole-image vertical bob at all.
            y: 0.5 + (size.height - baseHeight) * 0.5
        )

        reusableSpriteMesh.vertices.removeAll(keepingCapacity: true)
        reusableSpriteMesh.indices.removeAll(keepingCapacity: true)
        reusableEyeMesh.vertices.removeAll(keepingCapacity: true)

        let activeHandoff =
            wakeHandoff ?? ordinaryHandoff ?? authoredFrameHandoff
        if let activeHandoff {
            let progress = CGFloat(
                min(
                    max(
                        (time - activeHandoff.startedAt)
                            / max(activeHandoff.duration, 0.001),
                        0
                    ),
                    1
                )
            )
            let baseTransitionTuning = Self.organicTuning(
                named: selection.clipName,
                containsProp:
                    selection.containsProp
                        || activeHandoff.previous.containsProp
            )
            let transitionTuning =
                activeHandoff.kind == .authoredFrame
                    ? baseTransitionTuning.forAuthoredFrameHandoff()
                    : baseTransitionTuning
            let rigidSwitch: (CGFloat, CGFloat)
            switch activeHandoff.kind {
            case .urgent:
                rigidSwitch = (0.34, 0.48)
            case .authoredFrame:
                rigidSwitch = (0.42, 0.56)
            case .wake, .sleep, .semantic:
                rigidSwitch = (0.46, 0.60)
            }
            let outgoing = MigiTissueTransition(
                progress: progress,
                role: .outgoing,
                tuning: transitionTuning,
                rigidSwitchStart: rigidSwitch.0,
                rigidSwitchEnd: rigidSwitch.1
            )
            let incoming = MigiTissueTransition(
                progress: progress,
                role: .incoming,
                tuning: transitionTuning,
                rigidSwitchStart: rigidSwitch.0,
                rigidSwitchEnd: rigidSwitch.1
            )
            let transitionRootAxis = Self.transitionRootAxis(
                named: selection.clipName
            )

            appendSprite(
                activeHandoff.previous,
                center: center,
                size: size,
                phase: phase,
                behavior: behavior,
                transition: outgoing,
                transitionRootAxis: transitionRootAxis
            )
            appendSprite(
                selection,
                center: center,
                size: size,
                phase: phase,
                behavior: behavior,
                transition: incoming,
                transitionRootAxis: transitionRootAxis
            )
            // The tissue layers are premultiplied and added as one opacity-
            // conserving composite. Eyes are identity-critical organs, so keep
            // exactly one tracked set and switch it with the dominant body.
            let eyeSelection =
                progress < 0.5 ? activeHandoff.previous : selection
            appendPointerEyes(
                for: eyeSelection,
                center: center,
                size: size,
                phase: phase,
                deltaTime: deltaTime,
                behavior: behavior,
                transition: progress < 0.5 ? outgoing : incoming,
                transitionRootAxis: transitionRootAxis,
                trackingNamespace: nil
            )
        } else {
            let transitionRootAxis = Self.transitionRootAxis(
                named: selection.clipName
            )
            appendSprite(
                selection,
                center: center,
                size: size,
                phase: phase,
                behavior: behavior,
                transition: nil,
                transitionRootAxis: transitionRootAxis
            )
            appendPointerEyes(
                for: selection,
                center: center,
                size: size,
                phase: phase,
                deltaTime: deltaTime,
                behavior: behavior,
                transition: nil,
                transitionRootAxis: transitionRootAxis,
                trackingNamespace: nil
            )
        }

        return V4SpriteScene(
            sprite: reusableSpriteMesh,
            eyes: reusableEyeMesh,
            usesTransitionCompositing: activeHandoff != nil
        )
    }

    private struct OrganicTuningKey: Hashable {
        let clipName: String
        let containsProp: Bool
    }

    private static var organicTuningCache: [OrganicTuningKey: MigiOrganicMotionTuning] = [:]

    private static func organicTuning(
        named clipName: String,
        containsProp: Bool
    ) -> MigiOrganicMotionTuning {
        let key = OrganicTuningKey(clipName: clipName, containsProp: containsProp)
        if let cached = organicTuningCache[key] { return cached }
        let tuning = MigiOrganicMotionTuning.preset(
            for: clipName,
            containsProp: containsProp
        )
        organicTuningCache[key] = tuning
        return tuning
    }

    private func appendSprite(
        _ selection: V4SpriteSelection,
        center: CGPoint,
        size: CGSize,
        phase: CGFloat,
        behavior: MigiBehaviorFrame,
        transition: MigiTissueTransition?,
        transitionRootAxis: V4TransitionRootAxis
    ) {
        let tuning = Self.organicTuning(
            named: selection.clipName,
            containsProp: selection.containsProp
        )
        reusableSpriteMesh.addCell(
            row: selection.row,
            column: selection.column,
            columns: atlas.columns,
            rows: atlas.rows,
            mirrored: selection.mirrored,
            center: center,
            size: size,
            time: phase,
            deformation: deformationAmount(
                for: selection,
                behavior: behavior,
                tuning: tuning
            ) * organicMotionScale,
            deformationProfile: selection.deformationProfile,
            motionTuning: tuning,
            transition: transition,
            transitionRootAxis: transitionRootAxis
        )
    }

    private func appendPointerEyes(
        for selection: V4SpriteSelection,
        center: CGPoint,
        size: CGSize,
        phase: CGFloat,
        deltaTime: TimeInterval,
        behavior: MigiBehaviorFrame,
        transition: MigiTissueTransition?,
        transitionRootAxis: V4TransitionRootAxis,
        trackingNamespace: String?
    ) {
        guard selection.clipName != "complete-sleep",
              selection.pointerEyes,
              !selection.eyeAnchors.isEmpty
        else {
            return
        }
        let tuning = Self.organicTuning(
            named: selection.clipName,
            containsProp: selection.containsProp
        )
        let deformation = deformationAmount(
            for: selection,
            behavior: behavior,
            tuning: tuning
        ) * organicMotionScale
        let trackedGazes = updateTrackedEyeGazes(
            for: selection.eyeAnchors,
            deltaTime: deltaTime,
            time: phase,
            namespace: trackingNamespace
        )
        for (index, anchor) in selection.eyeAnchors.enumerated() {
            let displayX = selection.mirrored ? 1 - anchor.x : anchor.x
            let rigidity = selection.deformationProfile.rigidityWeight(
                sourceX: anchor.x,
                sourceY: anchor.y
            )
            let visibility =
                transition?.organVisibility(
                    rootDistance: Self.transitionRootDistance(
                        for: anchor,
                        axis: transitionRootAxis
                    ),
                    displayX: displayX,
                    rigidity: rigidity
                ) ?? 1
            guard visibility > 0.002 else { continue }
            let tissueOffset = selection.deformationProfile.offset(
                sourceX: anchor.x,
                sourceY: anchor.y,
                displayX: displayX,
                mirrored: selection.mirrored,
                time: phase,
                amplitude: deformation,
                tuning: tuning
            )
            let transitionOffset =
                transition?.flowOffset(
                    rootDistance: Self.transitionRootDistance(
                        for: anchor,
                        axis: transitionRootAxis
                    ),
                    displayX: displayX,
                    rigidity: rigidity
                ) ?? .zero
            addPointerEye(
                anchor: anchor,
                mirrored: selection.mirrored,
                spriteCenter: center,
                spriteSize: size,
                gaze: trackedGazes.indices.contains(index)
                    ? trackedGazes[index]
                    : gaze,
                tissueOffset: CGPoint(
                    x: tissueOffset.x + transitionOffset.x,
                    y: tissueOffset.y + transitionOffset.y
                ),
                blink: blinkCurve(
                    time:
                        phase
                        - Double(min(index, 3)) * Self.blinkStaggerPerEye
                ),
                alpha: visibility,
                mesh: &reusableEyeMesh
            )
        }
    }

    /// Tissue calm scales: being held suppresses fidget; accumulated sleep
    /// debt lowers overall amplitude. Neither touches authored identity.
    private var organicMotionScale: CGFloat {
        (1 - 0.25 * dragDispleasure) * (1 - 0.20 * currentFatigue)
    }

    private func deformationAmount(
        for selection: V4SpriteSelection,
        behavior: MigiBehaviorFrame,
        tuning: MigiOrganicMotionTuning
    ) -> CGFloat {
        let base: CGFloat
        switch selection.clipName {
        case "dormant":
            base = 0.0018 + 0.0008 * behavior.bodyEnergy
        case "sharpen-tip":
            base = 0.0030 + 0.0012 * behavior.bodyEnergy
        default:
            base =
                selection.containsProp
                    ? 0.0030 + 0.0013 * behavior.bodyEnergy
                    : 0.0045 + 0.0020 * behavior.bodyEnergy
        }
        return base * tuning.amplitudeScale
    }

    private func updateTrackedEyeGazes(
        for anchors: [V4EyeAnchor],
        deltaTime: TimeInterval,
        time: TimeInterval,
        namespace: String? = nil
    ) -> [SIMD2<Double>] {
        trackedEyesAreChasing = false
        return anchors.enumerated().map { index, anchor in
            let baseKey = anchor.trackingID ?? "eye-\(index)"
            let key = namespace.map { "\($0):\(baseKey)" } ?? baseKey
            let defaultGain: CGFloat = index == 0 ? 1 : max(0.56, 0.78 - CGFloat(index - 1) * 0.10)
            let horizontalGain = anchor.trackingGain ?? defaultGain
            let verticalGain = anchor.verticalGain ?? min(horizontalGain + 0.06, 1)
            let cursorTarget = SIMD2<Double>(
                gaze.x * Double(horizontalGain),
                gaze.y * Double(verticalGain)
            )
            let target: SIMD2<Double>
            if index == 0 || gazeConvergence >= 0.999 {
                // The primary eye never leaves the pointer; attention cues,
                // sleep phases and deterministic QA keep every eye converged.
                target = cursorTarget
            } else {
                let scanTarget: SIMD2<Double>
                if readingScanActive {
                    // Reading Migi sweeps lines, not the mouse: a canon page
                    // scan with per-eye staggered rhythm and saccade return.
                    scanTarget = readingScanTarget(index: index, time: time)
                } else {
                    scanTarget = autonomousScanTarget(
                        namespace: namespace,
                        baseKey: baseKey,
                        index: index,
                        time: time
                    )
                }
                target =
                    cursorTarget * gazeConvergence
                    + scanTarget * (1 - gazeConvergence)
            }
            var state =
                eyeTrackingStates[key]
                    ?? V4EyeTrackingState(value: target, velocity: .zero)
            let stiffness = Double(
                max(
                    anchor.trackingStiffness
                        ?? (index == 0 ? 12 : max(4.5, 7.0 - CGFloat(index))),
                    1
                )
            )
            MigiDampedMotion.advance(
                value: &state.value, velocity: &state.velocity, target: target,
                stiffness: stiffness, deltaTime: deltaTime
            )
            trackedEyesAreChasing = trackedEyesAreChasing
                || simd_length(target - state.value) > 0.012
                || simd_length(state.velocity) > 0.018
            eyeTrackingStates[key] = state
            return state.value
        }
    }

    /// Line-by-line page sweep for reading poses. Each branch eye keeps its
    /// own rhythm; the last 12% of every line is the saccade back to the
    /// start of the next one.
    private func readingScanTarget(index: Int, time: TimeInterval) -> SIMD2<Double> {
        let phase = Double(index - 1) * 0.35
        let t = time + phase
        let linePeriod: TimeInterval = 1.9
        let lineCount = 4
        let raw = t / linePeriod
        let lineIndex = Double(Int(floor(raw)) % lineCount)
        let frac = raw - floor(raw)
        let sweep = frac < 0.88 ? frac / 0.88 : 0
        let eased = sweep * sweep * (3 - 2 * sweep)
        let x = -0.52 + 1.04 * eased
        let y = 0.10 - lineIndex * 0.09
        return SIMD2<Double>(x, y)
    }

    /// branch eye slowly sweeps its own sector. Motion is a layered,
    /// low-frequency wander driven by a stable per-eye phase; parallel agent
    /// work fans branch eyes toward distinct sectors, the way Migi divides
    /// attention across multiple threats.
    private func autonomousScanTarget(
        namespace: String?,
        baseKey: String,
        index: Int,
        time: TimeInterval
    ) -> SIMD2<Double> {
        // Stable FNV-1a hash keeps per-eye phases deterministic without
        // depending on Swift's per-process `hashValue` randomization.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in ((namespace ?? "") + "/" + baseKey).utf8 {
            hash ^= UInt64(byte)
            hash &*= 0x0000_0100_0000_01b3
        }
        let phaseH = Double(hash & 0xFFFF) / 65535 * .pi * 2
        let phaseV = Double((hash >> 16) & 0xFFFF) / 65535 * .pi * 2
        var scanX =
            0.34 * sin(time * 0.21 + phaseH)
            + 0.14 * sin(time * 0.53 + phaseV)
        var scanY =
            0.26 * sin(time * 0.17 + phaseV * 1.7 + 1.1)
            + 0.11 * cos(time * 0.43 + phaseH * 0.6)
        if activeAgentCount > 1 {
            let side = index % 2 == 0 ? -1.0 : 1.0
            let tier = Double(index / 2)
            scanX += side * (0.16 + 0.10 * tier)
            scanY += 0.05 * tier - 0.03
        }
        var target = SIMD2<Double>(scanX, scanY)
        let length = simd_length(target)
        if length > 0.8 {
            target *= 0.8 / length
        }
        return target
    }

    /// Advances blink bookkeeping once per frame with unshifted time. A new
    /// blink always re-anchors both timestamps so the curve restarts clean.
    private func updateBlinkState(
        for behavior: MigiBehaviorFrame,
        time: TimeInterval
    ) {
        if behavior.blinkWanted {
            if blinkStartedAt == nil || blinkReleaseStartedAt != nil {
                blinkStartedAt = time
            }
            blinkReleaseStartedAt = nil
        } else if blinkStartedAt != nil, blinkReleaseStartedAt == nil {
            blinkReleaseStartedAt = time
        }
    }

    /// Pure blink-curve sample; callers shift `time` by an eye's stagger
    /// offset. Canon blinks are slow and deliberate rather than conversational.
    private func blinkCurve(
        time: TimeInterval
    ) -> CGFloat {
        // Sample the delayed eye's own time, including its closing phase after
        // the leading eye has started reopening. A global blinkWanted branch
        // snapped trailing eyes straight to fully closed at that boundary.
        MigiBlinkEnvelope.sample(
            startedAt: blinkStartedAt,
            releasedAt: blinkReleaseStartedAt,
            time: time
        )
    }

    private func addPointerEye(
        anchor: V4EyeAnchor,
        mirrored: Bool,
        spriteCenter: CGPoint,
        spriteSize: CGSize,
        gaze: SIMD2<Double>,
        tissueOffset: CGPoint,
        blink: CGFloat,
        alpha: CGFloat = 1,
        mesh: inout FullColorMesh
    ) {
        let anchorX = mirrored ? 1 - anchor.x : anchor.x
        let center = CGPoint(
            x: spriteCenter.x + (anchorX - 0.5) * spriteSize.width
                + tissueOffset.x,
            y: spriteCenter.y + (0.5 - anchor.y) * spriteSize.height
                + tissueOffset.y
        )
        let sourceRadius =
            anchor.radius * min(spriteSize.width, spriteSize.height)
        // The white must fully cover the authored eyeball in the atlas frame;
        // otherwise the painted iris underneath leaks past the procedural
        // overlay at the rim. Socket shading stays outside this radius.
        let whiteRadius = sourceRadius * 0.94
        // Being dragged narrows the eye slightly — tolerated, and noted.
        let pupilPinch = 1 - 0.15 * dragDispleasure
        let gazeOffset = CGPoint(
            x: CGFloat(gaze.x) * sourceRadius * 0.36,
            y: CGFloat(gaze.y) * sourceRadius * 0.36
        )
        let irisCenter = CGPoint(
            x: center.x + gazeOffset.x,
            y: center.y + gazeOffset.y
        )

        mesh.addEllipse(
            center: center,
            rx: whiteRadius,
            ry: whiteRadius * 0.94,
            color: .eyeWhite.withAlphaMultiplier(alpha),
            segments: 32
        )
        // Canon eyes are a plain dark disc on white — no colored iris, no
        // glossy cartoon sparkle. One faint static fleck keeps the surface
        // readable at small sizes without softening the stare.
        let pupilRadius = sourceRadius * 0.44 * pupilPinch
        mesh.addEllipse(
            center: irisCenter,
            rx: pupilRadius,
            ry: pupilRadius,
            color: .pupil.withAlphaMultiplier(alpha),
            segments: 28
        )
        mesh.addEllipse(
            center: CGPoint(
                x: irisCenter.x - sourceRadius * 0.10,
                y: irisCenter.y + sourceRadius * 0.11
            ),
            rx: sourceRadius * 0.05,
            ry: sourceRadius * 0.05,
            color: .highlight.withAlphaMultiplier(alpha * 0.85),
            segments: 12
        )

        if blink > 0.001 {
            let lids = MigiEyelidShape(closure: blink)
            let lidRadiusX = whiteRadius * 1.015
            let lidRadiusY = whiteRadius * 0.94 * 1.015
            // Opaque geometry moves over the intact eye. Fading flesh across
            // the whole eyeball made the pupil dissolve and left a white rim.
            mesh.addEllipticalCap(
                center: center, rx: lidRadiusX, ry: lidRadiusY,
                cut: lids.upperCut, upper: true,
                color: .eyelidFlesh.withAlphaMultiplier(alpha)
            )
            mesh.addEllipticalCap(
                center: center, rx: lidRadiusX, ry: lidRadiusY,
                cut: lids.lowerCut, upper: false,
                color: .eyelidFlesh.withAlphaMultiplier(alpha)
            )
            let crease = MigiOrganicMath.smoothstep(edge0: 0.86, edge1: 1, value: blink)
            if crease > 0 {
                mesh.addEllipse(
                    center: CGPoint(x: center.x, y: center.y - lidRadiusY * 0.12),
                    rx: sourceRadius * 0.72,
                    ry: max(sourceRadius * 0.025, 0.00025),
                    color: .eyelidCrease.withAlphaMultiplier(alpha * crease),
                    segments: 24
                )
            }
        }
    }

    private func reserveBufferSlot() -> Int? {
        // Never wait for the GPU from the display callback. If all three slots
        // are still owned by submitted command buffers, skip this visual frame
        // and let the next display-link callback try again.
        guard bufferSlotLock.try() else { return nil }
        defer { bufferSlotLock.unlock() }

        for distance in 1...Self.inFlightBufferCount {
            let slot = (activeBufferSlot + distance) % Self.inFlightBufferCount
            guard !bufferSlotsInUse[slot] else { continue }
            bufferSlotsInUse[slot] = true
            activeBufferSlot = slot
            return slot
        }
        return nil
    }

    private func releaseBufferSlot(_ slot: Int) {
        bufferSlotLock.lock()
        defer { bufferSlotLock.unlock() }
        guard bufferSlotsInUse.indices.contains(slot) else { return }
        bufferSlotsInUse[slot] = false
    }

    private func prepareGPUScene(
        _ scene: V4SpriteScene,
        slot: Int
    ) -> V4GPUScene? {
        guard let device else { return nil }

        guard let sprite = Self.upload(
            scene.sprite.vertices,
            device: device,
            slot: slot,
            buffers: &spriteVertexBuffers
        ) else {
            return nil
        }
        let spriteIndices = Self.upload(
            scene.sprite.indices,
            device: device,
            slot: slot,
            buffers: &spriteIndexBuffers
        )
        let eyes = Self.upload(
            scene.eyes.vertices,
            device: device,
            slot: slot,
            buffers: &eyeVertexBuffers
        )
        return V4GPUScene(
            sprite: V4GPUMesh(
                buffer: sprite.buffer,
                vertexCount: sprite.count,
                indexBuffer: spriteIndices?.buffer,
                indexCount: spriteIndices?.count ?? 0
            ),
            eyes: eyes.map {
                V4GPUMesh(buffer: $0.buffer, vertexCount: $0.count)
            },
            usesTransitionCompositing: scene.usesTransitionCompositing
        )
    }

    private static func upload<Vertex>(
        _ elements: [Vertex],
        device: MTLDevice,
        slot: Int,
        buffers: inout [MTLBuffer?]
    ) -> (buffer: MTLBuffer, count: Int)? {
        guard !elements.isEmpty else { return nil }
        let byteCount = elements.count * MemoryLayout<Vertex>.stride
        if buffers[slot]?.length ?? 0 < byteCount {
            buffers[slot] = device.makeBuffer(
                length: byteCount,
                options: .storageModeShared
            )
        }
        guard let buffer = buffers[slot] else { return nil }
        elements.withUnsafeBufferPointer { pointer in
            guard let baseAddress = pointer.baseAddress else { return }
            buffer.contents().copyMemory(
                from: baseAddress,
                byteCount: byteCount
            )
        }
        return (buffer, elements.count)
    }

    private func encodeSprite(
        _ mesh: V4GPUMesh,
        transitionCompositing: Bool,
        with encoder: MTLRenderCommandEncoder
    ) {
        encoder.setRenderPipelineState(
            transitionCompositing
                ? transitionTexturePipeline
                : texturePipeline
        )
        encoder.setFragmentTexture(spriteTexture, index: 0)
        encoder.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
        if mesh.indexCount > 0, let indexBuffer = mesh.indexBuffer {
            encoder.drawIndexedPrimitives(
                type: .triangle,
                indexCount: mesh.indexCount,
                indexType: .uint16,
                indexBuffer: indexBuffer,
                indexBufferOffset: 0
            )
        } else {
            encoder.drawPrimitives(
                type: .triangle,
                vertexStart: 0,
                vertexCount: mesh.vertexCount
            )
        }
    }

    private func encodeEyes(
        _ mesh: V4GPUMesh,
        with encoder: MTLRenderCommandEncoder
    ) {
        encoder.setRenderPipelineState(colorPipeline)
        encoder.setVertexBuffer(mesh.buffer, offset: 0, index: 0)
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: mesh.vertexCount
        )
    }

    private func encodeQACapture(
        scene: V4GPUScene,
        pixelWidth: Int,
        pixelHeight: Int,
        commandBuffer: MTLCommandBuffer,
        request: QACaptureRequest
    ) -> QACaptureEncodingResult {
        guard let device else {
            return .failure("Metal device is unavailable")
        }
        guard pixelWidth > 0, pixelHeight > 0 else {
            return .failure("drawable has an invalid size \(pixelWidth)x\(pixelHeight)")
        }

        let resolvedDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: colorPixelFormat,
            width: pixelWidth,
            height: pixelHeight,
            mipmapped: false
        )
        resolvedDescriptor.storageMode = .private
        resolvedDescriptor.usage = [.renderTarget]
        guard let resolvedTexture = device.makeTexture(descriptor: resolvedDescriptor) else {
            return .failure("unable to allocate the resolved capture texture")
        }

        let renderTarget: MTLTexture
        if sampleCount > 1 {
            let multisampleDescriptor = MTLTextureDescriptor()
            multisampleDescriptor.textureType = .type2DMultisample
            multisampleDescriptor.pixelFormat = colorPixelFormat
            multisampleDescriptor.width = pixelWidth
            multisampleDescriptor.height = pixelHeight
            multisampleDescriptor.sampleCount = sampleCount
            multisampleDescriptor.storageMode = .private
            multisampleDescriptor.usage = [.renderTarget]
            guard let multisampleTexture = device.makeTexture(descriptor: multisampleDescriptor) else {
                return .failure("unable to allocate the multisample capture texture")
            }
            renderTarget = multisampleTexture
        } else {
            renderTarget = resolvedTexture
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = renderTarget
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = clearColor
        if sampleCount > 1 {
            pass.colorAttachments[0].resolveTexture = resolvedTexture
            pass.colorAttachments[0].storeAction = .multisampleResolve
        } else {
            pass.colorAttachments[0].storeAction = .store
        }

        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return .failure("unable to create the capture render encoder")
        }
        encodeSprite(
            scene.sprite,
            transitionCompositing: scene.usesTransitionCompositing,
            with: encoder
        )
        if let eyes = scene.eyes {
            encodeEyes(eyes, with: encoder)
        }
        encoder.endEncoding()

        let bytesPerPixel = 4
        let bytesPerRow = pixelWidth * bytesPerPixel
        let byteCount = bytesPerRow * pixelHeight
        guard let buffer = device.makeBuffer(
            length: byteCount,
            options: .storageModeShared
        ) else {
            return .failure("unable to allocate the capture readback buffer")
        }
        guard let blit = commandBuffer.makeBlitCommandEncoder() else {
            return .failure("unable to create the capture blit encoder")
        }

        blit.copy(
            from: resolvedTexture,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: pixelWidth, height: pixelHeight, depth: 1),
            to: buffer,
            destinationOffset: 0,
            destinationBytesPerRow: bytesPerRow,
            destinationBytesPerImage: byteCount
        )
        blit.endEncoding()

        return .success(
            QACaptureSubmission(
                request: request,
                buffer: buffer,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight,
                bytesPerRow: bytesPerRow,
                byteCount: byteCount
            )
        )
    }

    private func finishQACapture(
        _ submission: QACaptureSubmission,
        commandBuffer: MTLCommandBuffer
    ) {
        guard commandBuffer.status == .completed else {
            let detail = commandBuffer.error?.localizedDescription
                ?? "command buffer ended with status \(commandBuffer.status.rawValue)"
            retryQACapture(submission.request, reason: "GPU capture failed: \(detail)")
            return
        }

        let data = Data(
            bytes: submission.buffer.contents(),
            count: submission.byteCount
        )
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                  width: submission.pixelWidth,
                  height: submission.pixelHeight,
                  bitsPerComponent: 8,
                  bitsPerPixel: 32,
                  bytesPerRow: submission.bytesPerRow,
                  space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: [
                      CGBitmapInfo.byteOrder32Little,
                      CGBitmapInfo(
                          rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue
                      )
                  ],
                  provider: provider,
                  decode: nil,
                  shouldInterpolate: true,
                  intent: .defaultIntent
              ),
              let png = NSBitmapImageRep(cgImage: image)
                .representation(using: .png, properties: [:])
        else {
            retryQACapture(
                submission.request,
                reason: "unable to encode the GPU readback as PNG"
            )
            return
        }

        do {
            try png.write(
                to: submission.request.destinationURL,
                options: .atomic
            )
        } catch {
            retryQACapture(
                submission.request,
                reason: "unable to write PNG: \(error.localizedDescription)"
            )
        }
    }

    private func recordQACaptureFailure(
        for request: QACaptureRequest,
        reason: String
    ) {
        let nextAttempt = request.failedAttempts + 1
        if nextAttempt < Self.maximumQACaptureAttempts {
            pendingQACapture = QACaptureRequest(
                destinationURL: request.destinationURL,
                failedAttempts: nextAttempt
            )
            fputs(
                "Migi QA capture attempt \(nextAttempt) failed: \(reason); retrying.\n",
                stderr
            )
        } else {
            pendingQACapture = nil
            fputs(
                "Migi QA capture failed after \(nextAttempt) attempts: \(reason).\n",
                stderr
            )
        }
    }

    private func retryQACapture(
        _ request: QACaptureRequest,
        reason: String
    ) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            guard self.pendingQACapture == nil else {
                fputs(
                    "Migi QA capture failed: \(reason); a newer request is pending.\n",
                    stderr
                )
                return
            }
            self.recordQACaptureFailure(for: request, reason: reason)
            if self.pendingQACapture != nil {
                self.draw()
            }
        }
    }

    private static func loadAtlasResources(
        device: MTLDevice
    ) -> (texture: MTLTexture, manifest: V4AtlasManifest) {
        let installedBundle = Bundle.main.resourceURL?
            .appendingPathComponent("MigiAdvanced_MigiAdvanced.bundle", isDirectory: true)

        func resourceURL(name: String, extension fileExtension: String) -> URL? {
            let installed = installedBundle?
                .appendingPathComponent("\(name).\(fileExtension)", isDirectory: false)
            if let installed,
               FileManager.default.fileExists(atPath: installed.path)
            {
                return installed
            }
            return Bundle.module.url(forResource: name, withExtension: fileExtension)
        }

        // A BC7 KTX1 cut the resident atlas copy from 135 MB to 34 MB. PNG
        // stays as the fallback so the app still runs if the KTX is missing
        // (e.g. older installs).
        guard let manifestURL = resourceURL(name: "migi-v4-atlas", extension: "json")
        else {
            fatalError("The coherent Migi v4 atlas resources are missing.")
        }

        let manifest: V4AtlasManifest
        do {
            manifest = try JSONDecoder().decode(
                V4AtlasManifest.self,
                from: Data(contentsOf: manifestURL)
            )
        } catch {
            fatalError("Unable to decode the Migi v4 atlas manifest: \(error)")
        }

        let loader = MTKTextureLoader(device: device)
        let texture: MTLTexture
        if let ktxURL = resourceURL(name: "migi-v4-atlas", extension: "ktx") {
            do {
                // Block-compressed KTX files are stored bottom-up; the
                // topLeft origin flip is unsupported for block formats and
                // would make the loader emit the texture bottom-up anyway,
                // matching the PNG's topLeft orientation as loaded.
                texture = try loader.newTexture(
                    URL: ktxURL,
                    options: [.SRGB: true]
                )
            } catch {
                fatalError("Unable to load the Migi v4 BC7 atlas KTX: \(error)")
            }
        } else if let textureURL = resourceURL(name: "migi-v4-atlas", extension: "png") {
            do {
                texture = try loader.newTexture(
                    URL: textureURL,
                    options: [
                        .origin: MTKTextureLoader.Origin.topLeft,
                        .SRGB: true
                    ]
                )
            } catch {
                fatalError("Unable to load the Migi v4 atlas PNG: \(error)")
            }
        } else {
            fatalError("The Migi v4 atlas texture is missing.")
        }
        guard manifest.version >= 1,
              manifest.columns > 0,
              manifest.rows > 0,
              manifest.cellWidth > 0,
              manifest.cellHeight > 0,
              texture.width == manifest.columns * manifest.cellWidth,
              texture.height == manifest.rows * manifest.cellHeight
        else {
            fatalError(
                "Migi v4 atlas dimensions do not match its manifest: "
                    + "\(texture.width)x\(texture.height), "
                    + "\(manifest.columns)x\(manifest.rows) cells"
            )
        }
            for (name, clip) in manifest.clips {
                let frameDurationsAreValid =
                    clip.frameDurations == nil
                        || (
                            clip.frameDurations?.count == clip.frameCount
                                && clip.frameDurations?.allSatisfy {
                                    $0.isFinite && $0 > 0
                                } == true
                        )
                let eyeFallbacksAreValid =
                    clip.eyeFallbacks == nil
                        || clip.eyeFallbacks?.count == clip.frameCount
                let loopRangeIsValid =
                    clip.loopRange == nil || clip.loopRange?.count == 2
                guard clip.row >= 0,
                      clip.row < manifest.rows,
                      clip.columnOffset >= 0,
                      clip.frameCount > 0,
                      clip.columnOffset + clip.frameCount <= manifest.columns,
                      clip.frameDuration.isFinite,
                      clip.frameDuration > 0,
                      clip.eyes.count == clip.frameCount,
                      frameDurationsAreValid,
                      eyeFallbacksAreValid,
                      loopRangeIsValid
                else {
                    fatalError("Invalid Migi v4 clip manifest entry: \(name)")
                }
                for reference in [
                    clip.leftClip,
                    clip.rightClip,
                    clip.turnClip,
                    clip.turnLeftClip,
                    clip.turnRightClip,
                ].compactMap({ $0 }) {
                    guard manifest.clips[reference] != nil else {
                        fatalError(
                            "Migi v4 clip \(name) references missing clip \(reference)."
                        )
                    }
                }
            }
            return (texture, manifest)
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String,
        sampleCount: Int,
        blendMode: V4PipelineBlendMode = .sourceOver
    ) -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        switch blendMode {
        case .sourceOver:
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor =
                .oneMinusSourceAlpha
            descriptor.colorAttachments[0].destinationAlphaBlendFactor =
                .oneMinusSourceAlpha
        case .additivePremultiplied:
            // Outgoing and incoming tissue carry complementary visibility.
            // Adding premultiplied samples gives C_old*(1-p)+C_new*p and an
            // opacity of one where both authored silhouettes overlap.
            descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
            descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
            descriptor.colorAttachments[0].destinationRGBBlendFactor = .one
            descriptor.colorAttachments[0].destinationAlphaBlendFactor = .one
        }
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Unable to create the Migi v4 render pipeline: \(error)")
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct FullSpriteVertex {
        float2 position;
        float2 uv;
        float alpha;
    };

    struct FullSpriteOut {
        float4 position [[position]];
        float2 uv;
        float alpha;
    };

    vertex FullSpriteOut fullSpriteVertex(
        const device FullSpriteVertex *vertices [[buffer(0)]],
        uint vertexID [[vertex_id]]
    ) {
        FullSpriteOut out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.uv = vertices[vertexID].uv;
        out.alpha = vertices[vertexID].alpha;
        return out;
    }

    fragment float4 fullSpriteFragment(
        FullSpriteOut in [[stage_in]],
        texture2d<float> spriteTexture [[texture(0)]]
    ) {
        constexpr sampler spriteSampler(
            mag_filter::linear,
            min_filter::linear,
            mip_filter::linear,
            address::clamp_to_edge
        );
        float4 color = spriteTexture.sample(spriteSampler, in.uv);
        color.a *= in.alpha;
        return color;
    }

    fragment float4 fullSpritePremultipliedFragment(
        FullSpriteOut in [[stage_in]],
        texture2d<float> spriteTexture [[texture(0)]]
    ) {
        constexpr sampler spriteSampler(
            mag_filter::linear,
            min_filter::linear,
            mip_filter::linear,
            address::clamp_to_edge
        );
        float4 color = spriteTexture.sample(spriteSampler, in.uv);
        float alpha = color.a * in.alpha;
        return float4(color.rgb * alpha, alpha);
    }

    struct FullColorVertex {
        float2 position;
        float4 color;
    };

    struct FullColorOut {
        float4 position [[position]];
        float4 color;
    };

    vertex FullColorOut fullColorVertex(
        const device FullColorVertex *vertices [[buffer(0)]],
        uint vertexID [[vertex_id]]
    ) {
        FullColorOut out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.color = vertices[vertexID].color;
        return out;
    }

    fragment float4 fullColorFragment(FullColorOut in [[stage_in]]) {
        return in.color;
    }
    """
}

private struct V4AtlasManifest: Decodable {
    let version: Int
    let columns: Int
    let rows: Int
    let cellWidth: Int
    let cellHeight: Int
    let clips: [String: V4Clip]

    private enum CodingKeys: String, CodingKey {
        case version
        case columns
        case rows
        case cellWidth = "cell_width"
        case cellHeight = "cell_height"
        case clips
    }
}

private struct V4Clip: Decodable {
    let row: Int
    let columnOffset: Int
    let frameCount: Int
    let frameDuration: Double
    let frameDurations: [Double]?
    let playbackMode: V4PlaybackMode?
    let holdFrame: Int?
    let holdDuration: Double?
    let loopRange: [Int]?
    let pointerEyes: Bool
    let containsProp: Bool
    let eyes: [[V4EyeAnchor]]
    let eyeFallbacks: [[V4EyeAnchor]]?
    let leftClip: String?
    let rightClip: String?
    let turnClip: String?
    let turnLeftClip: String?
    let turnRightClip: String?
    let turnLeftReversed: Bool
    let turnRightReversed: Bool
    let mirrorPolicy: V4MirrorPolicy
    let deformationZones: [V4DeformationZone]?
    let rigidZones: [V4RigidZone]?

    private enum CodingKeys: String, CodingKey {
        case row
        case columnOffset = "column_offset"
        case frameCount = "frame_count"
        case frameDuration = "frame_duration"
        case frameDurations = "frame_durations"
        case playbackMode = "playback_mode"
        case holdFrame = "hold_frame"
        case holdDuration = "hold_duration"
        case loopRange = "loop_range"
        case pointerEyes = "pointer_eyes"
        case containsProp = "contains_prop"
        case eyes
        case eyeFallbacks = "eye_fallbacks"
        case leftClip = "left_clip"
        case rightClip = "right_clip"
        case turnClip = "turn_clip"
        case turnLeftClip = "turn_left_clip"
        case turnRightClip = "turn_right_clip"
        case turnLeftReversed = "turn_left_reversed"
        case turnRightReversed = "turn_right_reversed"
        case mirrorPolicy = "mirror_policy"
        case deformationZones = "deformation_zones"
        case rigidZones = "rigid_zones"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        row = try container.decode(Int.self, forKey: .row)
        columnOffset =
            try container.decodeIfPresent(Int.self, forKey: .columnOffset) ?? 0
        frameCount = try container.decode(Int.self, forKey: .frameCount)
        frameDuration =
            try container.decodeIfPresent(Double.self, forKey: .frameDuration) ?? 0.2
        frameDurations =
            try container.decodeIfPresent([Double].self, forKey: .frameDurations)
        playbackMode =
            try container.decodeIfPresent(V4PlaybackMode.self, forKey: .playbackMode)
        holdFrame = try container.decodeIfPresent(Int.self, forKey: .holdFrame)
        holdDuration =
            try container.decodeIfPresent(Double.self, forKey: .holdDuration)
        loopRange = try container.decodeIfPresent([Int].self, forKey: .loopRange)
        pointerEyes =
            try container.decodeIfPresent(Bool.self, forKey: .pointerEyes) ?? false
        containsProp =
            try container.decodeIfPresent(Bool.self, forKey: .containsProp) ?? false
        eyes =
            try container.decodeIfPresent([[V4EyeAnchor]].self, forKey: .eyes)
                ?? Array(repeating: [], count: max(frameCount, 0))
        eyeFallbacks =
            try container.decodeIfPresent([[V4EyeAnchor]].self, forKey: .eyeFallbacks)
        leftClip = try container.decodeIfPresent(String.self, forKey: .leftClip)
        rightClip = try container.decodeIfPresent(String.self, forKey: .rightClip)
        turnClip = try container.decodeIfPresent(String.self, forKey: .turnClip)
        turnLeftClip =
            try container.decodeIfPresent(String.self, forKey: .turnLeftClip)
        turnRightClip =
            try container.decodeIfPresent(String.self, forKey: .turnRightClip)
        turnLeftReversed =
            try container.decodeIfPresent(Bool.self, forKey: .turnLeftReversed) ?? false
        turnRightReversed =
            try container.decodeIfPresent(Bool.self, forKey: .turnRightReversed)
                ?? (turnClip != nil)
        mirrorPolicy =
            try container.decodeIfPresent(V4MirrorPolicy.self, forKey: .mirrorPolicy)
                ?? .automatic
        deformationZones =
            try container.decodeIfPresent(
                [V4DeformationZone].self,
                forKey: .deformationZones
            )
        rigidZones =
            try container.decodeIfPresent([V4RigidZone].self, forKey: .rigidZones)
    }
}

private struct V4EyeAnchor: Decodable {
    let x: CGFloat
    let y: CGFloat
    let radius: CGFloat
    let trackingID: String?
    let trackingGain: CGFloat?
    let verticalGain: CGFloat?
    let trackingStiffness: CGFloat?

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case radius
        case trackingID = "tracking_id"
        case trackingGain = "tracking_gain"
        case verticalGain = "vertical_gain"
        case trackingStiffness = "tracking_stiffness"
    }

    init(
        x: CGFloat,
        y: CGFloat,
        radius: CGFloat,
        trackingID: String? = nil,
        trackingGain: CGFloat? = nil,
        verticalGain: CGFloat? = nil,
        trackingStiffness: CGFloat? = nil
    ) {
        self.x = x
        self.y = y
        self.radius = radius
        self.trackingID = trackingID
        self.trackingGain = trackingGain
        self.verticalGain = verticalGain
        self.trackingStiffness = trackingStiffness
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(CGFloat.self, forKey: .x)
        y = try container.decode(CGFloat.self, forKey: .y)
        radius = try container.decode(CGFloat.self, forKey: .radius)
        trackingID =
            try container.decodeIfPresent(String.self, forKey: .trackingID)
        trackingGain =
            try container.decodeIfPresent(CGFloat.self, forKey: .trackingGain)
        verticalGain =
            try container.decodeIfPresent(CGFloat.self, forKey: .verticalGain)
        trackingStiffness =
            try container.decodeIfPresent(CGFloat.self, forKey: .trackingStiffness)
    }
}

private struct V4SpriteSelection {
    let clipName: String
    let transitionKey: String
    let row: Int
    let column: Int
    let mirrored: Bool
    let containsProp: Bool
    let pointerEyes: Bool
    let eyeAnchors: [V4EyeAnchor]
    let deformationProfile: V4DeformationProfile
}

private enum MigiQAAgentTransition: String {
    case join
    case handoff
    case leave
}

private enum V4TransitionRootAxis: Equatable {
    case bottom
    case left
}

private struct V4PresentationIdentity: Equatable {
    let key: String
    let mirrored: Bool
}

private struct V4EyeTrackingState {
    var value: SIMD2<Double>
    var velocity: SIMD2<Double>
}

private struct V4TurnPlayback {
    let baseClipName: String
    let clipName: String
    let startedAt: TimeInterval
    let targetMirrored: Bool
    let playbackRate: Double
    let reversed: Bool
}

private enum V4PlaybackMode: String, Decodable {
    case loop
    case once
    case pingPong = "ping-pong"
    case hold
    case enterHoldRetract = "enter-hold-retract"
}

private enum V4MirrorPolicy: String, Decodable {
    case automatic
    case never
    case always
}

private struct V4SpriteHandoff {
    let previous: V4SpriteSelection
    let startedAt: TimeInterval
    let duration: TimeInterval
    let kind: V4SpriteHandoffKind
}

private enum V4SpriteHandoffKind: Equatable {
    case authoredFrame
    case semantic
    case urgent
    case sleep
    case wake
}

private struct V4SpriteScene {
    let sprite: FullSpriteMesh
    let eyes: FullColorMesh
    let usesTransitionCompositing: Bool
}

private struct V4GPUScene {
    let sprite: V4GPUMesh
    let eyes: V4GPUMesh?
    let usesTransitionCompositing: Bool
}

private enum V4PipelineBlendMode {
    case sourceOver
    case additivePremultiplied
}

private struct V4GPUMesh {
    let buffer: MTLBuffer
    let vertexCount: Int
    var indexBuffer: MTLBuffer?
    var indexCount: Int

    init(
        buffer: MTLBuffer,
        vertexCount: Int,
        indexBuffer: MTLBuffer? = nil,
        indexCount: Int = 0
    ) {
        self.buffer = buffer
        self.vertexCount = vertexCount
        self.indexBuffer = indexBuffer
        self.indexCount = indexCount
    }
}

private struct QACaptureRequest {
    let destinationURL: URL
    let failedAttempts: Int
}

private enum QACaptureEncodingResult {
    case success(QACaptureSubmission)
    case failure(String)
}

private struct QACaptureSubmission {
    let request: QACaptureRequest
    let buffer: MTLBuffer
    let pixelWidth: Int
    let pixelHeight: Int
    let bytesPerRow: Int
    let byteCount: Int
}

private struct FullSpriteVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var alpha: Float
}

private struct V4DeformationZone: Decodable {
    let x: CGFloat
    let y: CGFloat
    let radiusX: CGFloat
    let radiusY: CGFloat
    let gain: CGFloat

    private enum CodingKeys: String, CodingKey {
        case x
        case y
        case radiusX = "radius_x"
        case radiusY = "radius_y"
        case gain
    }

    init(
        x: CGFloat,
        y: CGFloat,
        radiusX: CGFloat,
        radiusY: CGFloat,
        gain: CGFloat
    ) {
        self.x = x
        self.y = y
        self.radiusX = radiusX
        self.radiusY = radiusY
        self.gain = gain
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        x = try container.decode(CGFloat.self, forKey: .x)
        y = try container.decode(CGFloat.self, forKey: .y)
        radiusX = try container.decode(CGFloat.self, forKey: .radiusX)
        radiusY = try container.decode(CGFloat.self, forKey: .radiusY)
        gain = try container.decodeIfPresent(CGFloat.self, forKey: .gain) ?? 1
    }
}

private struct V4RigidZone: Decodable {
    let minX: CGFloat
    let minY: CGFloat
    let maxX: CGFloat
    let maxY: CGFloat
    let feather: CGFloat

    private enum CodingKeys: String, CodingKey {
        case minX = "min_x"
        case minY = "min_y"
        case maxX = "max_x"
        case maxY = "max_y"
        case feather
    }

    init(
        minX: CGFloat,
        minY: CGFloat,
        maxX: CGFloat,
        maxY: CGFloat,
        feather: CGFloat
    ) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
        self.feather = feather
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        minX = try container.decode(CGFloat.self, forKey: .minX)
        minY = try container.decode(CGFloat.self, forKey: .minY)
        maxX = try container.decode(CGFloat.self, forKey: .maxX)
        maxY = try container.decode(CGFloat.self, forKey: .maxY)
        feather =
            try container.decodeIfPresent(CGFloat.self, forKey: .feather) ?? 0.04
    }
}

private struct V4DeformationProfile {
    let tissueZones: [V4DeformationZone]
    let rigidZones: [V4RigidZone]

    func offset(
        sourceX: CGFloat,
        sourceY: CGFloat,
        displayX: CGFloat,
        mirrored: Bool,
        time: CGFloat,
        amplitude: CGFloat,
        tuning: MigiOrganicMotionTuning
    ) -> CGPoint {
        guard amplitude > 0, !tissueZones.isEmpty else { return .zero }
        let rigidity = rigidityWeight(sourceX: sourceX, sourceY: sourceY)
        guard rigidity < 0.999 else { return .zero }

        let rootDistance = MigiOrganicMath.clamp(1 - sourceY)
        let rootEnvelope = MigiOrganicMath.smoothstep(
            edge0: 0.025,
            edge1: max(tuning.rootAnchorLength, 0.08),
            value: rootDistance
        )
        let horizontalEnvelope = max(sin(displayX * .pi), 0)
        let topSafety =
            1 - 0.24 * MigiOrganicMath.smoothstep(
                edge0: 0.92,
                edge1: 1,
                value: rootDistance
            )
        let directionSign: CGFloat = mirrored ? -1 : 1
        let breathScale = min(max(amplitude / 0.005, 0.45), 1.35)

        var accumulated = CGPoint.zero
        var totalWeight: CGFloat = 0
        for (index, zone) in tissueZones.enumerated() {
            let weight = tissueWeight(
                for: zone,
                sourceX: sourceX,
                sourceY: sourceY
            )
            guard weight > 0.0001 else { continue }

            // Each authored tissue zone behaves as one appendage family. Its
            // phase is independent, while the wave within that zone travels
            // continuously from its lower/root edge toward its upper/tip edge.
            let localRootDistance = MigiOrganicMath.clamp(
                (zone.y + zone.radiusY - sourceY)
                    / max(zone.radiusY * 2, 0.002)
            )
            let appendagePhase = MigiOrganicMath.appendagePhase(
                index: index,
                sourceX: zone.x,
                stride: tuning.appendagePhaseStride
            )
            let travelling = sin(
                time * tuning.waveSpeed
                    - localRootDistance * tuning.rootToTipPhaseLag
                    + appendagePhase
            )
            let counterWave = sin(
                time * tuning.counterWaveSpeed
                    - localRootDistance * tuning.rootToTipPhaseLag * 0.43
                    - appendagePhase * 0.61
                    + displayX * 2.4
            )

            let localDisplayX = (sourceX - zone.x) * directionSign
            let localDisplayY = zone.y - sourceY
            let localBreath = sin(
                time * tuning.localBreathSpeed
                    - localRootDistance * 0.82
                    + appendagePhase * 0.73
            ) * tuning.localBreathAmount * breathScale

            let lateralWave =
                amplitude * tuning.lateralGain * travelling
            let axialWave =
                amplitude * tuning.axialGain * counterWave
            // When a region lengthens, its width contracts by a matching small
            // amount. This keeps eye stalks and tendrils fleshy rather than
            // ballooning as a synchronized rubber sheet.
            let volumeX =
                -localDisplayX * localBreath * tuning.volumeConservation
            let volumeY = localDisplayY * localBreath
            accumulated.x += (lateralWave + volumeX) * weight
            accumulated.y += (axialWave + volumeY) * weight
            totalWeight += weight
        }

        guard totalWeight > 0.0001 else { return .zero }
        let overlapNormalization = max(totalWeight, 1)
        let envelope =
            (1 - rigidity) * rootEnvelope * topSafety
        return CGPoint(
            x: accumulated.x / overlapNormalization
                * envelope * horizontalEnvelope,
            y: accumulated.y / overlapNormalization
                * envelope * (0.46 + 0.54 * horizontalEnvelope)
        )
    }

    func rigidityWeight(
        sourceX: CGFloat,
        sourceY: CGFloat
    ) -> CGFloat {
        var rigidWeight: CGFloat = 0
        for zone in rigidZones {
            let dx = max(max(zone.minX - sourceX, 0), sourceX - zone.maxX)
            let dy = max(max(zone.minY - sourceY, 0), sourceY - zone.maxY)
            let distance = sqrt(dx * dx + dy * dy)
            let feather = max(zone.feather, 0.001)
            let normalized = min(max(1 - distance / feather, 0), 1)
            let smooth = normalized * normalized * (3 - 2 * normalized)
            rigidWeight = max(rigidWeight, smooth)
        }
        return MigiOrganicMath.clamp(rigidWeight)
    }

    private func tissueWeight(
        for zone: V4DeformationZone,
        sourceX: CGFloat,
        sourceY: CGFloat
    ) -> CGFloat {
        let dx = (sourceX - zone.x) / max(zone.radiusX, 0.001)
        let dy = (sourceY - zone.y) / max(zone.radiusY, 0.001)
        let distance = sqrt(dx * dx + dy * dy)
        let normalized = MigiOrganicMath.clamp((1 - distance) / 0.36)
        let smooth = normalized * normalized * (3 - 2 * normalized)
        return smooth * max(zone.gain, 0)
    }
}

private struct FullSpriteMesh {
    var vertices: [FullSpriteVertex] = []
    var indices: [UInt16] = []

    mutating func addCell(
        row: Int,
        column: Int,
        columns: Int,
        rows: Int,
        mirrored: Bool,
        center: CGPoint,
        size: CGSize,
        time: CGFloat,
        deformation: CGFloat,
        deformationProfile: V4DeformationProfile,
        motionTuning: MigiOrganicMotionTuning,
        transition: MigiTissueTransition?,
        transitionRootAxis: V4TransitionRootAxis,
        alpha: CGFloat = 1
    ) {
        let horizontalSegments = 14
        let verticalSegments = 16
        let atlasColumns = CGFloat(max(columns, 1))
        let atlasRows = CGFloat(max(rows, 1))

        func vertex(x: Int, y: Int) -> FullSpriteVertex {
            let s = CGFloat(x) / CGFloat(horizontalSegments)
            let t = CGFloat(y) / CGFloat(verticalSegments)
            let displayX = s - 0.5
            let displayY = t - 0.5
            let sourceS = mirrored ? 1 - s : s
            let sourceY = 1 - t
            let tissueOffset = deformationProfile.offset(
                sourceX: sourceS,
                sourceY: sourceY,
                displayX: s,
                mirrored: mirrored,
                time: time,
                amplitude: deformation,
                tuning: motionTuning
            )
            let rigidity = deformationProfile.rigidityWeight(
                sourceX: sourceS,
                sourceY: sourceY
            )
            let transitionVisibility =
                transition?.visibility(
                    rootDistance:
                        transitionRootAxis == .left ? sourceS : t,
                    displayX: s,
                    rigidity: rigidity
                ) ?? 1
            let transitionOffset =
                transition?.flowOffset(
                    rootDistance:
                        transitionRootAxis == .left ? sourceS : t,
                    displayX: s,
                    rigidity: rigidity
                ) ?? .zero
            let point = CGPoint(
                x: center.x + displayX * size.width
                    + tissueOffset.x + transitionOffset.x,
                y: center.y + displayY * size.height
                    + tissueOffset.y + transitionOffset.y
            )
            let u = (CGFloat(column) + sourceS) / atlasColumns
            let v = (CGFloat(row + 1) - t) / atlasRows
            return FullSpriteVertex(
                position: fullMetalPoint(point),
                uv: SIMD2<Float>(Float(u), Float(v)),
                alpha: Float(
                    min(max(alpha * transitionVisibility, 0), 1)
                )
            )
        }

        // Shared grid points are deformed exactly once. Neighbouring cells
        // reuse them through indices, so a cell mesh costs one 15 × 17 vertex
        // grid instead of four overlapping evaluations per quad.
        let gridWidth = horizontalSegments + 1
        let gridHeight = verticalSegments + 1
        var grid = [FullSpriteVertex]()
        grid.reserveCapacity(gridWidth * gridHeight)
        for y in 0..<gridHeight {
            for x in 0..<gridWidth {
                grid.append(vertex(x: x, y: y))
            }
        }

        let baseIndex = UInt16(vertices.count)
        vertices.append(contentsOf: grid)
        indices.reserveCapacity(
            indices.count + horizontalSegments * verticalSegments * 6
        )
        for y in 0..<verticalSegments {
            for x in 0..<horizontalSegments {
                let bottomLeft = baseIndex + UInt16(y * gridWidth + x)
                let bottomRight = bottomLeft + 1
                let topLeft = bottomLeft + UInt16(gridWidth)
                let topRight = topLeft + 1
                indices.append(contentsOf: [
                    bottomLeft, bottomRight, topRight,
                    bottomLeft, topRight, topLeft,
                ])
            }
        }
    }
}

private struct FullColorVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct FullColorMesh {
    var vertices: [FullColorVertex] = []

    mutating func addEllipticalCap(
        center: CGPoint, rx: CGFloat, ry: CGFloat,
        cut: CGFloat, upper: Bool, color: FullRGBA
    ) {
        let boundary = min(max(cut, -1), 1)
        let angle = asin(boundary)
        let start = upper ? angle : .pi - angle
        let end = upper ? .pi - angle : 2 * .pi + angle
        guard end - start > 0.0001 else { return }
        let segments = 24
        let base = FullColorVertex(
            position: fullMetalPoint(CGPoint(x: center.x, y: center.y + boundary * ry)),
            color: color.vector
        )
        for index in 0..<segments {
            let first = start + (end - start) * CGFloat(index) / CGFloat(segments)
            let second = start + (end - start) * CGFloat(index + 1) / CGFloat(segments)
            vertices.append(contentsOf: [
                base,
                FullColorVertex(
                    position: fullMetalPoint(CGPoint(x: center.x + cos(first) * rx, y: center.y + sin(first) * ry)),
                    color: color.vector
                ),
                FullColorVertex(
                    position: fullMetalPoint(CGPoint(x: center.x + cos(second) * rx, y: center.y + sin(second) * ry)),
                    color: color.vector
                )
            ])
        }
    }

    mutating func addEllipse(
        center: CGPoint,
        rx: CGFloat,
        ry: CGFloat,
        color: FullRGBA,
        segments: Int
    ) {
        guard rx > 0, ry > 0, segments >= 3 else { return }
        for index in 0..<segments {
            let firstAngle = CGFloat(index) / CGFloat(segments) * .pi * 2
            let secondAngle = CGFloat(index + 1) / CGFloat(segments) * .pi * 2
            let first = CGPoint(
                x: center.x + cos(firstAngle) * rx,
                y: center.y + sin(firstAngle) * ry
            )
            let second = CGPoint(
                x: center.x + cos(secondAngle) * rx,
                y: center.y + sin(secondAngle) * ry
            )
            vertices.append(FullColorVertex(position: fullMetalPoint(center), color: color.vector))
            vertices.append(FullColorVertex(position: fullMetalPoint(first), color: color.vector))
            vertices.append(FullColorVertex(position: fullMetalPoint(second), color: color.vector))
        }
    }
}

private struct FullRGBA {
    let r: Float
    let g: Float
    let b: Float
    let a: Float

    var vector: SIMD4<Float> { SIMD4<Float>(r, g, b, a) }

    func withAlphaMultiplier(_ multiplier: CGFloat) -> FullRGBA {
        FullRGBA(
            r: r,
            g: g,
            b: b,
            a: a * Float(min(max(multiplier, 0), 1))
        )
    }

    static let eyeWhite = FullRGBA(r: 0.98, g: 0.97, b: 0.91, a: 1)
    static let pupil = FullRGBA(r: 0.025, g: 0.022, b: 0.016, a: 1)
    static let highlight = FullRGBA(r: 1, g: 1, b: 1, a: 1)
    static let eyelidFlesh = FullRGBA(r: 0.91, g: 0.74, b: 0.50, a: 1)
    static let eyelidCrease = FullRGBA(r: 0.24, g: 0.15, b: 0.11, a: 0.92)
}

private func fullMetalPoint(_ point: CGPoint) -> SIMD2<Float> {
    SIMD2<Float>(
        Float(point.x * 2 - 1),
        Float(point.y * 2 - 1)
    )
}
