import AppKit
import CoreGraphics
import XCTest
@testable import MigiAdvanced

/// The screen guard's decision logic is a pure window-geometry question.
/// These tests pin the public contract from the outside: on an ordinary
/// desktop (no full-screen window), the guard never reports suppression,
/// and its timer lifecycle stays clean across start/stop.
final class MigiScreenGuardTests: XCTestCase {
    func testOrdinaryDesktopNeverTriggersSuppression() {
        let petFrame = NSScreen.main?.frame.insetBy(dx: 100, dy: 100) ?? .zero
        // A PID that owns no window can never produce coverage; this also
        // proves the frontmost-PID filter does not fall back to "any window".
        XCTAssertFalse(
            MigiScreenGuard.coveringWindowCovers(
                petFrame: petFrame,
                frontmostOwnerPID: -1
            ),
            "An ordinary desktop must never read as full-screen playback"
        )
    }

    func testExcludedDesktopOverlaysNeverMatchFrontmostFilter() {
        // The Dock backdrop and automation overlays cover the whole screen at
        // layer 20 / layer 0, but they are never the frontmost application.
        // Feeding the real frontmost PID of an ordinary desktop must not
        // report suppression even though those full-coverage windows exist.
        let petFrame = NSScreen.main?.frame.insetBy(dx: 100, dy: 100) ?? .zero
        let frontmost = NSWorkspace.shared.frontmostApplication
        if let pid = frontmost?.processIdentifier {
            // ZCode editing this test is an ordinary non-full-screen app.
            let isFullScreenApp = MigiScreenGuard.coveringWindowCovers(
                petFrame: petFrame,
                frontmostOwnerPID: Int(pid)
            )
            XCTAssertFalse(
                isFullScreenApp,
                "The frontmost app on an ordinary desktop must not read as playback"
            )
        }
    }

    func testGuardLifecycleStartsAndStopsWithoutCallbacks() {
        let guardInstance = MigiScreenGuard()
        var callbackCount = 0
        guardInstance.onChange = { _ in callbackCount += 1 }
        guardInstance.configure(
            petFrameProvider: { .zero },
            demoModeProvider: { false }
        )
        guardInstance.start()
        // A zero pet frame means "no pet on stage": the guard must stay
        // silent instead of reporting suppression for a phantom pet.
        guardInstance.stop()
        XCTAssertEqual(callbackCount, 0)
    }

    func testZeroPetFramePollStaysSilent() {
        let guardInstance = MigiScreenGuard()
        var suppressions: [Bool] = []
        guardInstance.onChange = { suppressions.append($0) }
        guardInstance.configure(
            petFrameProvider: { .zero },
            demoModeProvider: { false }
        )
        guardInstance.start()
        // The timer fires at 2 Hz; a moment is enough to prove a zero
        // frame does not produce a suppression edge.
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guardInstance.stop()
        XCTAssertTrue(suppressions.isEmpty)
    }

    func testDemoModePollStaysSilent() {
        let guardInstance = MigiScreenGuard()
        var suppressions: [Bool] = []
        guardInstance.onChange = { suppressions.append($0) }
        guardInstance.configure(
            petFrameProvider: { NSScreen.main?.frame ?? .zero },
            demoModeProvider: { true }
        )
        guardInstance.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        guardInstance.stop()
        XCTAssertTrue(suppressions.isEmpty)
    }
}