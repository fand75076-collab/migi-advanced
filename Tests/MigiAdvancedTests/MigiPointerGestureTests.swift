import CoreGraphics
import XCTest
@testable import MigiAdvanced

final class MigiPointerGestureTests: XCTestCase {
    func testStationaryAndSubthresholdPressesAreTaps() {
        var stationary = MigiPointerGesture()
        stationary.begin(at: .zero, time: 10)
        XCTAssertEqual(
            stationary.end(at: .zero, time: 10.2),
            .tap
        )

        var subthreshold = MigiPointerGesture()
        subthreshold.begin(at: .zero, time: 20)
        XCTAssertFalse(
            subthreshold.update(to: CGPoint(x: 3.9, y: 0))
        )
        XCTAssertEqual(
            subthreshold.end(at: CGPoint(x: 3.9, y: 0), time: 20.3),
            .tap
        )
    }

    func testThresholdIsInclusiveAndDragClassificationIsSticky() {
        var exactThreshold = MigiPointerGesture()
        exactThreshold.begin(at: .zero, time: 10)
        XCTAssertTrue(
            exactThreshold.update(to: CGPoint(x: 4, y: 0))
        )
        XCTAssertEqual(
            exactThreshold.end(at: CGPoint(x: 4, y: 0), time: 10.2),
            .drag
        )

        var returnedToOrigin = MigiPointerGesture()
        returnedToOrigin.begin(at: .zero, time: 20)
        XCTAssertTrue(
            returnedToOrigin.update(to: CGPoint(x: 10, y: 0))
        )
        XCTAssertFalse(returnedToOrigin.update(to: .zero))
        XCTAssertEqual(
            returnedToOrigin.end(at: .zero, time: 20.3),
            .drag
        )
    }

    func testTapDurationBoundaryAndLongPress() {
        var boundary = MigiPointerGesture()
        boundary.begin(at: .zero, time: 10)
        XCTAssertEqual(
            boundary.end(at: .zero, time: 10.6),
            .tap
        )

        var longPress = MigiPointerGesture()
        longPress.begin(at: .zero, time: 20)
        XCTAssertEqual(
            longPress.end(at: .zero, time: 20.600_001),
            .ignored
        )
    }

    func testEndResetsStateForTheNextGesture() {
        var gesture = MigiPointerGesture()
        gesture.begin(at: .zero, time: 10)
        _ = gesture.update(to: CGPoint(x: 8, y: 0))
        XCTAssertEqual(
            gesture.end(at: CGPoint(x: 8, y: 0), time: 10.1),
            .drag
        )
        XCTAssertFalse(gesture.isActive)
        XCTAssertFalse(gesture.didDrag)

        gesture.begin(at: CGPoint(x: 2, y: 3), time: 11)
        XCTAssertEqual(
            gesture.end(at: CGPoint(x: 2, y: 3), time: 11.1),
            .tap
        )
    }

    func testNonFiniteInputIsIgnoredSafely() {
        var gesture = MigiPointerGesture()
        gesture.begin(
            at: CGPoint(x: CGFloat.infinity, y: 0),
            time: 10
        )
        XCTAssertFalse(gesture.isActive)

        gesture.begin(at: .zero, time: 20)
        XCTAssertEqual(
            gesture.end(
                at: CGPoint(x: CGFloat.nan, y: 0),
                time: 20.1
            ),
            .ignored
        )
        XCTAssertFalse(gesture.isActive)
    }
}
