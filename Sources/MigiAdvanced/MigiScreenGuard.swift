import AppKit
import CoreGraphics

/// Detects "the user is watching something full-screen" and asks the pet to
/// leave the stage until it is over.
///
/// One window shape identifies every playback surface this Mac can produce:
/// an on-screen window owned by another process covers (nearly) the whole
/// frame of the pet's screen. Native full-screen Spaces (QuickTime, TV,
/// IINA) and borderless full-screen players (mpv `--fs`, web players) both
/// end up as exactly that shape, so a single low-frequency window-list poll
/// covers both. An ordinary maximized window never reaches the coverage
/// threshold because the menu bar area stays uncovered.
///
/// The check runs at 2 Hz on the main queue and only walks the on-screen
/// window list (no per-window screenshots, no accessibility API, no logs).
/// Demo/QA runs are exempt so captures stay deterministic.
final class MigiScreenGuard {
    /// Fired with `true` when playback-like usage starts, `false` when it ends.
    var onChange: ((Bool) -> Void)?

    /// Demo and QA captures must stay deterministic, so the guard is disabled
    /// while a demo mode is active.
    private var isDisabled = false
    private var suppressActive = false
    private var petFrameProvider: (() -> CGRect)?
    private var demoModeProvider: (() -> Bool)?
    private var pollTimer: DispatchSourceTimer?

    /// Coverage fraction of the pet's screen that another process's window
    /// must reach before the pet steps aside. Full-screen windows cover the
    /// full frame including the menu bar; ordinary maximized windows leave
    /// the menu bar strip to the system, staying below this threshold.
    private static let coverageThreshold: CGFloat = 0.92
    private static let pollInterval: TimeInterval = 2.0

    deinit {
        stopPollTimer()
    }

    /// Wire up after the overlay exists; both providers stay weak-free since
    /// the guard is owned by the overlay controller and dies with it.
    func configure(
        petFrameProvider: @escaping () -> CGRect,
        demoModeProvider: @escaping () -> Bool
    ) {
        self.petFrameProvider = petFrameProvider
        self.demoModeProvider = demoModeProvider
    }

    func start() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now(),
            repeating: Self.pollInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            self?.poll()
        }
        pollTimer = timer
        timer.resume()
    }

    func stop() {
        stopPollTimer()
    }

    private func stopPollTimer() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func poll() {
        if demoModeProvider?() == true {
            if suppressActive {
                // Leaving demo mode re-evaluates immediately on the next poll.
                setSuppressActive(false)
            }
            return
        }
        guard let petFrame = petFrameProvider?(), petFrame != .zero else {
            setSuppressActive(false)
            return
        }
        // A genuine full-screen player is the frontmost application while it
        // is being watched; system chrome and automation overlays (Dock
        // backdrop, CUA driver surfaces) are full-coverage windows that are
        // never frontmost, which excludes them without name-based hacks.
        // The lock/login screen also fronts a full-coverage window and is
        // hidden behind a much higher layer; treat it as suppression too —
        // the pet has no business on a locked screen, and the panel would be
        // buried under the loginwindow layers anyway.
        guard let frontmost = NSWorkspace.shared.frontmostApplication
        else {
            setSuppressActive(false)
            return
        }
        if frontmost.bundleIdentifier == "com.apple.loginwindow" {
            setSuppressActive(true)
            return
        }
        let covering = Self.coveringWindowCovers(
            petFrame: petFrame,
            frontmostOwnerPID: Int(frontmost.processIdentifier)
        )
        setSuppressActive(covering)
    }

    private func setSuppressActive(_ active: Bool) {
        guard active != suppressActive else { return }
        suppressActive = active
        onChange?(active)
    }

    /// True when the frontmost application owns an on-screen window at the
    /// ordinary app plane (layer 0) covering at least `coverageThreshold` of
    /// the pet's screen. Native full-screen Spaces and borderless players
    /// (`mpv --fs`) both present exactly this shape — a layer-0 window that
    /// spans the full frame including the menu-bar strip, which an ordinary
    /// maximized window never reaches.
    static func coveringWindowCovers(
        petFrame: CGRect,
        frontmostOwnerPID: Int
    ) -> Bool {
        guard let screenFrame = screenFrame(containing: petFrame) else {
            return false
        }
        guard let infos = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        let screenArea = screenFrame.width * screenFrame.height
        guard screenArea > 0 else { return false }

        for info in infos {
            guard let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? Int,
                  ownerPID == frontmostOwnerPID
            else {
                continue
            }
            let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat]
            let frame = CGRect(
                x: boundsDict?["X"] ?? 0,
                y: boundsDict?["Y"] ?? 0,
                width: boundsDict?["Width"] ?? 0,
                height: boundsDict?["Height"] ?? 0
            )
            guard frame.width > 0, frame.height > 0 else { continue }
            let intersection = frame.intersection(screenFrame)
            guard !intersection.isNull else { continue }
            let coverage = intersection.width * intersection.height / screenArea
            if coverage >= coverageThreshold {
                return true
            }
        }
        return false
    }

    private static func screenFrame(containing petFrame: CGRect) -> CGRect? {
        let center = CGPoint(x: petFrame.midX, y: petFrame.midY)
        if let containing = NSScreen.screens.first(where: {
            $0.frame.contains(center)
        }) {
            return containing.frame
        }
        // Fallback: the screen with the largest overlap.
        let best = NSScreen.screens
            .map { screen -> (NSScreen, CGFloat)? in
                let intersection = screen.frame.intersection(petFrame)
                guard !intersection.isNull else { return nil }
                return (screen, intersection.width * intersection.height)
            }
            .compactMap { $0 }
            .max { $0.1 < $1.1 }
        return best?.0.frame
    }
}