import XCTest
import simd
@testable import MigiAdvanced

final class MigiMotionDynamicsTests: XCTestCase {
    func testRateChangeNeverRewritesLongRunningPhase() {
        var clock = MigiClipPlaybackClock()
        XCTAssertEqual(clock.sample(identity: "laptop", startedAt: 100, time: 130, targetRate: 1), 30)
        XCTAssertEqual(clock.sample(identity: "laptop", startedAt: 100, time: 130, targetRate: 1.4), 30)
        var previous = clock.elapsed
        for index in 1...120 {
            let rate = index < 60 ? 1.4 : 0.75
            let current = clock.sample(
                identity: "laptop", startedAt: 100,
                time: 130 + Double(index) / 60, targetRate: rate
            )
            XCTAssertGreaterThan(current, previous)
            XCTAssertLessThanOrEqual(current - previous, 1.4 / 60 + 1e-10)
            previous = current
        }
    }

    func testFixedRatesKeepAuthoredTiming() {
        for rate in [0.75, 1, 1.25, 1.4] {
            var clock = MigiClipPlaybackClock()
            for index in 0...240 {
                let time = Double(index) / 60
                XCTAssertEqual(
                    clock.sample(identity: "clip", startedAt: 0, time: time, targetRate: rate),
                    time * rate, accuracy: 1e-10
                )
            }
        }
    }

    func testHandoffLeadInDoesNotConsumeNewGesture() {
        var clock = MigiClipPlaybackClock()
        _ = clock.sample(identity: "laptop", startedAt: 10, time: 12, targetRate: 1)
        XCTAssertEqual(clock.sample(identity: "book", startedAt: 12, time: 12, targetRate: 1), 0)
        for time in [12.01, 12.15, 12.36] {
            XCTAssertEqual(clock.sample(identity: "book", startedAt: 12.36, time: time, targetRate: 1), 0)
        }
        XCTAssertEqual(
            clock.sample(identity: "book", startedAt: 12.36, time: 12.50, targetRate: 1),
            0.14, accuracy: 1e-10
        )
    }

    func testLateDrawCatchesUpWithoutShorteningBehaviorGesture() {
        var clock = MigiClipPlaybackClock()
        _ = clock.sample(identity: "turn", startedAt: 0, time: 0, targetRate: 1)
        XCTAssertEqual(clock.sample(identity: "turn", startedAt: 0, time: 1.01, targetRate: 1), 1.01)
    }

    func testRateSmoothingIsIndependentOfRenderFrequency() {
        func phase(fps: Int) -> Double {
            var clock = MigiClipPlaybackClock()
            _ = clock.sample(identity: "work", startedAt: 0, time: 1, targetRate: 0.75)
            for index in 1...fps {
                _ = clock.sample(identity: "work", startedAt: 0,
                                 time: 1 + Double(index) / Double(fps), targetRate: 1.4)
            }
            return clock.elapsed
        }
        XCTAssertEqual(phase(fps: 15), phase(fps: 60), accuracy: 1e-10)
    }

    func testClockIgnoresInvalidAndBackwardTimestamps() {
        var clock = MigiClipPlaybackClock()
        _ = clock.sample(identity: "work", startedAt: 0, time: 1, targetRate: 1)
        XCTAssertEqual(clock.sample(identity: "work", startedAt: 0, time: .nan, targetRate: 1), 1)
        XCTAssertEqual(clock.sample(identity: "work", startedAt: 0, time: 0.5, targetRate: 1), 1)
        XCTAssertEqual(clock.sample(identity: "work", startedAt: 0, time: 2, targetRate: .nan), 2)
    }

    func testBreathingRemainsContinuousWhenEnergyChanges() {
        var oscillator = MigiBreathingPhase()
        var previous: CGFloat = 0
        for index in 0..<1200 {
            let value = oscillator.advance(deltaTime: 1.0 / 60, energy: index % 2 == 0 ? 0 : 1)
            XCTAssertLessThanOrEqual(abs(value - previous), 0.96 / 60 + 1e-10)
            XCTAssertLessThanOrEqual(abs(value), 1)
            previous = value
        }
    }

    func testDampedGazeMatchesAcrossFrameRatesAndNeverOvershoots() {
        func state(fps: Int) -> (SIMD2<Double>, SIMD2<Double>) {
            var value = SIMD2<Double>.zero
            var velocity = SIMD2<Double>.zero
            for _ in 0..<(fps * 3) {
                MigiDampedMotion.advance(value: &value, velocity: &velocity,
                                        target: SIMD2(0.8, -0.4), stiffness: 5.4,
                                        deltaTime: 1.0 / Double(fps))
                XCTAssertTrue((0...0.8).contains(value.x))
                XCTAssertTrue((-0.4...0).contains(value.y))
            }
            return (value, velocity)
        }
        let coarse = state(fps: 15)
        let fine = state(fps: 60)
        XCTAssertLessThan(simd_length(coarse.0 - fine.0), 1e-12)
        XCTAssertLessThan(simd_length(coarse.1 - fine.1), 1e-12)
    }

    func testFrameRateRisesImmediatelyAndOnlyDropsAfterSettling() {
        var governor = MigiFrameRateGovernor()
        XCTAssertEqual(governor.update(requested: 30, time: 0), 60)
        XCTAssertEqual(governor.update(requested: 30, time: 0.54), 60)
        XCTAssertEqual(governor.update(requested: 30, time: 0.56), 30)
        XCTAssertEqual(governor.update(requested: 60, time: 0.57), 60)
        XCTAssertEqual(governor.update(requested: 30, time: 0.58), 60)
        XCTAssertEqual(governor.update(requested: 60, time: 0.8), 60)
        XCTAssertEqual(governor.update(requested: 15, time: 1), 60)
        XCTAssertEqual(governor.update(requested: 15, time: 1.56), 15)
    }

    func testEyelidsCloseFullyWithoutOverlappingBeforeClosure() {
        let open = MigiEyelidShape(closure: 0)
        XCTAssertEqual(open.upperCut, 1)
        XCTAssertEqual(open.lowerCut, -1)
        for index in 0..<100 {
            let lids = MigiEyelidShape(closure: CGFloat(index) / 100)
            XCTAssertGreaterThan(lids.upperCut, lids.lowerCut)
        }
        let closed = MigiEyelidShape(closure: 1)
        XCTAssertEqual(closed.upperCut, closed.lowerCut, accuracy: 1e-12)
    }

    func testTrailingEyeFinishesItsOwnBlinkAfterLeadingEyeReleases() {
        let release = 10.12
        let trailingTime = release - 0.135
        XCTAssertEqual(MigiBlinkEnvelope.sample(startedAt: 10, releasedAt: release, time: trailingTime), 0)
        XCTAssertEqual(MigiBlinkEnvelope.sample(startedAt: 10, releasedAt: release, time: 10.10), 1)
        XCTAssertEqual(MigiBlinkEnvelope.sample(startedAt: 10, releasedAt: release, time: 10.30), 0)
        let before = MigiBlinkEnvelope.sample(startedAt: 10, releasedAt: nil, time: 10.04)
        let after = MigiBlinkEnvelope.sample(startedAt: 10, releasedAt: 10.04, time: 10.04)
        XCTAssertEqual(before, after, accuracy: 1e-12)
    }
}
