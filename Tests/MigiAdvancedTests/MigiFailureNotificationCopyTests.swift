import XCTest
@testable import MigiAdvanced

final class MigiFailureNotificationCopyTests: XCTestCase {
    func testRoutineFailureSubtitleReflectsRelationshipStage() {
        let expectations: [(MigiRelationshipStage, String)] = [
            (.cautious, "需要你确认。"),
            (.cooperative, "建议你确认。"),
            (.protective, "我会继续观察；请你确认。"),
        ]

        for (stage, expectedSubtitle) in expectations {
            let copy = MigiFailureNotificationCopy.make(
                source: "Codex",
                detail: "Tool failed",
                relationshipStage: stage,
                failureDisposition: .routine
            )

            XCTAssertEqual(copy.title, "Migi：Codex任务异常")
            XCTAssertEqual(copy.subtitle, expectedSubtitle)
        }
    }

    func testCredibleThreatOverridesEveryRelationshipStage() {
        for stage in MigiRelationshipStage.allCases {
            let copy = MigiFailureNotificationCopy.make(
                source: "Grok",
                detail: "Security event",
                relationshipStage: stage,
                failureDisposition: .credibleThreat
            )

            XCTAssertEqual(
                copy.subtitle,
                "可能涉及安全风险，请立即确认。"
            )
        }
    }

    func testBodyPreservesTrimmedFailureDetail() {
        let copy = MigiFailureNotificationCopy.make(
            source: "ZCode",
            detail: " \n  Compilation failed at line 42. \t",
            relationshipStage: .cooperative,
            failureDisposition: .routine
        )

        XCTAssertEqual(copy.body, "Compilation failed at line 42.")
    }

    func testBodyFallsBackWhenDetailContainsOnlyWhitespace() {
        let copy = MigiFailureNotificationCopy.make(
            source: "Codex",
            detail: " \n\t ",
            relationshipStage: .cautious,
            failureDisposition: .interrupted
        )

        XCTAssertEqual(copy.body, "任务需要检查。")
    }
}
