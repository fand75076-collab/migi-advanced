import Foundation

struct MigiFailureNotificationCopy: Equatable {
    let title: String
    let subtitle: String
    let body: String

    static func make(
        source: String,
        detail: String,
        relationshipStage: MigiRelationshipStage,
        failureDisposition: CodexFailureDisposition
    ) -> Self {
        let subtitle: String
        if failureDisposition == .credibleThreat {
            subtitle = "可能涉及安全风险，请立即确认。"
        } else {
            switch relationshipStage {
            case .cautious:
                subtitle = "需要你确认。"
            case .cooperative:
                subtitle = "建议你确认。"
            case .protective:
                subtitle = "我会继续观察；请你确认。"
            }
        }

        let trimmedDetail = detail.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return Self(
            title: "Migi：\(source)任务异常",
            subtitle: subtitle,
            body: trimmedDetail.isEmpty ? "任务需要检查。" : trimmedDetail
        )
    }
}
