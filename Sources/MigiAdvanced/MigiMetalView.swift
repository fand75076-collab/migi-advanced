import AppKit
import MetalKit
import simd

final class MigiMetalView: MTKView, MTKViewDelegate {
    var onBehaviorFrame: ((MigiBehaviorFrame) -> Void)?
    var onManualWindowMove: ((CGPoint, Bool) -> Void)?

    private let commandQueue: MTLCommandQueue
    private let colorPipeline: MTLRenderPipelineState
    private let texturePipeline: MTLRenderPipelineState
    private let partsTexture: MTLTexture?
    private let behavior = MigiBehaviorController(
        seed: 0x4D49_4749,
        initialFacing: -1
    )

    private var lastDrawTime = ProcessInfo.processInfo.systemUptime
    private var gaze = SIMD2<Double>(0, 0)
    private var gazeVelocity = SIMD2<Double>(0, 0)
    private var stalkGaze = SIMD2<Double>(0, 0)
    private var stalkGazeVelocity = SIMD2<Double>(0, 0)
    private var demoMode = false
    private var fixedDemoActivity: CodexActivity?
    private var demoStartTime: TimeInterval?
    private var lastDemoIndex = -1
    private var latestLiveSnapshot = CodexActivitySnapshot(
        activity: .idle,
        detail: "Idle",
        observedAt: Date(),
        sourcePath: nil
    )
    private var pendingQACaptureURL: URL?
    private var dragStartMouse: CGPoint?
    private var dragStartWindowOrigin: CGPoint?

    var isDemoModeEnabled: Bool { demoMode }
    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect, device: MTLDevice?) {
        guard
            let device,
            let queue = device.makeCommandQueue()
        else {
            fatalError("Unable to initialize Metal.")
        }

        let shaderSource = Self.shaderSource
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: shaderSource, options: nil)
        } catch {
            fatalError("Unable to compile Migi Metal shaders: \(error)")
        }

        let sampleCount = device.supportsTextureSampleCount(4) ? 4 : 1
        colorPipeline = Self.makePipeline(
            device: device,
            library: library,
            vertex: "colorVertex",
            fragment: "colorFragment",
            sampleCount: sampleCount
        )
        texturePipeline = Self.makePipeline(
            device: device,
            library: library,
            vertex: "textureVertex",
            fragment: "textureFragment",
            sampleCount: sampleCount
        )
        commandQueue = queue
        partsTexture = Self.loadPartsTexture(device: device)

        super.init(frame: frameRect, device: device)

        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        framebufferOnly = true
        layer?.isOpaque = false
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = false
        isPaused = false
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

    func setDemoMode(_ enabled: Bool, fixedActivity: CodexActivity? = nil) {
        demoMode = enabled
        fixedDemoActivity = enabled ? fixedActivity : nil
        demoStartTime = nil
        lastDemoIndex = -1
        if enabled, let fixedActivity {
            behavior.force(demoSnapshot(for: fixedActivity))
        } else if !enabled {
            behavior.force(latestLiveSnapshot)
        }
    }

    func requestQACapture(to url: URL) {
        guard url.isFileURL else { return }
        pendingQACaptureURL = url
        // A sleeping display can pause MTKView's display link. Explicitly request
        // one frame so the QA route remains deterministic in background launches.
        DispatchQueue.main.async { [weak self] in
            self?.draw()
        }
    }

    func draw(in view: MTKView) {
        autoreleasepool {
            let now = ProcessInfo.processInfo.systemUptime
            let dt = min(max(now - lastDrawTime, 1.0 / 240.0), 1.0 / 20.0)
            lastDrawTime = now

            updateDemoIfNeeded(time: now)
            updateGaze(deltaTime: dt)

            let behaviorFrame = behavior.update(
                time: now,
                deltaTime: dt,
                availableWidth: availableRoamWidth
            )
            onBehaviorFrame?(behaviorFrame)

            guard
                let descriptor = currentRenderPassDescriptor,
                let drawable = currentDrawable,
                let commandBuffer = commandQueue.makeCommandBuffer(),
                let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
            else {
                return
            }

            var backgroundMesh = ColorMesh()
            var foregroundMesh = ColorMesh()
            var textureMesh = TextureMesh()
            buildScene(
                time: now,
                behavior: behaviorFrame,
                gaze: gaze,
                stalkGaze: stalkGaze,
                background: &backgroundMesh,
                foreground: &foregroundMesh,
                textures: &textureMesh
            )

            encode(backgroundMesh, with: encoder)
            encode(textureMesh, with: encoder)
            encode(foregroundMesh, with: encoder)

            encoder.endEncoding()

            if let captureURL = pendingQACaptureURL {
                encodeQACapture(
                    background: backgroundMesh,
                    textures: textureMesh,
                    foreground: foregroundMesh,
                    pixelWidth: drawable.texture.width,
                    pixelHeight: drawable.texture.height,
                    commandBuffer: commandBuffer,
                    destinationURL: captureURL
                )
                pendingQACaptureURL = nil
            }

            commandBuffer.present(drawable)
            commandBuffer.commit()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    override func mouseDown(with event: NSEvent) {
        guard let window else { return }
        dragStartMouse = NSEvent.mouseLocation
        dragStartWindowOrigin = window.frame.origin
        onManualWindowMove?(window.frame.origin, true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let window,
            let startMouse = dragStartMouse,
            let startOrigin = dragStartWindowOrigin
        else {
            return
        }
        let current = NSEvent.mouseLocation
        let origin = CGPoint(
            x: startOrigin.x + current.x - startMouse.x,
            y: startOrigin.y + current.y - startMouse.y
        )
        window.setFrameOrigin(origin)
        onManualWindowMove?(origin, true)
    }

    override func mouseUp(with event: NSEvent) {
        if let origin = window?.frame.origin {
            onManualWindowMove?(origin, false)
        }
        dragStartMouse = nil
        dragStartWindowOrigin = nil
    }

    private var availableRoamWidth: CGFloat {
        guard let window, let screen = window.screen ?? NSScreen.main else { return 240 }
        return max(80, min(520, screen.visibleFrame.width - window.frame.width - 72))
    }

    private func updateDemoIfNeeded(time: TimeInterval) {
        guard demoMode else { return }
        let activities: [CodexActivity] = [.idle, .thinking, .tool, .waiting, .review, .failed]
        if demoStartTime == nil {
            demoStartTime = time
        }
        if let fixedDemoActivity {
            let index = activities.firstIndex(of: fixedDemoActivity) ?? 0
            guard index != lastDemoIndex else { return }
            lastDemoIndex = index
            behavior.force(demoSnapshot(for: fixedDemoActivity))
            return
        }

        let elapsed = max(0, time - (demoStartTime ?? time))
        let index = Int(elapsed / 8.0) % activities.count
        guard index != lastDemoIndex else { return }
        lastDemoIndex = index
        behavior.force(demoSnapshot(for: activities[index]))
    }

    private func demoSnapshot(for activity: CodexActivity) -> CodexActivitySnapshot {
        CodexActivitySnapshot(
            activity: activity,
            detail: "状态演示",
            observedAt: Date(),
            sourcePath: nil
        )
    }

    private func updateGaze(deltaTime: TimeInterval) {
        guard let window else { return }
        let screenPoint = NSEvent.mouseLocation
        let windowPoint = window.convertPoint(fromScreen: screenPoint)
        let localPoint = convert(windowPoint, from: nil)
        let halfWidth = max(bounds.width * 0.5, 1)
        let halfHeight = max(bounds.height * 0.5, 1)
        var target = SIMD2<Double>(
            Double((localPoint.x - bounds.midX) / halfWidth),
            Double((localPoint.y - bounds.midY) / halfHeight)
        )
        let length = simd_length(target)
        if length > 1 {
            target /= length
        }

        // Two critically damped springs create the characteristic sequence:
        // the pupils notice first, then the soft eye stalks follow a moment later.
        integrateSpring(
            value: &gaze,
            velocity: &gazeVelocity,
            target: target,
            stiffness: 18,
            deltaTime: deltaTime
        )
        integrateSpring(
            value: &stalkGaze,
            velocity: &stalkGazeVelocity,
            target: target,
            stiffness: 5.5,
            deltaTime: deltaTime
        )
    }

    private func integrateSpring(
        value: inout SIMD2<Double>,
        velocity: inout SIMD2<Double>,
        target: SIMD2<Double>,
        stiffness: Double,
        deltaTime: TimeInterval
    ) {
        let damping = 2.0 * sqrt(stiffness)
        let acceleration = (target - value) * stiffness - velocity * damping
        velocity += acceleration * deltaTime
        value += velocity * deltaTime
    }

    private func buildScene(
        time: TimeInterval,
        behavior: MigiBehaviorFrame,
        gaze: SIMD2<Double>,
        stalkGaze: SIMD2<Double>,
        background: inout ColorMesh,
        foreground: inout ColorMesh,
        textures: inout TextureMesh
    ) {
        let phase = CGFloat(time)
        let facing = behavior.facing >= 0 ? CGFloat(1) : CGFloat(-1)
        let breath = sin(phase * (0.92 + behavior.bodyEnergy * 0.12))
        let bounce = 0.004 * breath + 0.0035 * behavior.bodyEnergy * sin(phase * 2.1)
        let squash = 1.0 + 0.010 * breath
        let transform = PoseTransform(
            facing: facing,
            yOffset: bounce,
            yScale: squash,
            aspect: bounds.height / max(bounds.width, 1)
        )

        addBackTendrils(
            time: phase,
            behavior: behavior,
            transform: transform,
            mesh: &background
        )

        if partsTexture != nil {
            textures.addSprite(
                slot: 0,
                center: transform.apply(CGPoint(x: 0.50, y: 0.25)),
                size: CGSize(width: 0.55 * transform.aspect, height: 0.40 * squash),
                rotation: 0,
                mirrored: false,
                alpha: 1
            )
        } else {
            addProceduralBody(transform: transform, mesh: &foreground)
        }

        let focus = min(max(behavior.focus, 0), 1)
        // X is authored in character-local coordinates and therefore compensates
        // for the later facing transform. This keeps stalk and pupil travel aligned.
        let attentionX = CGFloat(stalkGaze.x) * facing * (0.027 + 0.010 * focus)
        let attentionY = CGFloat(stalkGaze.y) * (0.014 + 0.007 * focus)
        let activityLean: CGFloat = behavior.activity == .review ? -0.025 :
            (behavior.activity == .tool ? 0.015 : 0)

        let tallRoot = transform.apply(CGPoint(x: 0.482, y: 0.425))
        let tallTipRaw = CGPoint(
            x: 0.525 + activityLean + attentionX + 0.008 * sin(phase * 0.73),
            y: 0.755 + attentionY + 0.008 * sin(phase * 0.91)
        )
        let tallControl1 = CGPoint(
            x: 0.455 + activityLean * 0.4 + attentionX * 0.15,
            y: 0.555 + 0.012 * sin(phase * 0.82)
        )
        let tallControl2 = CGPoint(
            x: 0.485 + activityLean * 0.8 + attentionX * 0.58,
            y: 0.675 + attentionY * 0.45
        )
        let tallBasePoints = cubic(
            tallRoot,
            transform.apply(tallControl1),
            transform.apply(tallControl2),
            transform.apply(tallTipRaw),
            count: 30
        )
        let tallPoints = organicCurve(
            tallBasePoints,
            time: phase,
            phase: 0.4,
            amplitude: 0.0035 + behavior.bodyEnergy * 0.0025,
            waveCount: 1.35
        )
        addFleshRibbon(
            points: tallPoints,
            widths: livingWidths(
                count: tallPoints.count,
                start: 0.098,
                end: 0.056,
                time: phase,
                phase: 0.2,
                energy: behavior.bodyEnergy
            ),
            mesh: &background
        )
        addTendrilHighlight(points: tallPoints, baseWidth: 0.013, mesh: &background)

        let smallRoot = transform.apply(CGPoint(x: 0.405, y: 0.37))
        let smallLag = 0.68
        let smallTipRaw = CGPoint(
            x: 0.305 + attentionX * smallLag + 0.008 * sin(phase * 0.63 + 1.7),
            y: 0.575 + attentionY * smallLag + 0.006 * sin(phase * 0.77 + 1.3)
        )
        let smallBasePoints = cubic(
            smallRoot,
            transform.apply(CGPoint(x: 0.335, y: 0.43)),
            transform.apply(CGPoint(x: 0.285 + attentionX * 0.3, y: 0.51)),
            transform.apply(smallTipRaw),
            count: 24
        )
        let smallPoints = organicCurve(
            smallBasePoints,
            time: phase,
            phase: 2.1,
            amplitude: 0.0045 + behavior.bodyEnergy * 0.0025,
            waveCount: 1.65
        )
        addFleshRibbon(
            points: smallPoints,
            widths: livingWidths(
                count: smallPoints.count,
                start: 0.074,
                end: 0.044,
                time: phase,
                phase: 2.4,
                energy: behavior.bodyEnergy
            ),
            mesh: &background
        )
        addTendrilHighlight(points: smallPoints, baseWidth: 0.009, mesh: &background)

        addShoulderBlend(
            time: phase,
            transform: transform,
            mesh: &foreground
        )
        addRootFolds(at: tallRoot, scale: 1.0, transform: transform, mesh: &foreground)
        addRootFolds(at: smallRoot, scale: 0.72, transform: transform, mesh: &foreground)

        addArmAndHand(
            time: phase,
            behavior: behavior,
            transform: transform,
            armMesh: &background,
            fingerMesh: &foreground
        )

        let blinkAmount = blinkValue(time: phase, microAction: behavior.microAction)
        addEye(
            center: tallPoints.last ?? transform.apply(tallTipRaw),
            radius: 0.050,
            gaze: gaze,
            blink: blinkAmount,
            focus: focus,
            transform: transform,
            mesh: &foreground
        )
        addEye(
            center: smallPoints.last ?? transform.apply(smallTipRaw),
            radius: 0.038,
            gaze: gaze * 0.82,
            blink: min(1, blinkAmount * 1.05),
            focus: focus * 0.8,
            transform: transform,
            mesh: &foreground
        )

        if partsTexture == nil {
            addMouth(time: phase, behavior: behavior, transform: transform, mesh: &foreground)
        }

        addProp(
            time: phase,
            behavior: behavior,
            transform: transform,
            textures: &textures,
            colors: &foreground
        )
    }

    private func encode(_ mesh: ColorMesh, with encoder: MTLRenderCommandEncoder) {
        guard !mesh.vertices.isEmpty else { return }
        encoder.setRenderPipelineState(colorPipeline)
        if let buffer = device?.makeBuffer(
            bytes: mesh.vertices,
            length: mesh.vertices.count * MemoryLayout<ColorVertex>.stride,
            options: .storageModeShared
        ) {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertices.count)
        }
    }

    private func encode(_ mesh: TextureMesh, with encoder: MTLRenderCommandEncoder) {
        guard !mesh.vertices.isEmpty, let texture = partsTexture else { return }
        encoder.setRenderPipelineState(texturePipeline)
        encoder.setFragmentTexture(texture, index: 0)
        if let buffer = device?.makeBuffer(
            bytes: mesh.vertices,
            length: mesh.vertices.count * MemoryLayout<TextureVertex>.stride,
            options: .storageModeShared
        ) {
            encoder.setVertexBuffer(buffer, offset: 0, index: 0)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: mesh.vertices.count)
        }
    }

    private func encodeQACapture(
        background: ColorMesh,
        textures: TextureMesh,
        foreground: ColorMesh,
        pixelWidth: Int,
        pixelHeight: Int,
        commandBuffer: MTLCommandBuffer,
        destinationURL: URL
    ) {
        guard let device,
              pixelWidth > 0,
              pixelHeight > 0
        else {
            return
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
            return
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
                return
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

        guard let qaEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            return
        }
        encode(background, with: qaEncoder)
        encode(textures, with: qaEncoder)
        encode(foreground, with: qaEncoder)
        qaEncoder.endEncoding()

        let bytesPerPixel = 4
        let bytesPerRow = pixelWidth * bytesPerPixel
        let byteCount = bytesPerRow * pixelHeight
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else {
            return
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

        commandBuffer.addCompletedHandler { _ in
            let data = Data(bytes: buffer.contents(), count: byteCount)
            guard let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bitsPerPixel: 32,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: [
                        CGBitmapInfo.byteOrder32Little,
                        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    ],
                    provider: provider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  ),
                  let png = NSBitmapImageRep(cgImage: image)
                    .representation(using: .png, properties: [:])
            else {
                return
            }
            try? png.write(to: destinationURL, options: .atomic)
        }
    }

    private func addBackTendrils(
        time: CGFloat,
        behavior: MigiBehaviorFrame,
        transform: PoseTransform,
        mesh: inout ColorMesh
    ) {
        let energy = behavior.bodyEnergy
        let isExpanded = behavior.activity != .idle
            || behavior.microAction == .stretch
            || behavior.microAction == .inspectHand
        let actionBoost: CGFloat = behavior.microAction == .stretch ? 0.055 : 0
        var configs: [(CGPoint, CGFloat, CGFloat, CGFloat)] = [
            (CGPoint(x: 0.38, y: 0.20), -1, 0.3, 0.00)
        ]
        if isExpanded {
            configs.append((CGPoint(x: 0.62, y: 0.20), 1, 2.2, 0.01))
            configs.append((
                CGPoint(x: 0.51, y: 0.19),
                behavior.facing < 0 ? -1 : 1,
                4.0,
                -0.02
            ))
        }

        for (index, config) in configs.enumerated() {
            let (root, direction, phase, verticalBias) = config
            let sway = sin(time * (0.72 + CGFloat(index) * 0.11) + phase)
            let baseLength: CGFloat = isExpanded ? 0.155 : 0.105
            let length = baseLength + 0.032 * energy + actionBoost * (index == 1 ? 1 : 0.45)
            let tip = CGPoint(
                x: root.x + direction * length + 0.025 * sway,
                y: 0.285 + verticalBias + 0.035 * cos(time * 0.61 + phase)
            )
            let basePoints = cubic(
                transform.apply(root),
                transform.apply(CGPoint(
                    x: root.x + direction * length * 0.28,
                    y: root.y + 0.04
                )),
                transform.apply(CGPoint(
                    x: root.x + direction * length * 0.72 - 0.03 * sway,
                    y: tip.y + 0.045
                )),
                transform.apply(tip),
                count: 22
            )
            let points = organicCurve(
                basePoints,
                time: time,
                phase: phase,
                amplitude: 0.005 + 0.006 * energy,
                waveCount: 1.85 + CGFloat(index) * 0.22
            )
            addFleshRibbon(
                points: points,
                widths: livingWidths(
                    count: points.count,
                    start: isExpanded ? 0.046 : 0.040,
                    end: 0.014,
                    time: time,
                    phase: phase,
                    energy: energy
                ),
                mesh: &mesh
            )
            addTendrilHighlight(points: points, baseWidth: 0.006, mesh: &mesh)
        }
    }

    private func addProceduralBody(transform: PoseTransform, mesh: inout ColorMesh) {
        let controls = [
            CGPoint(x: 0.48, y: 0.43),
            CGPoint(x: 0.36, y: 0.39),
            CGPoint(x: 0.29, y: 0.28),
            CGPoint(x: 0.20, y: 0.19),
            CGPoint(x: 0.18, y: 0.12),
            CGPoint(x: 0.25, y: 0.09),
            CGPoint(x: 0.36, y: 0.11),
            CGPoint(x: 0.43, y: 0.07),
            CGPoint(x: 0.52, y: 0.075),
            CGPoint(x: 0.59, y: 0.11),
            CGPoint(x: 0.72, y: 0.09),
            CGPoint(x: 0.80, y: 0.13),
            CGPoint(x: 0.76, y: 0.21),
            CGPoint(x: 0.66, y: 0.28),
            CGPoint(x: 0.61, y: 0.39)
        ].map(transform.apply)
        let contour = closedCatmullRom(controls, samplesPerSegment: 7)
        mesh.addPolygon(contour, color: Palette.flesh)
        mesh.addRibbon(
            points: contour + [contour[0]],
            widths: Array(repeating: 0.014, count: contour.count + 1),
            leftColor: Palette.outline,
            rightColor: Palette.outline
        )
        let highlight = [
            transform.apply(CGPoint(x: 0.37, y: 0.34)),
            transform.apply(CGPoint(x: 0.34, y: 0.27)),
            transform.apply(CGPoint(x: 0.33, y: 0.20))
        ]
        mesh.addRibbon(
            points: highlight,
            widths: [0.014, 0.010, 0.006],
            leftColor: Palette.highlight,
            rightColor: Palette.highlight.withAlpha(0.25)
        )
    }

    /// Covers the deliberately open top edge of the generated torso with a soft,
    /// deforming shoulder mantle. Eye stalks remain behind it, so their attachment
    /// reads as one continuous organism instead of separate pieces.
    private func addShoulderBlend(
        time: CGFloat,
        transform: PoseTransform,
        mesh: inout ColorMesh
    ) {
        let ripple = 0.004 * sin(time * 1.05)
        let controls = [
            CGPoint(x: 0.35, y: 0.385),
            CGPoint(x: 0.37, y: 0.425 + ripple),
            CGPoint(x: 0.405, y: 0.463 - ripple * 0.3),
            CGPoint(x: 0.45, y: 0.442 + ripple * 0.2),
            CGPoint(x: 0.482, y: 0.472 + ripple * 0.4),
            CGPoint(x: 0.525, y: 0.447 - ripple * 0.15),
            CGPoint(x: 0.57, y: 0.465 + ripple * 0.25),
            CGPoint(x: 0.615, y: 0.425 - ripple * 0.2),
            CGPoint(x: 0.64, y: 0.385),
            CGPoint(x: 0.61, y: 0.335),
            CGPoint(x: 0.54, y: 0.315),
            CGPoint(x: 0.46, y: 0.315),
            CGPoint(x: 0.39, y: 0.335)
        ].map(transform.apply)
        let contour = closedCatmullRom(controls, samplesPerSegment: 7)
        let fadeStart = transform.apply(CGPoint(x: 0.50, y: 0.315)).y
        let fadeEnd = transform.apply(CGPoint(x: 0.50, y: 0.445)).y
        let edgeColors = contour.map { point -> RGBA in
            let raw = (point.y - fadeStart) / max(fadeEnd - fadeStart, 0.0001)
            let t = min(max(raw, 0), 1)
            let smooth = t * t * (3 - 2 * t)
            return Palette.bridgeFlesh.withAlpha(Float(smooth * 0.92))
        }
        mesh.addGradientPolygon(
            contour,
            edgeColors: edgeColors,
            centerColor: Palette.bridgeFlesh.withAlpha(0.62)
        )

        let highlight = quadratic(
            transform.apply(CGPoint(x: 0.397, y: 0.407)),
            transform.apply(CGPoint(x: 0.435, y: 0.447 + ripple)),
            transform.apply(CGPoint(x: 0.465, y: 0.438)),
            count: 14
        )
        mesh.addRibbon(
            points: highlight,
            widths: taperedWidths(count: highlight.count, start: 0.0045, end: 0.0015),
            leftColor: Palette.bridgeLight.withAlpha(0.38),
            rightColor: Palette.bridgeLight.withAlpha(0.08)
        )
    }

    private func addArmAndHand(
        time: CGFloat,
        behavior: MigiBehaviorFrame,
        transform: PoseTransform,
        armMesh: inout ColorMesh,
        fingerMesh: inout ColorMesh
    ) {
        let typing = behavior.prop == .laptop
        let reading = behavior.prop == .book
        let phone = behavior.prop == .phone
        let inspect = behavior.microAction == .inspectHand
        let wave = behavior.microAction == .lookAround
        let yTarget: CGFloat = typing ? 0.225 : (reading ? 0.31 : (phone ? 0.425 : 0.505))
        let xTarget: CGFloat = phone ? 0.65 : (typing ? 0.60 : (reading ? 0.625 : 0.705))
        let curl = 0.018 * sin(time * (typing ? 5.2 : 1.4))
        let inspectLift: CGFloat = inspect ? 0.06 : 0
        let waveLift: CGFloat = wave ? 0.025 * sin(time * 2.4) : 0

        let armBasePoints = cubic(
            transform.apply(CGPoint(x: 0.60, y: 0.355)),
            transform.apply(CGPoint(x: 0.665, y: 0.405)),
            transform.apply(CGPoint(x: 0.695 + curl, y: yTarget + 0.055 + inspectLift)),
            transform.apply(CGPoint(x: xTarget, y: yTarget + inspectLift + waveLift)),
            count: 24
        )
        let armPoints = organicCurve(
            armBasePoints,
            time: time,
            phase: 3.1,
            amplitude: 0.006 + 0.007 * behavior.bodyEnergy,
            waveCount: typing ? 2.1 : 1.55
        )
        addFleshRibbon(
            points: armPoints,
            widths: livingWidths(
                count: armPoints.count,
                start: 0.062,
                end: 0.037,
                time: time,
                phase: 3.1,
                energy: behavior.bodyEnergy
            ),
            mesh: &armMesh
        )
        addTendrilHighlight(points: armPoints, baseWidth: 0.008, mesh: &armMesh)

        let palm = armPoints.last ?? transform.apply(CGPoint(x: xTarget, y: yTarget))
        let fingerCount = typing ? 3 : 5
        let fingerLengths: [CGFloat] = typing
            ? [0.040, 0.050, 0.043]
            : [0.038, 0.047, 0.053, 0.047, 0.038]
        for finger in 0..<fingerCount {
            let t = CGFloat(finger) / CGFloat(max(fingerCount - 1, 1))
            let spread = (t - 0.5) * (typing ? 0.070 : 0.10)
            let tap = typing ? max(0, sin(time * 7.0 + CGFloat(finger) * 1.7)) * 0.024 : 0
            let fingerWave = sin(time * (1.15 + CGFloat(finger) * 0.07) + CGFloat(finger) * 1.4) * 0.006
            let end = CGPoint(
                x: palm.x + transform.facing * fingerLengths[finger] * transform.aspect,
                y: palm.y - 0.034 + spread * 0.32 - tap + fingerWave
            )
            let control = CGPoint(
                x: (palm.x + end.x) * 0.5 + transform.facing * 0.015,
                y: palm.y + spread
            )
            let points = quadratic(palm, control, end, count: 10)
            addFleshRibbon(
                points: points,
                widths: taperedWidths(count: points.count, start: 0.020, end: 0.010),
                mesh: &fingerMesh
            )
        }
    }

    private func addEye(
        center: CGPoint,
        radius: CGFloat,
        gaze: SIMD2<Double>,
        blink: CGFloat,
        focus: CGFloat,
        transform: PoseTransform,
        mesh: inout ColorMesh
    ) {
        let rx = radius * transform.aspect
        let ry = max(radius * (1 - blink * 0.88), radius * 0.10)
        mesh.addEllipse(center: center, rx: rx * 1.30, ry: ry * 1.28, color: Palette.outline, segments: 42)
        mesh.addEllipse(center: center, rx: rx * 1.22, ry: ry * 1.20, color: Palette.fleshShadow, segments: 42)
        mesh.addEllipse(
            center: CGPoint(x: center.x - rx * 0.025, y: center.y + ry * 0.035),
            rx: rx * 1.16,
            ry: ry * 1.13,
            color: Palette.fleshLight,
            segments: 42
        )
        mesh.addEllipse(center: center, rx: rx * 1.08, ry: ry * 1.10, color: Palette.outline, segments: 40)
        mesh.addEllipse(center: center, rx: rx, ry: ry, color: Palette.eyeWhite, segments: 38)

        if blink < 0.82 {
            let irisOffset = CGPoint(
                x: CGFloat(gaze.x) * rx * 0.34,
                y: CGFloat(gaze.y) * ry * 0.30
            )
            let irisCenter = CGPoint(x: center.x + irisOffset.x, y: center.y + irisOffset.y)
            let irisScale = 0.46 + 0.05 * focus
            mesh.addEllipse(
                center: irisCenter,
                rx: rx * irisScale,
                ry: ry * irisScale,
                color: Palette.irisDark,
                segments: 30
            )
            mesh.addEllipse(
                center: irisCenter,
                rx: rx * irisScale * 0.74,
                ry: ry * irisScale * 0.74,
                color: Palette.iris,
                segments: 28
            )
            mesh.addEllipse(
                center: irisCenter,
                rx: rx * 0.19,
                ry: ry * 0.21,
                color: Palette.pupil,
                segments: 24
            )
            mesh.addEllipse(
                center: CGPoint(x: irisCenter.x - rx * 0.14, y: irisCenter.y + ry * 0.22),
                rx: rx * 0.095,
                ry: ry * 0.12,
                color: Palette.white,
                segments: 18
            )
            mesh.addEllipse(
                center: CGPoint(x: irisCenter.x + rx * 0.09, y: irisCenter.y + ry * 0.08),
                rx: rx * 0.043,
                ry: ry * 0.055,
                color: Palette.white.withAlpha(0.92),
                segments: 14
            )
        } else {
            let lid = [
                CGPoint(x: center.x - rx, y: center.y),
                CGPoint(x: center.x, y: center.y - 0.006),
                CGPoint(x: center.x + rx, y: center.y)
            ]
            mesh.addRibbon(
                points: lid,
                widths: [0.010, 0.014, 0.010],
                leftColor: Palette.outline,
                rightColor: Palette.outline
            )
        }
    }

    private func addMouth(
        time: CGFloat,
        behavior: MigiBehaviorFrame,
        transform: PoseTransform,
        mesh: inout ColorMesh
    ) {
        let tension = behavior.activity == .failed ? 0.55 : 0.15
        let open = 0.014 + tension * 0.018 + 0.004 * sin(time * 1.7)
        let center = transform.apply(CGPoint(x: 0.50, y: 0.29))
        mesh.addEllipse(
            center: center,
            rx: 0.080 * transform.aspect,
            ry: 0.035 + open,
            color: Palette.lipDark,
            segments: 32
        )
        mesh.addEllipse(
            center: center,
            rx: 0.068 * transform.aspect,
            ry: 0.020 + open * 0.55,
            color: Palette.mouth,
            segments: 30
        )
        for tooth in -2...2 {
            let x = center.x + CGFloat(tooth) * 0.020 * transform.aspect
            mesh.addQuad(
                CGRect(x: x - 0.007 * transform.aspect, y: center.y + 0.002, width: 0.014 * transform.aspect, height: 0.014),
                color: Palette.tooth
            )
        }
    }

    private func addProp(
        time: CGFloat,
        behavior: MigiBehaviorFrame,
        transform: PoseTransform,
        textures: inout TextureMesh,
        colors: inout ColorMesh
    ) {
        switch behavior.prop {
        case .none:
            if behavior.microAction == .sharpenTip {
                let base = transform.apply(CGPoint(x: 0.25, y: 0.39))
                let tip = transform.apply(CGPoint(x: 0.14, y: 0.53))
                colors.addPolygon(
                    [
                        base,
                        CGPoint(x: tip.x + 0.018 * transform.aspect, y: tip.y - 0.018),
                        tip,
                        CGPoint(x: tip.x - 0.012 * transform.aspect, y: tip.y + 0.016)
                    ],
                    color: Palette.blade
                )
                colors.addRibbon(
                    points: [base, tip],
                    widths: [0.018, 0.005],
                    leftColor: Palette.outline,
                    rightColor: Palette.outline
                )
            }

        case .phone:
            if partsTexture != nil {
                textures.addSprite(
                    slot: 6,
                    center: transform.apply(CGPoint(x: 0.66, y: 0.39)),
                    size: CGSize(width: 0.18 * transform.aspect, height: 0.17),
                    rotation: -0.13 * transform.facing,
                    mirrored: false,
                    alpha: 1
                )
            } else {
                colors.addRoundedRect(
                    center: transform.apply(CGPoint(x: 0.66, y: 0.39)),
                    size: CGSize(width: 0.095 * transform.aspect, height: 0.16),
                    radius: 0.018,
                    color: Palette.device
                )
            }

        case .book:
            if partsTexture != nil {
                textures.addSprite(
                    slot: 7,
                    center: transform.apply(CGPoint(x: 0.53, y: 0.26)),
                    size: CGSize(width: 0.40 * transform.aspect, height: 0.23),
                    rotation: 0,
                    mirrored: false,
                    alpha: 1
                )
            } else {
                let center = transform.apply(CGPoint(x: 0.53, y: 0.25))
                colors.addQuad(
                    CGRect(x: center.x - 0.18 * transform.aspect, y: center.y - 0.04, width: 0.18 * transform.aspect, height: 0.12),
                    color: Palette.paper
                )
                colors.addQuad(
                    CGRect(x: center.x, y: center.y - 0.04, width: 0.18 * transform.aspect, height: 0.12),
                    color: Palette.paper
                )
            }

        case .laptop:
            if partsTexture != nil {
                textures.addSprite(
                    slot: 8,
                    center: transform.apply(CGPoint(x: 0.52, y: 0.235)),
                    size: CGSize(width: 0.34 * transform.aspect, height: 0.23),
                    rotation: 0,
                    mirrored: false,
                    alpha: 1
                )
            } else {
                let center = transform.apply(CGPoint(x: 0.52, y: 0.28))
                colors.addQuad(
                    CGRect(x: center.x - 0.14 * transform.aspect, y: center.y, width: 0.28 * transform.aspect, height: 0.17),
                    color: Palette.device
                )
                colors.addQuad(
                    CGRect(x: center.x - 0.18 * transform.aspect, y: center.y - 0.04, width: 0.36 * transform.aspect, height: 0.05),
                    color: Palette.deviceLight
                )
            }
        }
    }

    private func addFleshRibbon(
        points: [CGPoint],
        widths: [CGFloat],
        mesh: inout ColorMesh
    ) {
        mesh.addRibbon(
            points: points,
            widths: widths.map { $0 + 0.007 },
            leftColor: Palette.outline,
            rightColor: Palette.outline
        )
        mesh.addRibbon(
            points: points,
            widths: widths,
            leftColor: Palette.fleshLight,
            rightColor: Palette.fleshShadow
        )
    }

    private func addTendrilHighlight(
        points: [CGPoint],
        baseWidth: CGFloat,
        mesh: inout ColorMesh
    ) {
        guard points.count >= 4 else { return }
        let highlightedIndices = points.indices.filter { $0.isMultiple(of: 2) }
        let highlightPoints = highlightedIndices.map { index -> CGPoint in
            let point = points[index]
            let previous = points[max(points.startIndex, index - 1)]
            let next = points[min(points.index(before: points.endIndex), index + 1)]
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(sqrt(dx * dx + dy * dy), 0.0001)
            let normal = CGPoint(x: -dy / length, y: dx / length)
            return CGPoint(
                x: point.x + normal.x * baseWidth * 0.48,
                y: point.y + normal.y * baseWidth * 0.48
            )
        }
        mesh.addRibbon(
            points: highlightPoints,
            widths: taperedWidths(count: highlightPoints.count, start: baseWidth, end: baseWidth * 0.35),
            leftColor: Palette.highlight.withAlpha(0.65),
            rightColor: Palette.highlight.withAlpha(0.12)
        )

        let shadowPoints = highlightedIndices.map { index -> CGPoint in
            let point = points[index]
            let previous = points[max(points.startIndex, index - 1)]
            let next = points[min(points.index(before: points.endIndex), index + 1)]
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(sqrt(dx * dx + dy * dy), 0.0001)
            let normal = CGPoint(x: -dy / length, y: dx / length)
            return CGPoint(
                x: point.x - normal.x * baseWidth * 0.60,
                y: point.y - normal.y * baseWidth * 0.60
            )
        }
        mesh.addRibbon(
            points: shadowPoints,
            widths: taperedWidths(
                count: shadowPoints.count,
                start: baseWidth * 0.42,
                end: baseWidth * 0.16
            ),
            leftColor: Palette.outline.withAlpha(0.15),
            rightColor: Palette.fleshShadow.withAlpha(0.08)
        )
    }

    private func addRootFolds(
        at root: CGPoint,
        scale: CGFloat,
        transform: PoseTransform,
        mesh: inout ColorMesh
    ) {
        let direction = transform.facing
        let aspect = transform.aspect
        let upper = quadratic(
            CGPoint(x: root.x - direction * 0.026 * aspect * scale, y: root.y - 0.004 * scale),
            CGPoint(x: root.x - direction * 0.006 * aspect * scale, y: root.y + 0.017 * scale),
            CGPoint(x: root.x + direction * 0.025 * aspect * scale, y: root.y + 0.006 * scale),
            count: 12
        )
        mesh.addRibbon(
            points: upper,
            widths: taperedWidths(count: upper.count, start: 0.0045 * scale, end: 0.002 * scale),
            leftColor: Palette.outline.withAlpha(0.24),
            rightColor: Palette.fleshShadow.withAlpha(0.14)
        )

        let lower = quadratic(
            CGPoint(x: root.x - direction * 0.020 * aspect * scale, y: root.y - 0.014 * scale),
            CGPoint(x: root.x + direction * 0.002 * aspect * scale, y: root.y - 0.003 * scale),
            CGPoint(x: root.x + direction * 0.021 * aspect * scale, y: root.y - 0.010 * scale),
            count: 10
        )
        mesh.addRibbon(
            points: lower,
            widths: taperedWidths(count: lower.count, start: 0.0032 * scale, end: 0.0015 * scale),
            leftColor: Palette.outline.withAlpha(0.16),
            rightColor: Palette.fleshShadow.withAlpha(0.08)
        )
    }

    private func blinkValue(time: CGFloat, microAction: MigiMicroAction) -> CGFloat {
        if microAction == .blink {
            return min(1, max(0, sin(time * 9.0) * 1.4))
        }
        let cycle = time.truncatingRemainder(dividingBy: 5.7)
        if cycle < 0.16 {
            return sin((cycle / 0.16) * .pi)
        }
        return 0
    }

    private static func loadPartsTexture(device: MTLDevice) -> MTLTexture? {
        let installedBundle = Bundle.main.resourceURL?
            .appendingPathComponent("MigiAdvanced_MigiAdvanced.bundle", isDirectory: true)
        let installedURL = installedBundle?
            .appendingPathComponent("migi-parts.png", isDirectory: false)
        let url = installedURL.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? Bundle.module.url(forResource: "migi-parts", withExtension: "png")
        guard let url else {
            return nil
        }
        let loader = MTKTextureLoader(device: device)
        return try? loader.newTexture(
            URL: url,
            options: [
                .origin: MTKTextureLoader.Origin.topLeft,
                .SRGB: true
            ]
        )
    }

    private static func makePipeline(
        device: MTLDevice,
        library: MTLLibrary,
        vertex: String,
        fragment: String,
        sampleCount: Int
    ) -> MTLRenderPipelineState {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.rasterSampleCount = sampleCount
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        do {
            return try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            fatalError("Unable to create Migi render pipeline: \(error)")
        }
    }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct ColorVertex {
        float2 position;
        float4 color;
    };

    struct ColorOut {
        float4 position [[position]];
        float4 color;
    };

    vertex ColorOut colorVertex(
        const device ColorVertex *vertices [[buffer(0)]],
        uint vertexID [[vertex_id]]
    ) {
        ColorOut out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.color = vertices[vertexID].color;
        return out;
    }

    fragment float4 colorFragment(ColorOut in [[stage_in]]) {
        return in.color;
    }

    struct TextureVertex {
        float2 position;
        float2 uv;
        float4 tint;
    };

    struct TextureOut {
        float4 position [[position]];
        float2 uv;
        float4 tint;
    };

    vertex TextureOut textureVertex(
        const device TextureVertex *vertices [[buffer(0)]],
        uint vertexID [[vertex_id]]
    ) {
        TextureOut out;
        out.position = float4(vertices[vertexID].position, 0.0, 1.0);
        out.uv = vertices[vertexID].uv;
        out.tint = vertices[vertexID].tint;
        return out;
    }

    fragment float4 textureFragment(
        TextureOut in [[stage_in]],
        texture2d<float> texture [[texture(0)]]
    ) {
        constexpr sampler textureSampler(
            mag_filter::linear,
            min_filter::linear,
            mip_filter::linear,
            address::clamp_to_edge
        );
        return texture.sample(textureSampler, in.uv) * in.tint;
    }
    """
}

private struct PoseTransform {
    let facing: CGFloat
    let yOffset: CGFloat
    let yScale: CGFloat
    let aspect: CGFloat

    func apply(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: 0.5 + (point.x - 0.5) * facing * aspect,
            y: 0.5 + (point.y - 0.5) * yScale + yOffset
        )
    }
}

private struct ColorVertex {
    var position: SIMD2<Float>
    var color: SIMD4<Float>
}

private struct TextureVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
    var tint: SIMD4<Float>
}

private struct ColorMesh {
    var vertices: [ColorVertex] = []

    mutating func addTriangle(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, colors: (RGBA, RGBA, RGBA)) {
        vertices.append(ColorVertex(position: metalPoint(a), color: colors.0.vector))
        vertices.append(ColorVertex(position: metalPoint(b), color: colors.1.vector))
        vertices.append(ColorVertex(position: metalPoint(c), color: colors.2.vector))
    }

    mutating func addPolygon(_ points: [CGPoint], color: RGBA) {
        guard points.count >= 3 else { return }
        let center = CGPoint(
            x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
            y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
        )
        for index in points.indices {
            let next = points[(index + 1) % points.count]
            addTriangle(center, points[index], next, colors: (color, color, color))
        }
    }

    mutating func addGradientPolygon(
        _ points: [CGPoint],
        edgeColors: [RGBA],
        centerColor: RGBA
    ) {
        guard points.count >= 3, edgeColors.count == points.count else { return }
        let center = CGPoint(
            x: points.map(\.x).reduce(0, +) / CGFloat(points.count),
            y: points.map(\.y).reduce(0, +) / CGFloat(points.count)
        )
        for index in points.indices {
            let nextIndex = (index + 1) % points.count
            addTriangle(
                center,
                points[index],
                points[nextIndex],
                colors: (centerColor, edgeColors[index], edgeColors[nextIndex])
            )
        }
    }

    mutating func addRibbon(
        points: [CGPoint],
        widths: [CGFloat],
        leftColor: RGBA,
        rightColor: RGBA
    ) {
        guard points.count >= 2, widths.count == points.count else { return }
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(points.count)
        right.reserveCapacity(points.count)

        for index in points.indices {
            let previous = points[max(0, index - 1)]
            let next = points[min(points.count - 1, index + 1)]
            let dx = next.x - previous.x
            let dy = next.y - previous.y
            let length = max(sqrt(dx * dx + dy * dy), 0.0001)
            let normal = CGPoint(x: -dy / length, y: dx / length)
            let radius = widths[index] * 0.5
            left.append(CGPoint(x: points[index].x + normal.x * radius, y: points[index].y + normal.y * radius))
            right.append(CGPoint(x: points[index].x - normal.x * radius, y: points[index].y - normal.y * radius))
        }

        for index in 0..<(points.count - 1) {
            addTriangle(left[index], right[index], left[index + 1], colors: (leftColor, rightColor, leftColor))
            addTriangle(right[index], right[index + 1], left[index + 1], colors: (rightColor, rightColor, leftColor))
        }

        addEllipse(
            center: points[0],
            rx: widths[0] * 0.5,
            ry: widths[0] * 0.5,
            color: RGBA.mix(leftColor, rightColor, amount: 0.5),
            segments: 18
        )
        if let final = points.last, let finalWidth = widths.last {
            addEllipse(
                center: final,
                rx: finalWidth * 0.5,
                ry: finalWidth * 0.5,
                color: RGBA.mix(leftColor, rightColor, amount: 0.5),
                segments: 18
            )
        }
    }

    mutating func addEllipse(
        center: CGPoint,
        rx: CGFloat,
        ry: CGFloat,
        color: RGBA,
        segments: Int
    ) {
        guard segments >= 3 else { return }
        for segment in 0..<segments {
            let a0 = CGFloat(segment) / CGFloat(segments) * .pi * 2
            let a1 = CGFloat(segment + 1) / CGFloat(segments) * .pi * 2
            let p0 = CGPoint(x: center.x + cos(a0) * rx, y: center.y + sin(a0) * ry)
            let p1 = CGPoint(x: center.x + cos(a1) * rx, y: center.y + sin(a1) * ry)
            addTriangle(center, p0, p1, colors: (color, color, color))
        }
    }

    mutating func addQuad(_ rect: CGRect, color: RGBA) {
        let a = CGPoint(x: rect.minX, y: rect.minY)
        let b = CGPoint(x: rect.maxX, y: rect.minY)
        let c = CGPoint(x: rect.maxX, y: rect.maxY)
        let d = CGPoint(x: rect.minX, y: rect.maxY)
        addTriangle(a, b, c, colors: (color, color, color))
        addTriangle(a, c, d, colors: (color, color, color))
    }

    mutating func addRoundedRect(center: CGPoint, size: CGSize, radius: CGFloat, color: RGBA) {
        addQuad(
            CGRect(
                x: center.x - size.width * 0.5 + radius,
                y: center.y - size.height * 0.5,
                width: size.width - radius * 2,
                height: size.height
            ),
            color: color
        )
        addQuad(
            CGRect(
                x: center.x - size.width * 0.5,
                y: center.y - size.height * 0.5 + radius,
                width: size.width,
                height: size.height - radius * 2
            ),
            color: color
        )
        for offset in [
            CGPoint(x: -size.width * 0.5 + radius, y: -size.height * 0.5 + radius),
            CGPoint(x: size.width * 0.5 - radius, y: -size.height * 0.5 + radius),
            CGPoint(x: -size.width * 0.5 + radius, y: size.height * 0.5 - radius),
            CGPoint(x: size.width * 0.5 - radius, y: size.height * 0.5 - radius)
        ] {
            addEllipse(
                center: CGPoint(x: center.x + offset.x, y: center.y + offset.y),
                rx: radius,
                ry: radius,
                color: color,
                segments: 16
            )
        }
    }
}

private struct TextureMesh {
    var vertices: [TextureVertex] = []

    mutating func addSprite(
        slot: Int,
        center: CGPoint,
        size: CGSize,
        rotation: CGFloat,
        mirrored: Bool,
        alpha: CGFloat
    ) {
        guard PartAtlas.uvRects.indices.contains(slot) else { return }
        let uv = PartAtlas.uvRects[slot]
        var u0 = Float(uv.minX)
        var u1 = Float(uv.maxX)
        if mirrored {
            swap(&u0, &u1)
        }
        let v0 = Float(uv.minY)
        let v1 = Float(uv.maxY)
        let half = CGPoint(x: size.width * 0.5, y: size.height * 0.5)
        let local = [
            CGPoint(x: -half.x, y: -half.y),
            CGPoint(x: half.x, y: -half.y),
            CGPoint(x: half.x, y: half.y),
            CGPoint(x: -half.x, y: half.y)
        ].map { point -> CGPoint in
            let x = point.x * cos(rotation) - point.y * sin(rotation)
            let y = point.x * sin(rotation) + point.y * cos(rotation)
            return CGPoint(x: center.x + x, y: center.y + y)
        }
        let tint = SIMD4<Float>(1, 1, 1, Float(alpha))
        let data: [(CGPoint, SIMD2<Float>)] = [
            (local[0], SIMD2<Float>(u0, v1)),
            (local[1], SIMD2<Float>(u1, v1)),
            (local[2], SIMD2<Float>(u1, v0)),
            (local[0], SIMD2<Float>(u0, v1)),
            (local[2], SIMD2<Float>(u1, v0)),
            (local[3], SIMD2<Float>(u0, v0))
        ]
        vertices.append(contentsOf: data.map {
            TextureVertex(position: metalPoint($0.0), uv: $0.1, tint: tint)
        })
    }
}

private enum PartAtlas {
    private static let width: CGFloat = 1_646
    private static let height: CGFloat = 956

    // Deterministic alpha-component bounds from the generated parts master,
    // expanded by six source pixels to retain antialiased edge coverage.
    private static let pixelRects: [CGRect] = [
        // Torso intentionally omits the component's flat assembly lip; the
        // renderer supplies a deforming shoulder blend over this lower crop.
        CGRect(x: 83, y: 105, width: 384, height: 283),  // torso lower body
        CGRect(x: 564, y: 30, width: 149, height: 349),  // tall eye stalk
        CGRect(x: 928, y: 138, width: 148, height: 227), // small eye stalk
        CGRect(x: 1196, y: 72, width: 303, height: 307),// flexible tendril
        CGRect(x: 83, y: 422, width: 377, height: 175),  // hand tendril
        CGRect(x: 512, y: 407, width: 312, height: 204), // probe tendril
        CGRect(x: 878, y: 446, width: 222, height: 172), // phone
        CGRect(x: 1200, y: 431, width: 382, height: 191),// book
        CGRect(x: 98, y: 631, width: 341, height: 267),  // laptop
        CGRect(x: 533, y: 700, width: 233, height: 164), // closed eyelid
        CGRect(x: 860, y: 697, width: 299, height: 186), // blade tip
        CGRect(x: 1271, y: 716, width: 211, height: 144) // mouth
    ]

    static let uvRects: [CGRect] = pixelRects.map { rect in
        CGRect(
            x: rect.minX / width,
            y: rect.minY / height,
            width: rect.width / width,
            height: rect.height / height
        )
    }
}

private struct RGBA {
    var r: Float
    var g: Float
    var b: Float
    var a: Float

    var vector: SIMD4<Float> { SIMD4<Float>(r, g, b, a) }

    func withAlpha(_ alpha: Float) -> RGBA {
        RGBA(r: r, g: g, b: b, a: alpha)
    }

    static func mix(_ a: RGBA, _ b: RGBA, amount: Float) -> RGBA {
        let t = min(max(amount, 0), 1)
        return RGBA(
            r: a.r + (b.r - a.r) * t,
            g: a.g + (b.g - a.g) * t,
            b: a.b + (b.b - a.b) * t,
            a: a.a + (b.a - a.a) * t
        )
    }
}

private enum Palette {
    static let outline = RGBA(r: 0.22, g: 0.12, b: 0.075, a: 1)
    static let flesh = RGBA(r: 0.88, g: 0.68, b: 0.46, a: 1)
    static let fleshLight = RGBA(r: 0.96, g: 0.80, b: 0.59, a: 1)
    static let fleshShadow = RGBA(r: 0.66, g: 0.43, b: 0.27, a: 1)
    static let bridgeFlesh = RGBA(r: 0.86, g: 0.68, b: 0.49, a: 1)
    static let bridgeLight = RGBA(r: 0.97, g: 0.82, b: 0.63, a: 1)
    static let highlight = RGBA(r: 1.0, g: 0.93, b: 0.78, a: 1)
    static let eyeWhite = RGBA(r: 0.98, g: 0.97, b: 0.90, a: 1)
    static let iris = RGBA(r: 0.61, g: 0.59, b: 0.12, a: 1)
    static let irisDark = RGBA(r: 0.30, g: 0.28, b: 0.055, a: 1)
    static let pupil = RGBA(r: 0.025, g: 0.022, b: 0.016, a: 1)
    static let white = RGBA(r: 1, g: 1, b: 1, a: 1)
    static let lipDark = RGBA(r: 0.47, g: 0.24, b: 0.18, a: 1)
    static let mouth = RGBA(r: 0.15, g: 0.075, b: 0.065, a: 1)
    static let tooth = RGBA(r: 0.94, g: 0.90, b: 0.76, a: 1)
    static let device = RGBA(r: 0.10, g: 0.11, b: 0.12, a: 1)
    static let deviceLight = RGBA(r: 0.30, g: 0.32, b: 0.34, a: 1)
    static let paper = RGBA(r: 0.93, g: 0.89, b: 0.76, a: 1)
    static let blade = RGBA(r: 0.82, g: 0.86, b: 0.88, a: 1)
}

private func metalPoint(_ point: CGPoint) -> SIMD2<Float> {
    SIMD2<Float>(
        Float(point.x * 2 - 1),
        Float(point.y * 2 - 1)
    )
}

/// Adds a travelling, root-to-tip deformation without moving the attachment point.
/// Each appendage receives a different phase and wavelength, avoiding synchronized
/// "template mascot" motion while retaining a stable, readable silhouette.
private func organicCurve(
    _ points: [CGPoint],
    time: CGFloat,
    phase: CGFloat,
    amplitude: CGFloat,
    waveCount: CGFloat
) -> [CGPoint] {
    guard points.count >= 3 else { return points }
    return points.indices.map { index in
        let previous = points[max(points.startIndex, index - 1)]
        let next = points[min(points.index(before: points.endIndex), index + 1)]
        let dx = next.x - previous.x
        let dy = next.y - previous.y
        let length = max(sqrt(dx * dx + dy * dy), 0.0001)
        let normal = CGPoint(x: -dy / length, y: dx / length)
        let t = CGFloat(index) / CGFloat(points.count - 1)
        let envelope = t * t * (3 - 2 * t)
        let travellingWave = sin(time * 1.28 - t * waveCount * .pi * 2 + phase)
        let offset = amplitude * envelope * travellingWave
        return CGPoint(
            x: points[index].x + normal.x * offset,
            y: points[index].y + normal.y * offset
        )
    }
}

/// A subtle per-segment pulse makes the silhouette compress and release as the
/// travelling wave passes. The endpoints remain stable for clean body/eye joins.
private func livingWidths(
    count: Int,
    start: CGFloat,
    end: CGFloat,
    time: CGFloat,
    phase: CGFloat,
    energy: CGFloat
) -> [CGFloat] {
    let base = taperedWidths(count: count, start: start, end: end)
    guard count > 2 else { return base }
    return base.enumerated().map { index, width in
        let t = CGFloat(index) / CGFloat(count - 1)
        let endpointGuard = sin(t * .pi)
        let pulse = sin(time * 1.16 - t * .pi * 4.2 + phase)
        return max(0.004, width + endpointGuard * pulse * (0.0015 + 0.0025 * energy))
    }
}

private func taperedWidths(count: Int, start: CGFloat, end: CGFloat) -> [CGFloat] {
    guard count > 1 else { return [start] }
    return (0..<count).map { index in
        let t = CGFloat(index) / CGFloat(count - 1)
        let eased = t * t * (3 - 2 * t)
        return start + (end - start) * eased
    }
}

private func cubic(
    _ p0: CGPoint,
    _ p1: CGPoint,
    _ p2: CGPoint,
    _ p3: CGPoint,
    count: Int
) -> [CGPoint] {
    guard count > 1 else { return [p0] }
    return (0..<count).map { index in
        let t = CGFloat(index) / CGFloat(count - 1)
        let u = 1 - t
        return CGPoint(
            x: u * u * u * p0.x + 3 * u * u * t * p1.x + 3 * u * t * t * p2.x + t * t * t * p3.x,
            y: u * u * u * p0.y + 3 * u * u * t * p1.y + 3 * u * t * t * p2.y + t * t * t * p3.y
        )
    }
}

private func quadratic(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, count: Int) -> [CGPoint] {
    guard count > 1 else { return [p0] }
    return (0..<count).map { index in
        let t = CGFloat(index) / CGFloat(count - 1)
        let u = 1 - t
        return CGPoint(
            x: u * u * p0.x + 2 * u * t * p1.x + t * t * p2.x,
            y: u * u * p0.y + 2 * u * t * p1.y + t * t * p2.y
        )
    }
}

private func closedCatmullRom(_ points: [CGPoint], samplesPerSegment: Int) -> [CGPoint] {
    guard points.count >= 4 else { return points }
    var result: [CGPoint] = []
    for index in points.indices {
        let p0 = points[(index - 1 + points.count) % points.count]
        let p1 = points[index]
        let p2 = points[(index + 1) % points.count]
        let p3 = points[(index + 2) % points.count]
        for sample in 0..<samplesPerSegment {
            let t = CGFloat(sample) / CGFloat(samplesPerSegment)
            let t2 = t * t
            let t3 = t2 * t
            result.append(
                CGPoint(
                    x: 0.5 * (
                        2 * p1.x
                        + (-p0.x + p2.x) * t
                        + (2 * p0.x - 5 * p1.x + 4 * p2.x - p3.x) * t2
                        + (-p0.x + 3 * p1.x - 3 * p2.x + p3.x) * t3
                    ),
                    y: 0.5 * (
                        2 * p1.y
                        + (-p0.y + p2.y) * t
                        + (2 * p0.y - 5 * p1.y + 4 * p2.y - p3.y) * t2
                        + (-p0.y + 3 * p1.y - 3 * p2.y + p3.y) * t3
                    )
                )
            )
        }
    }
    return result
}
