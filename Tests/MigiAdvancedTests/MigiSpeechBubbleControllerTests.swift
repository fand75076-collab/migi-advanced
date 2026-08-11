import CoreGraphics
import XCTest
@testable import MigiAdvanced

final class MigiSpeechBubbleControllerTests: XCTestCase {
    func testDisplayExcerptLeavesShortTextUnchanged() {
        let text = "Migi is reading a book."

        XCTAssertEqual(
            MigiSpeechBubbleController.displayExcerpt(text),
            text
        )
    }

    func testDisplayExcerptKeepsHeadAndTailWithoutSplittingEmoji() {
        let headEmoji = "👨‍👩‍👧‍👦"
        let tailEmoji = "🧑🏽‍💻"
        let expectedHead = String(repeating: "H", count: 95) + headEmoji
        let omittedMiddle = String(repeating: "M", count: 50)
        let expectedTail = tailEmoji + String(repeating: "T", count: 142)
        let text = expectedHead + omittedMiddle + expectedTail

        let excerpt = MigiSpeechBubbleController.displayExcerpt(text)

        XCTAssertEqual(excerpt.count, 240)
        XCTAssertEqual(excerpt, expectedHead + "…" + expectedTail)
        XCTAssertTrue(excerpt.hasPrefix(expectedHead))
        XCTAssertTrue(excerpt.hasSuffix(expectedTail))
    }

    func testBubbleOriginClampsToNegativeCoordinateSecondaryScreen() {
        let visibleFrame = CGRect(x: -1_920, y: -180, width: 1_920, height: 1_080)
        let petFrame = CGRect(x: -2_050, y: -420, width: 80, height: 80)

        let origin = MigiSpeechBubbleController.bubbleOrigin(
            petFrame: petFrame,
            bubbleSize: CGSize(width: 300, height: 150),
            visibleFrame: visibleFrame,
            gap: 10
        )

        XCTAssertEqual(origin.x, visibleFrame.minX, accuracy: 0.001)
        XCTAssertEqual(origin.y, visibleFrame.minY, accuracy: 0.001)
    }

    func testBubbleOriginUsesBelowWhenThereIsNotEnoughSpaceAbove() {
        let petFrame = CGRect(x: 450, y: 600, width: 100, height: 80)

        let origin = MigiSpeechBubbleController.bubbleOrigin(
            petFrame: petFrame,
            bubbleSize: CGSize(width: 240, height: 120),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 700),
            gap: 10
        )

        XCTAssertEqual(origin.x, 380, accuracy: 0.001)
        XCTAssertEqual(origin.y, 470, accuracy: 0.001)
    }

    func testBubbleOriginUsesVisibleMinimumWhenBubbleIsLargerThanVisibleArea() {
        let visibleFrame = CGRect(x: -1_280, y: -100, width: 1_000, height: 700)

        let origin = MigiSpeechBubbleController.bubbleOrigin(
            petFrame: CGRect(x: -900, y: 160, width: 100, height: 100),
            bubbleSize: CGSize(width: 1_200, height: 900),
            visibleFrame: visibleFrame,
            gap: 10
        )

        XCTAssertEqual(origin.x, visibleFrame.minX, accuracy: 0.001)
        XCTAssertEqual(origin.y, visibleFrame.minY, accuracy: 0.001)
    }
}
