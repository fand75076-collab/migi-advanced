import AppKit

/// Speech-bubble overlay that echoes the monitored Agent's reply text as a
/// floating, non-activating panel beside the pet.
///
/// The bubble is a sibling of the sprite panel (its own `MigiPanel`), so the
/// Metal renderer and the behavior state machine stay untouched. Text only
/// flows in from the snapshot's `spokenText` field via `showSpeech(_:)`.
final class MigiSpeechBubbleController {
    private let panel: MigiPanel
    private let textField: NSTextField
    private let visualEffect: NSVisualEffectView

    /// Last anchor (pet's on-screen frame) used to reposition the bubble when
    /// the pet roams. Stored so `reposition()` can be called without new input.
    private var petFrame: CGRect = .zero

    /// Safety auto-dismiss if the monitor cannot deliver its normal expiry nil.
    /// Completed turns are ordinarily retired by CodexStateMonitor after 6 s.
    private static let idleTimeout: TimeInterval = 10.0
    /// Maximum characters of reply text shown in the bubble. Longer replies are
    /// truncated with an ellipsis so the bubble stays a glanceable hint, not a
    /// wall of text.
    private static let maxDisplayChars = 240
    private var dismissWorkItem: DispatchWorkItem?
    private var lastRawText = ""
    private var lastRenderedText = ""
    private var lastRevision: UInt64?
    private var screenParametersObserver: NSObjectProtocol?
    private var isFadingOut = false
    /// Invalidates stale dismiss work and fade completions when new text arrives.
    private var visibilityGeneration: UInt64 = 0

    private let maxBubbleWidth: CGFloat = 280
    private let maximumDisplayLines: CGFloat = 10
    private let horizontalPadding: CGFloat = 14
    private let verticalPadding: CGFloat = 10
    private let petGap: CGFloat = 10

    init() {
        textField = NSTextField(labelWithString: "")
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.isEditable = false
        textField.isSelectable = false
        textField.maximumNumberOfLines = 0
        textField.lineBreakMode = .byWordWrapping
        textField.font = .systemFont(ofSize: 13)
        textField.textColor = .labelColor
        textField.alignment = .left
        textField.usesSingleLineMode = false
        textField.cell?.wraps = true
        textField.cell?.isScrollable = false

        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.masksToBounds = true

        visualEffect = NSVisualEffectView()
        visualEffect.material = .popover
        visualEffect.blendingMode = .behindWindow
        visualEffect.state = .active
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true

        container.addSubview(visualEffect)
        container.addSubview(textField)
        visualEffect.autoresizingMask = [.width, .height]
        textField.autoresizingMask = [.width, .height]

        panel = MigiPanel(
            contentRect: NSRect(x: 0, y: 0, width: maxBubbleWidth + 2 * horizontalPadding, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.ignoresMouseEvents = true
        // Mirrors the sprite panel: the bubble never follows a full-screen
        // Space, and MigiScreenGuard hides it during playback anyway.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary]
        panel.contentView = container
        panel.alphaValue = 0

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.reposition()
        }
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    /// Present one monitor-owned utterance. Its revision distinguishes an
    /// identical reply in a later turn from duplicate JSONL representations.
    func showSpeech(_ text: String?, revision: UInt64?, petFrame: CGRect) {
        self.petFrame = petFrame

        guard let text, !text.isEmpty else {
            fadeOut()
            return
        }

        let changed = revision != lastRevision || text != lastRawText
        guard changed else {
            reposition()
            return
        }

        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        isFadingOut = false
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        lastRevision = revision
        lastRawText = text

        let rendered = Self.displayExcerpt(text)
        if rendered != lastRenderedText {
            lastRenderedText = rendered
            textField.stringValue = rendered
            layoutBubble()
        }
        reposition()
        fadeIn(generation: generation)
        scheduleDismiss(after: Self.idleTimeout, generation: generation)
    }

    func clearSpeech(immediate: Bool) {
        fadeOut(immediate: immediate)
    }

    private func scheduleDismiss(after delay: TimeInterval, generation: UInt64) {
        dismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            self.fadeOut(expectedGeneration: generation)
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    static func displayExcerpt(_ text: String) -> String {
        guard text.count > maxDisplayChars else { return text }
        let headCount = 96
        let tailCount = maxDisplayChars - headCount - 1
        return String(text.prefix(headCount)) + "…" + String(text.suffix(tailCount))
    }

    /// Update only the pet's frame (used while roaming to keep the bubble glued
    /// to the pet without changing the text).
    func updatePetFrame(_ frame: CGRect) {
        self.petFrame = frame
        if panel.alphaValue > 0 {
            reposition()
        }
    }

    private func layoutBubble() {
        let font = textField.font ?? .systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributed = NSAttributedString(
            string: lastRenderedText,
            attributes: [.font: font, .paragraphStyle: paragraph]
        )
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let singleLine = attributed.boundingRect(
            with: NSSize(
                width: CGFloat.greatestFiniteMagnitude,
                height: CGFloat.greatestFiniteMagnitude
            ),
            options: options
        )
        let textWidth = min(maxBubbleWidth, max(44, ceil(singleLine.width)))
        let wrapped = attributed.boundingRect(
            with: NSSize(width: textWidth, height: CGFloat.greatestFiniteMagnitude),
            options: options
        )
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let textHeight = min(
            max(lineHeight, ceil(wrapped.height)),
            lineHeight * maximumDisplayLines
        )
        let contentSize = NSSize(
            width: textWidth + 2 * horizontalPadding,
            height: textHeight + 2 * verticalPadding
        )
        panel.setContentSize(contentSize)
        guard let container = panel.contentView else { return }
        visualEffect.frame = container.bounds
        textField.frame = NSRect(
            x: horizontalPadding,
            y: verticalPadding,
            width: textWidth,
            height: textHeight
        )
    }

    private func reposition() {
        guard petFrame != .zero, let screen = screenForPetFrame() else { return }
        panel.setFrameOrigin(
            Self.bubbleOrigin(
                petFrame: petFrame,
                bubbleSize: panel.frame.size,
                visibleFrame: screen.visibleFrame,
                gap: petGap
            )
        )
    }

    private func screenForPetFrame() -> NSScreen? {
        if let centered = NSScreen.screens.first(where: {
            $0.frame.contains(petFrame.center)
        }) {
            return centered
        }
        let scored = NSScreen.screens.map { screen -> (NSScreen, CGFloat) in
            let intersection = NSIntersectionRect(screen.frame, petFrame)
            return (screen, max(0, intersection.width) * max(0, intersection.height))
        }
        if let winner = scored.max(by: { $0.1 < $1.1 }), winner.1 > 0 {
            return winner.0
        }
        return NSScreen.screens.first { $0.frame.contains(petFrame.center) } ?? NSScreen.main
    }

    static func bubbleOrigin(
        petFrame: CGRect,
        bubbleSize: CGSize,
        visibleFrame: CGRect,
        gap: CGFloat = 10
    ) -> CGPoint {
        let maximumX = max(visibleFrame.minX, visibleFrame.maxX - bubbleSize.width)
        let originX = min(
            max(petFrame.midX - bubbleSize.width / 2, visibleFrame.minX),
            maximumX
        )
        let spaceAbove = visibleFrame.maxY - petFrame.maxY - gap
        let spaceBelow = petFrame.minY - visibleFrame.minY - gap
        let proposedY: CGFloat
        if bubbleSize.height <= spaceAbove || spaceAbove >= spaceBelow {
            proposedY = petFrame.maxY + gap
        } else {
            proposedY = petFrame.minY - gap - bubbleSize.height
        }
        let maximumY = max(visibleFrame.minY, visibleFrame.maxY - bubbleSize.height)
        return CGPoint(
            x: originX,
            y: min(max(proposedY, visibleFrame.minY), maximumY)
        )
    }

    private func fadeIn(generation: UInt64) {
        guard generation == visibilityGeneration else { return }
        let wasVisible = panel.isVisible
        panel.orderFrontRegardless()
        if wasVisible {
            panel.alphaValue = 1
            return
        }
        panel.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            panel.animator().alphaValue = 1
        }
    }

    private func fadeOut(
        expectedGeneration: UInt64? = nil,
        immediate: Bool = false
    ) {
        if let expectedGeneration, expectedGeneration != visibilityGeneration {
            return
        }
        if !immediate, isFadingOut {
            return
        }
        if lastRawText.isEmpty, panel.alphaValue == 0 {
            panel.orderOut(nil)
            return
        }
        visibilityGeneration &+= 1
        let generation = visibilityGeneration
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        isFadingOut = !immediate

        if immediate {
            panel.alphaValue = 0
            panel.orderOut(nil)
            finishHiding(generation: generation)
            return
        }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self, self.visibilityGeneration == generation else { return }
            self.panel.orderOut(nil)
            self.finishHiding(generation: generation)
        })
    }

    private func finishHiding(generation: UInt64) {
        guard generation == visibilityGeneration else { return }
        isFadingOut = false
        lastRawText = ""
        lastRenderedText = ""
        lastRevision = nil
        textField.stringValue = ""
        dismissWorkItem = nil
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}
