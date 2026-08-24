import Foundation
import XCTest
@testable import MigiAdvanced

final class CodexStateMonitorTests: XCTestCase {
    func testToolActionHintIsCodableAndSnapshotDefaultIsCompatible() throws {
        let encoded = try JSONEncoder().encode(CodexToolActionHint.write)
        XCTAssertEqual(
            try JSONDecoder().decode(CodexToolActionHint.self, from: encoded),
            .write
        )

        let snapshot = CodexActivitySnapshot(
            activity: .idle,
            detail: "Idle",
            observedAt: Date(),
            sourcePath: nil
        )
        XCTAssertEqual(snapshot.toolActionHint, .none)
        XCTAssertNil(snapshot.sourceAgent)
        XCTAssertEqual(snapshot.monitoringGeneration, 0)
        XCTAssertNil(snapshot.latestNovelTool)
        XCTAssertEqual(snapshot.activeAgents, [])
        XCTAssertEqual(snapshot.failureDisposition, .none)
        XCTAssertEqual(snapshot.relationshipProfile, .init())
        XCTAssertNil(snapshot.spokenText)
        XCTAssertNil(snapshot.spokenAgent)
        XCTAssertNil(snapshot.spokenRevision)
        XCTAssertEqual(
            try JSONDecoder().decode(
                AgentMonitoringMode.self,
                from: JSONEncoder().encode(AgentMonitoringMode.all)
            ),
            .all
        )
        XCTAssertEqual(
            try JSONDecoder().decode(
                MonitoredAgent.self,
                from: JSONEncoder().encode(MonitoredAgent.grok)
            ),
            .grok
        )
    }

    func testRelationshipStagesRequireDurationAndToolDiversity() {
        XCTAssertEqual(
            MigiRelationshipProfile(
                cooperationDuration: 24 * 60 * 60,
                familiarToolCount: 1
            ).stage,
            .cautious
        )
        XCTAssertEqual(
            MigiRelationshipProfile(
                cooperationDuration: 30 * 60,
                familiarToolCount: 3
            ).stage,
            .cooperative
        )
        XCTAssertEqual(
            MigiRelationshipProfile(
                cooperationDuration: 12 * 60 * 60,
                familiarToolCount: 10
            ).stage,
            .protective
        )
    }

    func testFailureDispositionIsFailClosedWithoutExplicitThreatEvidence() throws {
        let routine = try Fixture()
        defer { routine.remove() }
        let now = Date()
        try routine.write(
            record(
                type: "task_failed",
                at: now.addingTimeInterval(-1),
                fields: [
                    "status": "failed",
                    "error": "fatal unsafe attack parser wording",
                ]
            )
        )
        XCTAssertEqual(
            routine.monitor.pollSynchronously(now: now).failureDisposition,
            .routine
        )

        let threat = try Fixture()
        defer { threat.remove() }
        try threat.write(
            record(
                type: "security_threat",
                at: now.addingTimeInterval(-1),
                fields: [
                    "status": "failed",
                    "security_threat": true,
                ]
            )
        )
        XCTAssertEqual(
            threat.monitor.pollSynchronously(now: now).failureDisposition,
            .credibleThreat
        )
    }

    func testToolFamiliaritySurvivesMonitorRestart() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        _ = fixture.monitor.pollSynchronously(now: now)

        try fixture.append(
            toolRecord(
                name: "persistent_probe",
                at: now.addingTimeInterval(0.1),
                callID: "first"
            )
        )
        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.2)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.canonicalName, "persistent_probe")
        XCTAssertEqual(snapshot.relationshipProfile.familiarToolCount, 1)

        let restarted = CodexStateMonitor(homeDirectory: fixture.homeURL)
        _ = restarted.pollSynchronously(now: now.addingTimeInterval(3))
        try fixture.append(
            toolRecord(
                name: "PERSISTENT-PROBE",
                at: now.addingTimeInterval(3.1),
                callID: "same-after-restart"
            )
        )
        snapshot = restarted.pollSynchronously(
            now: now.addingTimeInterval(3.2)
        )
        XCTAssertNil(snapshot.latestNovelTool)
        XCTAssertEqual(snapshot.relationshipProfile.familiarToolCount, 1)

        try fixture.append(
            toolRecord(
                name: "second_persistent_probe",
                at: now.addingTimeInterval(3.3),
                callID: "second"
            )
        )
        snapshot = restarted.pollSynchronously(
            now: now.addingTimeInterval(3.4)
        )
        XCTAssertEqual(
            snapshot.latestNovelTool?.canonicalName,
            "second_persistent_probe"
        )
        XCTAssertEqual(snapshot.relationshipProfile.familiarToolCount, 2)
    }

    func testCooperationDurationPersistsWithoutCountingOfflineTime() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        try fixture.write(
            record(
                type: "task_started",
                at: now.addingTimeInterval(-1),
                fields: ["turn_id": "relationship-turn"]
            )
        )

        _ = fixture.monitor.pollSynchronously(now: now)
        let accumulated = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(1)
        )
        XCTAssertEqual(
            accumulated.relationshipProfile.cooperationDuration,
            1,
            accuracy: 0.001
        )

        let restarted = CodexStateMonitor(homeDirectory: fixture.homeURL)
        let restored = restarted.pollSynchronously(
            now: now.addingTimeInterval(3_600)
        )
        XCTAssertEqual(
            restored.relationshipProfile.cooperationDuration,
            1,
            accuracy: 0.001
        )
    }

    func testTaskStartedAndReasoningProduceThinking() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()

        try fixture.write(
            record(
                type: "task_started",
                at: now.addingTimeInterval(-2),
                fields: ["turn_id": "turn-1"]
            )
        )
        var snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .thinking)
        XCTAssertEqual(snapshot.toolActionHint, .none)
        XCTAssertEqual(snapshot.sourceAgent, .codex)

        try fixture.append(
            record(type: "agent_reasoning", at: now.addingTimeInterval(-1))
        )
        snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .thinking)
        XCTAssertEqual(snapshot.detail, "Thinking")
    }

    func testEveryPollRefreshesSelectedFileMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()

        try fixture.write(
            record(
                type: "task_started",
                at: now.addingTimeInterval(-2),
                fields: ["turn_id": "turn-1"]
            )
        )
        XCTAssertEqual(
            fixture.monitor.pollSynchronously(now: now).activity,
            .thinking
        )

        // This second poll is inside the two-second recursive discovery window.
        try fixture.append(
            toolRecord(
                name: "read_mcp_resource",
                at: now.addingTimeInterval(-1),
                callID: "read-1"
            )
        )
        let snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.1)
        )
        XCTAssertEqual(snapshot.activity, .tool)
        XCTAssertEqual(snapshot.toolActionHint, .read)
    }

    func testExplicitToolActionClassificationIsConservative() throws {
        let arguments = try jsonString(["cmd": "echo hello"])
        let readArguments = try jsonString(["cmd": "rg -n Migi Sources"])
        let testArguments = try jsonString(["cmd": "swift test"])
        let cases: [(String, String?, CodexToolActionHint)] = [
            ("read_mcp_resource", nil, .read),
            ("search_query", nil, .read),
            ("apply_patch", nil, .write),
            ("edit_file", nil, .write),
            ("write_file", nil, .write),
            ("web_search", nil, .search),
            ("exec_command", arguments, .execute),
            ("exec_command", testArguments, .verify),
            ("shell_command", readArguments, .read),
        ]

        for (index, item) in cases.enumerated() {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let now = Date()
            var fields: [String: Any] = [
                "name": item.0,
                "call_id": "call-\(index)",
                "status": "completed",
            ]
            if let arguments = item.1 {
                fields["arguments"] = arguments
            }
            try fixture.write(
                record(
                    type: "function_call",
                    at: now.addingTimeInterval(-1),
                    fields: fields
                )
            )

            let snapshot = fixture.monitor.pollSynchronously(now: now)
            XCTAssertEqual(snapshot.activity, .tool, item.0)
            XCTAssertEqual(snapshot.toolActionHint, item.2, item.0)
        }
    }

    func testWaitingReviewAndFailureEventsMapToStableStates() throws {
        let cases: [(String, CodexActivity)] = [
            ("approval_request", .waiting),
            ("task_complete", .review),
            ("task_failed", .failed),
        ]

        for item in cases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let now = Date()
            try fixture.write(
                record(type: item.0, at: now.addingTimeInterval(-1))
            )

            let snapshot = fixture.monitor.pollSynchronously(now: now)
            XCTAssertEqual(snapshot.activity, item.1, item.0)
            XCTAssertEqual(snapshot.toolActionHint, .none, item.0)
        }
    }

    func testPatchAndWebCompletionCarryWriteAndReadHints() throws {
        let cases: [(String, CodexToolActionHint)] = [
            ("patch_apply_end", .write),
            ("web_search_end", .search),
        ]

        for item in cases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let now = Date()
            try fixture.write(
                record(type: item.0, at: now.addingTimeInterval(-1))
            )

            let snapshot = fixture.monitor.pollSynchronously(now: now)
            XCTAssertEqual(snapshot.activity, .tool, item.0)
            XCTAssertEqual(snapshot.toolActionHint, item.1, item.0)
        }
    }

    func testBurstPriorityIsFailedThenWaitingReviewToolThinking() throws {
        let now = Date()
        let start = now.addingTimeInterval(-4)
        let events = [
            record(type: "task_started", at: start),
            toolRecord(
                name: "read_mcp_resource",
                at: start.addingTimeInterval(0.1),
                callID: "read-1"
            ),
            record(type: "review_started", at: start.addingTimeInterval(0.2)),
            record(type: "approval_request", at: start.addingTimeInterval(0.3)),
            record(type: "task_failed", at: start.addingTimeInterval(0.4)),
        ]
        let expected: [CodexActivity] = [
            .thinking, .tool, .review, .waiting, .failed,
        ]

        for count in 1...events.count {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.write(joined(Array(events.prefix(count))))

            let snapshot = fixture.monitor.pollSynchronously(now: now)
            XCTAssertEqual(snapshot.activity, expected[count - 1], "prefix \(count)")
        }
    }

    func testTruncationAndAtomicRotationRecoverAtTheSamePath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        var initial = Data(repeating: 0x20, count: 16_384)
        initial.append(0x0A)
        initial.append(
            record(type: "patch_apply_end", at: now.addingTimeInterval(-2))
        )
        try fixture.write(initial)

        var snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .tool)
        XCTAssertEqual(snapshot.toolActionHint, .write)

        let rotatedURL = fixture.rolloutURL
            .deletingLastPathComponent()
            .appendingPathComponent("rollout-fixture.old.jsonl")
        try FileManager.default.moveItem(at: fixture.rolloutURL, to: rotatedURL)
        let waitingEvent = record(
            type: "approval_request",
            at: now.addingTimeInterval(-1)
        )
        var replacement = Data(
            repeating: 0x20,
            count: initial.count - waitingEvent.count - 1
        )
        replacement.append(0x0A)
        replacement.append(waitingEvent)
        XCTAssertEqual(replacement.count, initial.count)
        try replacement.write(to: fixture.rolloutURL)

        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.1)
        )
        XCTAssertEqual(snapshot.activity, .waiting)
        XCTAssertEqual(snapshot.toolActionHint, .none)
    }

    func testIncrementalCatchUpBeyondOneMiBRetainsTurnAndPartialLine() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()

        try fixture.write(
            record(
                type: "task_started",
                at: now.addingTimeInterval(-3),
                fields: ["turn_id": "large-turn"]
            )
        )
        XCTAssertEqual(
            fixture.monitor.pollSynchronously(now: now).activity,
            .thinking
        )

        // More than the old skip threshold, with no newline yet.
        try fixture.append(Data(repeating: 0x20, count: 1_048_704))
        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.1)
        )
        XCTAssertEqual(snapshot.activity, .thinking)

        let readEvent = toolRecord(
            name: "read_mcp_resource",
            at: now.addingTimeInterval(-1),
            callID: "read-after-burst"
        )
        let split = readEvent.count / 2
        var firstHalf = Data([0x0A])
        firstHalf.append(readEvent.prefix(split))
        try fixture.append(firstHalf)
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.2)
        )
        XCTAssertEqual(snapshot.activity, .thinking)

        try fixture.append(readEvent.suffix(from: split))
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.3)
        )
        XCTAssertEqual(snapshot.activity, .tool)
        XCTAssertEqual(snapshot.toolActionHint, .read)
    }

    func testOversizedPartialLineIsDroppedWithoutErasingRuntimeState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()

        try fixture.write(
            record(
                type: "task_started",
                at: now.addingTimeInterval(-3),
                fields: ["turn_id": "oversized-line-turn"]
            )
        )
        XCTAssertEqual(
            fixture.monitor.pollSynchronously(now: now).activity,
            .thinking
        )

        // Cross the monitor's independent 4 MiB line limit without a newline.
        // Only that malformed/oversized record is discarded.
        try fixture.append(Data(repeating: 0x20, count: 4_194_400))
        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.1)
        )
        XCTAssertEqual(snapshot.activity, .thinking)

        var recovery = Data([0x0A])
        recovery.append(
            toolRecord(
                name: "read_mcp_resource",
                at: now.addingTimeInterval(-1),
                callID: "read-after-oversized-line"
            )
        )
        try fixture.append(recovery)
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.2)
        )
        XCTAssertEqual(snapshot.activity, .tool)
        XCTAssertEqual(snapshot.toolActionHint, .read)
    }

    func testInitialLargeFileStillTailsItsRecentCompleteEvent() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        var data = Data(repeating: 0x20, count: 1_048_704)
        data.append(0x0A)
        data.append(
            record(type: "web_search_end", at: now.addingTimeInterval(-1))
        )
        try fixture.write(data)

        let snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .tool)
        XCTAssertEqual(snapshot.toolActionHint, .search)
    }

    func testSubAgentAndCompactionCarryDistinctHints() throws {
        let cases: [(String, CodexToolActionHint)] = [
            ("sub_agent_activity", .scout),
            ("context_compacted", .compact),
        ]

        for item in cases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let now = Date()
            try fixture.write(
                record(type: item.0, at: now.addingTimeInterval(-1))
            )

            let snapshot = fixture.monitor.pollSynchronously(now: now)
            XCTAssertEqual(snapshot.activity, .tool, item.0)
            XCTAssertEqual(snapshot.toolActionHint, item.1, item.0)
        }
    }

    func testFreshBytesDriveLiveThroughputEstimate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        try fixture.write(record(type: "task_started", at: now.addingTimeInterval(-1)))
        let initial = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(initial.logThroughput, 0)

        let later = now.addingTimeInterval(0.8)
        try fixture.append(record(type: "reasoning", at: later))
        let afterAppend = fixture.monitor.pollSynchronously(now: later)
        XCTAssertGreaterThan(afterAppend.logThroughput, 0)

        let silent = fixture.monitor.pollSynchronously(
            now: later.addingTimeInterval(0.8)
        )
        XCTAssertLessThan(silent.logThroughput, afterAppend.logThroughput)
    }

    func testDefaultModeNeverReadsGrokOrZCode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        try fixture.write(
            record(
                type: "task_started",
                at: now.addingTimeInterval(-2),
                fields: ["turn_id": "codex-only"]
            ),
            for: .codex
        )
        try fixture.write(
            grokRecord(
                updateType: "tool_call_update",
                at: now.addingTimeInterval(-1),
                fields: ["toolCallId": "grok-failure", "status": "failed"]
            ),
            for: .grok
        )
        try fixture.write(
            zcodeRecord(
                startedAt: now.addingTimeInterval(-1),
                completedAt: now.addingTimeInterval(-0.5),
                finishReason: "error",
                error: "provider failed"
            ),
            for: .zcode
        )

        let snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .thinking)
        XCTAssertEqual(snapshot.sourceAgent, .codex)
    }

    func testMonitoringModeSwitchResetsCandidatesAndParserState() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        try fixture.write(
            record(
                type: "task_started",
                at: now.addingTimeInterval(-3),
                fields: ["turn_id": "codex-turn"]
            ),
            for: .codex
        )
        try fixture.write(
            grokRecord(
                updateType: "turn_completed",
                at: now.addingTimeInterval(-2),
                fields: ["stop_reason": "end_turn"]
            ),
            for: .grok
        )
        try fixture.write(
            zcodeRecord(
                startedAt: now.addingTimeInterval(-2),
                completedAt: now.addingTimeInterval(-1),
                finishReason: "tool-calls",
                toolCalls: [["id": "z1", "name": "Read", "input": [:]]]
            ),
            for: .zcode
        )

        var snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .thinking)
        XCTAssertEqual(snapshot.sourceAgent, .codex)

        fixture.monitor.setMonitoringMode(.grok)
        snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .review)
        XCTAssertEqual(snapshot.sourceAgent, .grok)

        fixture.monitor.setMonitoringMode(.zcode)
        snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .tool)
        XCTAssertEqual(snapshot.toolActionHint, .read)
        XCTAssertEqual(snapshot.sourceAgent, .zcode)
    }

    func testCodexFinalAnswerSurvivesTaskCompleteInSamePollWithoutDuplication() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        let turnID = "codex-final-turn"
        let finalText = "A complete Codex fixture answer."

        try fixture.write(
            joined([
                record(
                    type: "task_started",
                    at: now.addingTimeInterval(-1),
                    fields: ["turn_id": turnID]
                ),
                record(
                    type: "agent_message",
                    at: now.addingTimeInterval(-0.3),
                    fields: [
                        "message": finalText,
                        "phase": "final_answer",
                    ]
                ),
                responseItemMessageRecord(
                    text: finalText,
                    phase: "final_answer",
                    turnID: turnID,
                    at: now.addingTimeInterval(-0.2)
                ),
                record(
                    type: "task_complete",
                    at: now.addingTimeInterval(-0.1),
                    fields: [
                        "turn_id": turnID,
                        "last_agent_message": finalText,
                    ]
                ),
            ])
        )

        let snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .review)
        XCTAssertEqual(snapshot.sourceAgent, .codex)
        XCTAssertEqual(snapshot.spokenText, finalText)
        XCTAssertEqual(snapshot.spokenAgent, .codex)
        XCTAssertEqual(snapshot.spokenRevision, 1)
    }

    func testLateTaskCompleteFromOlderTurnDoesNotOverrideNewerActiveTurn() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        let currentText = "Turn B is still actively working."

        try fixture.write(
            joined([
                record(
                    type: "task_started",
                    at: now.addingTimeInterval(-1.0),
                    fields: ["turn_id": "turn-a"]
                ),
                record(
                    type: "task_started",
                    at: now.addingTimeInterval(-0.8),
                    fields: ["turn_id": "turn-b"]
                ),
                record(
                    type: "agent_message",
                    at: now.addingTimeInterval(-0.6),
                    fields: [
                        "message": currentText,
                        "phase": "commentary",
                    ]
                ),
                record(
                    type: "task_complete",
                    at: now.addingTimeInterval(-0.4),
                    fields: [
                        "turn_id": "turn-a",
                        "last_agent_message": "Late answer from obsolete turn A.",
                    ]
                ),
            ])
        )

        let snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .thinking)
        XCTAssertEqual(snapshot.sourceAgent, .codex)
        XCTAssertTrue(snapshot.activeAgents.contains(.codex))
        XCTAssertEqual(snapshot.spokenText, currentText)
        XCTAssertEqual(snapshot.spokenAgent, .codex)
    }

    func testNewerLowerOriginCommentaryWinsAndOlderRecordCannotFlowBackward() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        let turnID = "commentary-order-turn"
        let newestText = "Newer response-item commentary."

        try fixture.write(
            joined([
                record(
                    type: "task_started",
                    at: now.addingTimeInterval(-1.2),
                    fields: ["turn_id": turnID]
                ),
                record(
                    type: "agent_message",
                    at: now.addingTimeInterval(-0.9),
                    fields: [
                        "message": "Earlier event-message commentary.",
                        "phase": "commentary",
                    ]
                ),
                responseItemMessageRecord(
                    text: newestText,
                    phase: "commentary",
                    turnID: turnID,
                    at: now.addingTimeInterval(-0.5)
                ),
                record(
                    type: "agent_message",
                    at: now.addingTimeInterval(-1.0),
                    fields: [
                        "message": "Older record appended later in the file.",
                        "phase": "commentary",
                    ]
                ),
            ])
        )

        let snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .thinking)
        XCTAssertEqual(snapshot.sourceAgent, .codex)
        XCTAssertEqual(snapshot.spokenText, newestText)
        XCTAssertEqual(snapshot.spokenAgent, .codex)
    }

    func testLongRunningCodexTurnUsesLastSpokenTextTimeForFreshness() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        let finalText = "Fresh text from a long-running Codex turn."

        try fixture.write(
            record(
                type: "task_started",
                at: now.addingTimeInterval(-120),
                fields: ["turn_id": "long-running-turn"]
            )
        )
        var snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertNil(snapshot.spokenText)

        try fixture.append(
            record(
                type: "agent_message",
                at: now.addingTimeInterval(0.1),
                fields: [
                    "message": finalText,
                    "phase": "final_answer",
                ]
            )
        )
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.2)
        )
        XCTAssertEqual(snapshot.spokenText, finalText)
        XCTAssertEqual(snapshot.spokenAgent, .codex)
        XCTAssertNotNil(snapshot.spokenRevision)

        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(8)
        )
        XCTAssertEqual(snapshot.spokenText, finalText)

        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(8.2)
        )
        XCTAssertNil(snapshot.spokenText)
        XCTAssertNil(snapshot.spokenAgent)
        XCTAssertNil(snapshot.spokenRevision)
    }

    func testGrokReplySurvivesTurnCompletedInSamePoll() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.grok)
        let now = Date()

        _ = fixture.monitor.pollSynchronously(now: now)
        try fixture.append(
            joined([
                grokRecord(
                    updateType: "agent_message_chunk",
                    at: now.addingTimeInterval(0.1),
                    fields: ["content": ["type": "text", "text": "Grok "]]
                ),
                grokRecord(
                    updateType: "agent_message_chunk",
                    at: now.addingTimeInterval(0.2),
                    fields: ["content": ["type": "text", "text": "answer"]]
                ),
                grokRecord(
                    updateType: "turn_completed",
                    at: now.addingTimeInterval(0.3),
                    fields: [
                        "prompt_id": "grok-prompt",
                        "stop_reason": "end_turn",
                    ]
                ),
            ]),
            for: .grok
        )

        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.4)
        )
        XCTAssertEqual(snapshot.activity, .review)
        XCTAssertEqual(snapshot.sourceAgent, .grok)
        XCTAssertEqual(snapshot.spokenText, "Grok answer")
        XCTAssertEqual(snapshot.spokenAgent, .grok)
        XCTAssertEqual(snapshot.spokenRevision, 2)

        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(6.2)
        )
        XCTAssertEqual(snapshot.spokenText, "Grok answer")

        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(6.4)
        )
        XCTAssertNil(snapshot.spokenText)
        XCTAssertNil(snapshot.spokenAgent)
        XCTAssertNil(snapshot.spokenRevision)
    }

    func testZCodeNewTurnReplacesPreviousTurnSpeech() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.zcode)
        let now = Date()

        _ = fixture.monitor.pollSynchronously(now: now)
        try fixture.append(
            zcodeRecord(
                startedAt: now.addingTimeInterval(0.1),
                completedAt: now.addingTimeInterval(0.2),
                finishReason: "stop",
                turnID: "zcode-turn-one",
                text: "First ZCode answer"
            ),
            for: .zcode
        )
        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.3)
        )
        let firstRevision = try XCTUnwrap(snapshot.spokenRevision)
        XCTAssertEqual(snapshot.spokenText, "First ZCode answer")
        XCTAssertEqual(snapshot.spokenAgent, .zcode)

        try fixture.append(
            zcodeRecord(
                startedAt: now.addingTimeInterval(0.4),
                completedAt: now.addingTimeInterval(0.5),
                finishReason: "stop",
                turnID: "zcode-turn-two",
                text: "Second ZCode answer"
            ),
            for: .zcode
        )
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.6)
        )
        XCTAssertEqual(snapshot.spokenText, "Second ZCode answer")
        XCTAssertEqual(snapshot.spokenAgent, .zcode)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.spokenRevision), firstRevision)
    }

    func testSpokenTextBufferIsBoundedAndKeepsNewestText() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.grok)
        let now = Date()
        let discardedPrefix = "discarded-prefix-"
        let newestSuffix = "-newest-suffix"
        let oversizedChunk = discardedPrefix
            + String(
                repeating: "a",
                count: CodexStateMonitor.maximumSpokenTextCharacters
            )

        _ = fixture.monitor.pollSynchronously(now: now)
        try fixture.append(
            joined([
                grokRecord(
                    updateType: "agent_message_chunk",
                    at: now.addingTimeInterval(0.1),
                    fields: [
                        "content": ["type": "text", "text": oversizedChunk],
                    ]
                ),
                grokRecord(
                    updateType: "agent_message_chunk",
                    at: now.addingTimeInterval(0.2),
                    fields: [
                        "content": ["type": "text", "text": newestSuffix],
                    ]
                ),
            ]),
            for: .grok
        )

        let snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.3)
        )
        let spokenText = try XCTUnwrap(snapshot.spokenText)
        XCTAssertEqual(
            spokenText.count,
            CodexStateMonitor.maximumSpokenTextCharacters
        )
        XCTAssertFalse(spokenText.hasPrefix(discardedPrefix))
        XCTAssertTrue(spokenText.hasSuffix(newestSuffix))
        XCTAssertEqual(snapshot.spokenAgent, .grok)
        XCTAssertEqual(snapshot.spokenRevision, 2)
    }

    func testMonitoringModeSwitchDropsDisabledAgentSpeech() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()

        _ = fixture.monitor.pollSynchronously(now: now)
        try fixture.append(
            joined([
                record(
                    type: "task_started",
                    at: now.addingTimeInterval(0.1),
                    fields: ["turn_id": "mode-switch-turn"]
                ),
                record(
                    type: "agent_message",
                    at: now.addingTimeInterval(0.2),
                    fields: [
                        "message": "Codex mode speech",
                        "phase": "final_answer",
                    ]
                ),
            ])
        )
        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.3)
        )
        XCTAssertEqual(snapshot.spokenText, "Codex mode speech")
        XCTAssertEqual(snapshot.spokenAgent, .codex)
        let codexRevision = try XCTUnwrap(snapshot.spokenRevision)

        let grokGeneration = fixture.monitor.setMonitoringMode(.grok)
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.4)
        )
        XCTAssertEqual(snapshot.monitoringGeneration, grokGeneration)
        XCTAssertNil(snapshot.spokenText)
        XCTAssertNil(snapshot.spokenAgent)
        XCTAssertNil(snapshot.spokenRevision)

        try fixture.append(
            grokRecord(
                updateType: "agent_message_chunk",
                at: now.addingTimeInterval(0.5),
                fields: [
                    "content": ["type": "text", "text": "Grok mode speech"],
                ]
            ),
            for: .grok
        )
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.6)
        )
        XCTAssertEqual(snapshot.spokenText, "Grok mode speech")
        XCTAssertEqual(snapshot.spokenAgent, .grok)
        XCTAssertGreaterThan(try XCTUnwrap(snapshot.spokenRevision), codexRevision)
    }

    func testAllModeSpeechIsIndependentFromActivityWinner() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.all)
        let now = Date()

        _ = fixture.monitor.pollSynchronously(now: now)
        try fixture.append(
            record(
                type: "task_failed",
                at: now.addingTimeInterval(0.3),
                fields: ["status": "failed"]
            ),
            for: .codex
        )
        try fixture.append(
            grokRecord(
                updateType: "agent_message_chunk",
                at: now.addingTimeInterval(0.2),
                fields: [
                    "content": ["type": "text", "text": "Independent Grok speech"],
                ]
            ),
            for: .grok
        )

        let snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.4)
        )
        XCTAssertEqual(snapshot.activity, .failed)
        XCTAssertEqual(snapshot.sourceAgent, .codex)
        XCTAssertEqual(snapshot.spokenText, "Independent Grok speech")
        XCTAssertEqual(snapshot.spokenAgent, .grok)
        XCTAssertNotNil(snapshot.spokenRevision)
    }

    func testGrokRealShapeChunksCompletionAndFailure() throws {
        let now = Date()
        let cases: [([Data], CodexActivity)] = [
            ([
                grokRecord(
                    updateType: "user_message_chunk",
                    at: now.addingTimeInterval(-2),
                    fields: ["content": ["type": "text", "text": "request"]]
                ),
                grokRecord(
                    updateType: "agent_thought_chunk",
                    at: now.addingTimeInterval(-1.5),
                    fields: ["content": ["type": "text", "text": "thinking"]]
                ),
                grokRecord(
                    updateType: "agent_message_chunk",
                    at: now.addingTimeInterval(-1),
                    fields: ["content": ["type": "text", "text": "answer"]]
                ),
            ], .thinking),
            ([
                grokRecord(
                    updateType: "turn_completed",
                    at: now.addingTimeInterval(-1),
                    fields: ["stop_reason": "end_turn"]
                ),
            ], .review),
            ([
                grokRecord(
                    updateType: "tool_call_update",
                    at: now.addingTimeInterval(-1),
                    fields: [
                        "toolCallId": "failed-call",
                        "status": "failed",
                        "rawOutput": [
                            "error": "tool_execution_failed",
                            "message": "failed",
                        ],
                    ]
                ),
            ], .failed),
        ]

        for item in cases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.monitor.setMonitoringMode(.grok)
            try fixture.write(joined(item.0), for: .grok)

            let snapshot = fixture.monitor.pollSynchronously(now: now)
            XCTAssertEqual(snapshot.activity, item.1)
            XCTAssertEqual(snapshot.sourceAgent, .grok)
        }
    }

    func testGrokToolKindsUseConservativeIndependentAdapter() throws {
        let cases: [(String, String, CodexToolActionHint)] = [
            ("read", "read_file", .read),
            ("search", "grep_repo", .read),
            ("search", "web_search", .search),
            ("fetch", "web_fetch", .search),
            ("write", "write_file", .write),
            ("edit", "edit_file", .write),
            ("apply", "apply_patch", .write),
            ("execute", "run_terminal_command", .execute),
        ]

        for (index, item) in cases.enumerated() {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.monitor.setMonitoringMode(.grok)
            let now = Date()
            try fixture.write(
                grokRecord(
                    updateType: "tool_call",
                    at: now.addingTimeInterval(-1),
                    fields: [
                        "toolCallId": "grok-\(index)",
                        "title": item.1,
                        "rawInput": ["command": "fixture"],
                        "_meta": [
                            "x.ai/tool": [
                                "version": 1,
                                "name": item.1,
                                "kind": item.0,
                                "namespace": "grok_build",
                                "label": item.1,
                                "read_only": item.2 == .read,
                            ],
                        ],
                    ]
                ),
                for: .grok
            )

            let snapshot = fixture.monitor.pollSynchronously(now: now)
            XCTAssertEqual(snapshot.activity, .tool, item.0)
            XCTAssertEqual(snapshot.toolActionHint, item.2, item.0)
            XCTAssertEqual(snapshot.sourceAgent, .grok, item.0)
        }
    }

    func testGrokToolCallUpdateUsesKindFromRealShape() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.grok)
        let now = Date()
        try fixture.write(
            joined([
                grokRecord(
                    updateType: "tool_call",
                    at: now.addingTimeInterval(-2),
                    fields: [
                        "toolCallId": "grok-read",
                        "title": "read_file",
                        "_meta": [
                            "x.ai/tool": [
                                "name": "read_file",
                                "kind": "read",
                            ],
                        ],
                    ]
                ),
                grokRecord(
                    updateType: "tool_call_update",
                    at: now.addingTimeInterval(-1),
                    fields: [
                        "toolCallId": "grok-read",
                        "kind": "read",
                        "title": "Read fixture",
                        "locations": [["path": "/tmp/fixture"]],
                        "rawInput": ["variant": "ReadFile", "target_file": "/tmp/fixture"],
                    ]
                ),
            ]),
            for: .grok
        )

        let snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .tool)
        XCTAssertEqual(snapshot.toolActionHint, .read)
        XCTAssertEqual(snapshot.sourceAgent, .grok)
    }

    func testZCodeRealShapeToolNamesAreClassifiedConservatively() throws {
        let cases: [(String, CodexToolActionHint)] = [
            ("Read", .read),
            ("WebFetch", .search),
            ("search", .read),
            ("Write", .write),
            ("Edit", .write),
            ("ApplyPatch", .write),
            ("Bash", .execute),
        ]

        for (index, item) in cases.enumerated() {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.monitor.setMonitoringMode(.zcode)
            let now = Date()
            try fixture.write(
                zcodeRecord(
                    startedAt: now.addingTimeInterval(-2),
                    completedAt: now.addingTimeInterval(-1),
                    finishReason: "tool-calls",
                    toolCalls: [[
                        "id": "call-\(index)",
                        "name": item.0,
                        "input": ["path": "/tmp/fixture"],
                    ]]
                ),
                for: .zcode
            )

            let snapshot = fixture.monitor.pollSynchronously(now: now)
            XCTAssertEqual(snapshot.activity, .tool, item.0)
            XCTAssertEqual(snapshot.toolActionHint, item.1, item.0)
            XCTAssertEqual(snapshot.sourceAgent, .zcode, item.0)
        }
    }

    func testZCodeStopAndErrorUseCompletedModelIORecord() throws {
        let now = Date()
        let cases: [(Data, CodexActivity)] = [
            (
                zcodeRecord(
                    startedAt: now.addingTimeInterval(-2),
                    completedAt: now.addingTimeInterval(-1),
                    finishReason: "stop"
                ),
                .review
            ),
            (
                zcodeRecord(
                    startedAt: now.addingTimeInterval(-2),
                    completedAt: now.addingTimeInterval(-1),
                    finishReason: "error",
                    error: "provider failed"
                ),
                .failed
            ),
        ]

        for item in cases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.monitor.setMonitoringMode(.zcode)
            try fixture.write(item.0, for: .zcode)

            let snapshot = fixture.monitor.pollSynchronously(now: now)
            XCTAssertEqual(snapshot.activity, item.1)
            XCTAssertEqual(snapshot.sourceAgent, .zcode)
        }
    }

    func testAllModeArbitratesAcrossSourcesByTimeAndPriority() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.all)
        let now = Date()
        try fixture.write(
            toolRecord(
                name: "read_mcp_resource",
                at: now.addingTimeInterval(-1),
                callID: "codex-read"
            ),
            for: .codex
        )
        try fixture.write(
            grokRecord(
                updateType: "tool_call_update",
                at: now.addingTimeInterval(-0.8),
                fields: ["toolCallId": "grok-failed", "status": "failed"]
            ),
            for: .grok
        )
        try fixture.write(
            zcodeRecord(
                startedAt: now.addingTimeInterval(-1),
                completedAt: now.addingTimeInterval(-0.5),
                finishReason: "stop"
            ),
            for: .zcode
        )

        let snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .failed)
        XCTAssertEqual(snapshot.sourceAgent, .grok)
    }

    func testAllModeLetsClearlyNewerSourceBeatOldPriority() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.all)
        let now = Date()
        try fixture.write(
            grokRecord(
                updateType: "tool_call_update",
                at: now.addingTimeInterval(-5),
                fields: ["toolCallId": "old-failure", "status": "failed"]
            ),
            for: .grok
        )
        try fixture.write(
            zcodeRecord(
                startedAt: now.addingTimeInterval(-1),
                completedAt: now,
                finishReason: "stop"
            ),
            for: .zcode
        )

        let snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(snapshot.activity, .review)
        XCTAssertEqual(snapshot.sourceAgent, .zcode)
    }

    func testArbitrationUsesOneNewestClusterInsteadOfNonTransitivePairs() throws {
        let now = Date()

        // These three records formed a cycle under the previous pairwise rule:
        // review(t0) > tool(t+2) > thinking(t+4) > review(t0).
        // A fixed newest-time cluster excludes t0, then deterministically lets
        // tool priority beat thinking inside the t+2...t+4 cluster.
        for iteration in 0..<24 {
            let fixture = try Fixture()
            defer { fixture.remove() }
            fixture.monitor.setMonitoringMode(.all)
            let start = now.addingTimeInterval(Double(iteration) * 0.001 - 5)

            try fixture.write(
                zcodeRecord(
                    startedAt: start.addingTimeInterval(-1),
                    completedAt: start,
                    finishReason: "stop"
                ),
                for: .zcode
            )
            try fixture.write(
                toolRecord(
                    name: "read_mcp_resource",
                    at: start.addingTimeInterval(2),
                    callID: "cluster-tool-\(iteration)"
                ),
                for: .codex
            )
            try fixture.write(
                grokRecord(
                    updateType: "agent_thought_chunk",
                    at: start.addingTimeInterval(4),
                    fields: ["content": ["type": "text", "text": "thinking"]]
                ),
                for: .grok
            )

            let snapshot = fixture.monitor.pollSynchronously(now: now)
            XCTAssertEqual(snapshot.activity, .tool, "iteration \(iteration)")
            XCTAssertEqual(snapshot.sourceAgent, .codex, "iteration \(iteration)")
        }
    }

    func testMonitoringGenerationChangesAndLabelsNewModeSnapshots() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        try fixture.write(
            record(type: "task_started", at: now.addingTimeInterval(-1)),
            for: .codex
        )
        try fixture.write(
            grokRecord(
                updateType: "turn_completed",
                at: now,
                fields: ["stop_reason": "end_turn"]
            ),
            for: .grok
        )

        let codexGeneration = fixture.monitor.setMonitoringMode(.codex)
        let codexSnapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(codexSnapshot.monitoringGeneration, codexGeneration)
        XCTAssertEqual(codexSnapshot.sourceAgent, .codex)

        let grokGeneration = fixture.monitor.setMonitoringMode(.grok)
        XCTAssertNotEqual(grokGeneration, codexGeneration)
        let grokSnapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(grokSnapshot.monitoringGeneration, grokGeneration)
        XCTAssertEqual(grokSnapshot.sourceAgent, .grok)
    }

    func testInitialPollBuildsToolBaselineAndOnlyFreshAppendEmitsNovelty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        try fixture.write(
            toolRecord(
                name: "read_file",
                at: now.addingTimeInterval(-2),
                callID: "historical-read"
            )
        )

        var snapshot = fixture.monitor.pollSynchronously(now: now)
        XCTAssertNil(snapshot.latestNovelTool)

        try fixture.append(
            toolRecord(
                name: "read-file",
                at: now.addingTimeInterval(-1),
                callID: "same-normalized-read"
            )
        )
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.1)
        )
        XCTAssertNil(snapshot.latestNovelTool)

        try fixture.append(
            toolRecord(
                name: "write_file",
                at: now,
                callID: "fresh-write"
            )
        )
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.2)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 1)
        XCTAssertEqual(snapshot.latestNovelTool?.agent, .codex)
        XCTAssertEqual(snapshot.latestNovelTool?.canonicalName, "write_file")
        XCTAssertEqual(snapshot.latestNovelTool?.sourcePath, fixture.rolloutURL.path)
        XCTAssertEqual(snapshot.latestNovelTool?.toolActionHint, .write)

        try fixture.append(
            toolRecord(
                name: "WRITE FILE",
                at: now.addingTimeInterval(0.1),
                callID: "duplicate-write"
            )
        )
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.3)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 1)
    }

    func testNewRolloutDiscoveredAfterEpochEmitsOnlyRecentNovelty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        _ = fixture.monitor.pollSynchronously(now: now)

        let liveRollout = fixture.rolloutURL
            .deletingLastPathComponent()
            .appendingPathComponent("rollout-live-after-baseline.jsonl")
        try toolRecord(
            name: "novel_flux_probe",
            at: now.addingTimeInterval(0.2),
            callID: "live-new-source"
        ).write(to: liveRollout)

        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 1)
        XCTAssertEqual(snapshot.latestNovelTool?.agent, .codex)
        XCTAssertEqual(snapshot.latestNovelTool?.canonicalName, "novel_flux_probe")
        XCTAssertEqual(snapshot.latestNovelTool?.sourcePath, liveRollout.path)

        let copiedHistory = fixture.rolloutURL
            .deletingLastPathComponent()
            .appendingPathComponent("rollout-copied-history.jsonl")
        try toolRecord(
            name: "historical_only_probe",
            at: now.addingTimeInterval(-60),
            callID: "old-new-source"
        ).write(to: copiedHistory)

        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(6)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 1)
        XCTAssertEqual(snapshot.latestNovelTool?.canonicalName, "novel_flux_probe")
    }

    func testToolIdentityIsScopedPerAgentAndSeenSurvivesModeSwitch() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.all)
        let now = Date()
        _ = fixture.monitor.pollSynchronously(now: now)

        try fixture.append(
            toolRecord(
                name: "read_file",
                at: now.addingTimeInterval(0.1),
                callID: "codex-read"
            ),
            for: .codex
        )
        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.2)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 1)
        XCTAssertEqual(snapshot.latestNovelTool?.agent, .codex)

        try fixture.append(
            grokRecord(
                updateType: "tool_call",
                at: now.addingTimeInterval(0.3),
                fields: [
                    "toolCallId": "grok-read",
                    "_meta": [
                        "x.ai/tool": [
                            "name": "read-file",
                            "kind": "read",
                        ],
                    ],
                ]
            ),
            for: .grok
        )
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.4)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 2)
        XCTAssertEqual(snapshot.latestNovelTool?.agent, .grok)
        XCTAssertEqual(snapshot.latestNovelTool?.canonicalName, "read_file")

        fixture.monitor.setMonitoringMode(.codex)
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.5)
        )
        XCTAssertNil(snapshot.latestNovelTool)

        try fixture.append(
            toolRecord(
                name: "READ.FILE",
                at: now.addingTimeInterval(0.6),
                callID: "codex-read-after-switch"
            ),
            for: .codex
        )
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.7)
        )
        XCTAssertNil(snapshot.latestNovelTool)
    }

    func testDuplicateToolAcrossRolloutsDoesNotEmitAgain() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        _ = fixture.monitor.pollSynchronously(now: now)

        try fixture.append(
            toolRecord(
                name: "inspect_asset",
                at: now.addingTimeInterval(0.1),
                callID: "rollout-one"
            )
        )
        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.2)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 1)

        let secondRollout = fixture.rolloutURL
            .deletingLastPathComponent()
            .appendingPathComponent("rollout-second.jsonl")
        try toolRecord(
            name: "inspect-asset",
            at: now.addingTimeInterval(0.3),
            callID: "rollout-two-baseline"
        ).write(to: secondRollout)
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(3)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 1)

        let handle = try FileHandle(forWritingTo: secondRollout)
        try handle.seekToEnd()
        try handle.write(
            contentsOf: toolRecord(
                name: "INSPECT ASSET",
                at: now.addingTimeInterval(3.1),
                callID: "rollout-two-append"
            )
        )
        try handle.close()
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(3.2)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 1)
    }

    func testNovelToolRemainsVisibleWhenAnotherAgentWinsArbitration() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.all)
        let now = Date()
        _ = fixture.monitor.pollSynchronously(now: now)

        try fixture.append(
            toolRecord(
                name: "inspect_schema",
                at: now.addingTimeInterval(0.2),
                callID: "codex-novel"
            ),
            for: .codex
        )
        try fixture.append(
            grokRecord(
                updateType: "tool_call_update",
                at: now.addingTimeInterval(0.3),
                fields: [
                    "toolCallId": "grok-failed",
                    "status": "failed",
                ]
            ),
            for: .grok
        )

        let snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.4)
        )
        XCTAssertEqual(snapshot.activity, .failed)
        XCTAssertEqual(snapshot.sourceAgent, .grok)
        XCTAssertEqual(snapshot.latestNovelTool?.agent, .codex)
        XCTAssertEqual(snapshot.latestNovelTool?.canonicalName, "inspect_schema")
    }

    func testNewestNoveltyWinsAcrossSourcesAndEqualTimestampsUseSequenceOrder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.all)
        let now = Date()
        _ = fixture.monitor.pollSynchronously(now: now)

        try fixture.append(
            toolRecord(
                name: "newer_codex_probe",
                at: now.addingTimeInterval(0.4),
                callID: "newer-codex"
            ),
            for: .codex
        )
        try fixture.append(
            grokRecord(
                updateType: "tool_call",
                at: now.addingTimeInterval(0.2),
                fields: [
                    "toolCallId": "older-grok",
                    "_meta": [
                        "x.ai/tool": [
                            "name": "older_grok_probe",
                            "kind": "execute",
                        ],
                    ],
                ]
            ),
            for: .grok
        )

        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.5)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 1)
        XCTAssertEqual(snapshot.latestNovelTool?.agent, .codex)
        XCTAssertEqual(snapshot.latestNovelTool?.canonicalName, "newer_codex_probe")

        let equalTimestamp = now.addingTimeInterval(0.6)
        try fixture.append(
            joined([
                toolRecord(
                    name: "equal_codex_probe_first",
                    at: equalTimestamp,
                    callID: "equal-codex-first"
                ),
                toolRecord(
                    name: "equal_codex_probe_second",
                    at: equalTimestamp,
                    callID: "equal-codex-second"
                ),
            ]),
            for: .codex
        )

        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.7)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 4)
        XCTAssertEqual(snapshot.latestNovelTool?.agent, .codex)
        XCTAssertEqual(
            snapshot.latestNovelTool?.canonicalName,
            "equal_codex_probe_second"
        )
    }

    func testActiveAgentSetChangeDeliversWhenWinnerIsUnchanged() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.all)
        let now = Date()
        try fixture.write(
            record(type: "task_failed", at: now.addingTimeInterval(-1)),
            for: .codex
        )

        let delivered = expectation(description: "active-agent set callbacks")
        delivered.expectedFulfillmentCount = 2
        let lock = NSLock()
        var snapshots: [CodexActivitySnapshot] = []
        fixture.monitor.onChange = { snapshot in
            lock.lock()
            snapshots.append(snapshot)
            lock.unlock()
            delivered.fulfill()
        }

        let first = fixture.monitor.pollSynchronously(now: now)
        XCTAssertEqual(first.activity, .failed)
        XCTAssertEqual(first.activeAgents, [])

        try fixture.append(
            grokRecord(
                updateType: "agent_thought_chunk",
                at: now.addingTimeInterval(-0.5),
                fields: ["content": ["type": "text", "text": "thinking"]]
            ),
            for: .grok
        )
        let second = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.1)
        )
        XCTAssertEqual(second.activity, .failed)
        XCTAssertEqual(second.sourceAgent, .codex)
        XCTAssertEqual(second.activeAgents, [.grok])

        wait(for: [delivered], timeout: 2)
        lock.lock()
        let captured = snapshots
        lock.unlock()
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured.map(\.activity), [.failed, .failed])
        XCTAssertEqual(captured.map(\.activeAgents), [[], [.grok]])
    }

    func testActiveAgentsDeduplicateCodexAndGrokButNeverIncludeZCodeCompletion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.all)
        let now = Date()
        _ = fixture.monitor.pollSynchronously(now: now)

        try fixture.append(
            record(
                type: "task_started",
                at: now.addingTimeInterval(0.1),
                fields: ["turn_id": "codex-live"]
            ),
            for: .codex
        )
        try fixture.append(
            grokRecord(
                updateType: "agent_thought_chunk",
                at: now.addingTimeInterval(0.2),
                fields: ["content": ["type": "text", "text": "thinking"]]
            ),
            for: .grok
        )
        try fixture.append(
            zcodeRecord(
                startedAt: now,
                completedAt: now.addingTimeInterval(0.3),
                finishReason: "tool-calls",
                toolCalls: [[
                    "id": "zcode-read",
                    "name": "Read",
                    "input": [:],
                ]]
            ),
            for: .zcode
        )

        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.4)
        )
        XCTAssertEqual(snapshot.activeAgents, [.codex, .grok])
        XCTAssertFalse(snapshot.activeAgents.contains(.zcode))

        try fixture.append(
            grokRecord(
                updateType: "turn_completed",
                at: now.addingTimeInterval(0.5),
                fields: ["stop_reason": "end_turn"]
            ),
            for: .grok
        )
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.6)
        )
        XCTAssertEqual(snapshot.activeAgents, [.codex])
    }

    func testWaitingOpenCallNeverReactivatesAgentAfterEvidenceTTL() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let now = Date()
        _ = fixture.monitor.pollSynchronously(now: now)

        try fixture.append(
            joined([
                record(
                    type: "task_started",
                    at: now.addingTimeInterval(0.1),
                    fields: ["turn_id": "waiting-turn"]
                ),
                record(
                    type: "function_call",
                    at: now.addingTimeInterval(0.2),
                    fields: [
                        "name": "request_user_input",
                        "call_id": "waiting-call",
                    ]
                ),
            ])
        )

        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.3)
        )
        XCTAssertEqual(snapshot.activity, .waiting)
        XCTAssertEqual(snapshot.activeAgents, [])

        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(21.2)
        )
        XCTAssertEqual(snapshot.activity, .waiting)
        XCTAssertEqual(snapshot.activeAgents, [])

        try fixture.append(
            record(
                type: "function_call_output",
                at: now.addingTimeInterval(21.3),
                fields: ["call_id": "waiting-call"]
            )
        )
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(21.4)
        )
        XCTAssertEqual(snapshot.activity, .thinking)
        XCTAssertEqual(snapshot.activeAgents, [.codex])
    }

    func testGrokTitleOnlyAndGenericNamesDoNotEmitNovelty() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.all)
        let now = Date()
        _ = fixture.monitor.pollSynchronously(now: now)

        try fixture.append(
            grokRecord(
                updateType: "tool_call",
                at: now.addingTimeInterval(0.1),
                fields: [
                    "toolCallId": "unstable-title",
                    "title": "read_file /tmp/private-fixture",
                ]
            ),
            for: .grok
        )
        try fixture.append(
            toolRecord(
                name: "tool",
                at: now.addingTimeInterval(0.2),
                callID: "generic-codex"
            ),
            for: .codex
        )

        let snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.3)
        )
        XCTAssertNil(snapshot.latestNovelTool)
    }

    func testZCodeMarksEveryToolInAMultiToolResponseAsSeen() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.monitor.setMonitoringMode(.zcode)
        let now = Date()
        _ = fixture.monitor.pollSynchronously(now: now)

        try fixture.append(
            zcodeRecord(
                startedAt: now,
                completedAt: now.addingTimeInterval(0.1),
                finishReason: "tool-calls",
                toolCalls: [
                    ["id": "z-read", "name": "Read", "input": [:]],
                    ["id": "z-write", "name": "Write", "input": [:]],
                ]
            ),
            for: .zcode
        )
        var snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.2)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 2)
        XCTAssertEqual(snapshot.latestNovelTool?.canonicalName, "write")
        XCTAssertEqual(snapshot.activeAgents, [])

        try fixture.append(
            zcodeRecord(
                startedAt: now.addingTimeInterval(0.3),
                completedAt: now.addingTimeInterval(0.4),
                finishReason: "tool-calls",
                toolCalls: [["id": "z-read-again", "name": "Read", "input": [:]]]
            ),
            for: .zcode
        )
        snapshot = fixture.monitor.pollSynchronously(
            now: now.addingTimeInterval(0.5)
        )
        XCTAssertEqual(snapshot.latestNovelTool?.sequence, 2)
        XCTAssertEqual(snapshot.activeAgents, [])
    }

    private final class Fixture {
        let homeURL: URL
        let rolloutURL: URL
        let grokURL: URL
        let zcodeURL: URL
        let monitor: CodexStateMonitor

        init() throws {
            homeURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexStateMonitorTests-\(UUID().uuidString)")
            let codexSessionURL = homeURL
                .appendingPathComponent(".codex/sessions/2026/07/30", isDirectory: true)
            let grokSessionURL = homeURL
                .appendingPathComponent(
                    ".grok/sessions/%2Ffixture/session-id",
                    isDirectory: true
                )
            let zcodeRolloutURL = homeURL
                .appendingPathComponent(".zcode/cli/rollout", isDirectory: true)
            for directory in [codexSessionURL, grokSessionURL, zcodeRolloutURL] {
                try FileManager.default.createDirectory(
                    at: directory,
                    withIntermediateDirectories: true
                )
            }
            rolloutURL = codexSessionURL.appendingPathComponent("rollout-fixture.jsonl")
            grokURL = grokSessionURL.appendingPathComponent("updates.jsonl")
            zcodeURL = zcodeRolloutURL.appendingPathComponent("model-io-fixture.jsonl")
            for fileURL in [rolloutURL, grokURL, zcodeURL] {
                try Data().write(to: fileURL)
            }
            monitor = CodexStateMonitor(homeDirectory: homeURL)
        }

        func write(
            _ data: Data,
            for agent: MonitoredAgent = .codex
        ) throws {
            try data.write(to: url(for: agent))
        }

        func append(
            _ data: Data,
            for agent: MonitoredAgent = .codex
        ) throws {
            let handle = try FileHandle(forWritingTo: url(for: agent))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }

        private func url(for agent: MonitoredAgent) -> URL {
            switch agent {
            case .codex:
                return rolloutURL
            case .grok:
                return grokURL
            case .zcode:
                return zcodeURL
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: homeURL)
        }
    }

    private func toolRecord(
        name: String,
        at date: Date,
        callID: String
    ) -> Data {
        record(
            type: "function_call",
            at: date,
            fields: [
                "name": name,
                "call_id": callID,
                "status": "completed",
            ]
        )
    }

    private func record(
        type: String,
        at date: Date,
        fields: [String: Any] = [:]
    ) -> Data {
        var payload = fields
        payload["type"] = type
        let envelope: [String: Any] = [
            "timestamp": Self.timestampFormatter.string(from: date),
            "type": "event_msg",
            "payload": payload,
        ]
        var data = try! JSONSerialization.data(withJSONObject: envelope)
        data.append(0x0A)
        return data
    }

    private func responseItemMessageRecord(
        text: String,
        phase: String,
        turnID: String,
        at date: Date
    ) -> Data {
        let envelope: [String: Any] = [
            "timestamp": Self.timestampFormatter.string(from: date),
            "type": "response_item",
            "payload": [
                "type": "message",
                "id": "response-item-fixture",
                "role": "assistant",
                "phase": phase,
                "content": [[
                    "type": "output_text",
                    "text": text,
                ]],
                "internal_chat_message_metadata_passthrough": [
                    "turn_id": turnID,
                ],
            ],
        ]
        var data = try! JSONSerialization.data(withJSONObject: envelope)
        data.append(0x0A)
        return data
    }

    private func grokRecord(
        updateType: String,
        at date: Date,
        fields: [String: Any] = [:]
    ) -> Data {
        var update = fields
        update["sessionUpdate"] = updateType
        let envelope: [String: Any] = [
            "timestamp": date.timeIntervalSince1970,
            "method": "session/update",
            "params": [
                "sessionId": "grok-fixture-session",
                "update": update,
            ],
        ]
        var data = try! JSONSerialization.data(withJSONObject: envelope)
        data.append(0x0A)
        return data
    }

    private func zcodeRecord(
        startedAt: Date,
        completedAt: Date,
        finishReason: String,
        turnID: String = "zcode-fixture-turn",
        text: String = "",
        toolCalls: [[String: Any]] = [],
        error: String? = nil
    ) -> Data {
        var response: [String: Any] = [
            "finishReason": finishReason,
            "modelId": "glm-5.2",
            "text": text,
            "toolCalls": toolCalls,
            "usage": [
                "inputTokens": 10,
                "outputTokens": 5,
                "totalTokens": 15,
            ],
        ]
        var envelope: [String: Any] = [
            "type": "model_io",
            "requestId": "zcode-fixture-request",
            "turnId": turnID,
            "startedAt": Self.timestampFormatter.string(from: startedAt),
            "completedAt": Self.timestampFormatter.string(from: completedAt),
            "durationMs": Int(completedAt.timeIntervalSince(startedAt) * 1_000),
            "model": "glm-5.2",
            "request": [
                "messageCount": 1,
                "toolNames": ["Read", "Write", "Bash"],
            ],
            "response": response,
        ]
        if let error {
            envelope["error"] = error
            response["error"] = error
            envelope["response"] = response
        }
        var data = try! JSONSerialization.data(withJSONObject: envelope)
        data.append(0x0A)
        return data
    }

    private func joined(_ chunks: [Data]) -> Data {
        chunks.reduce(into: Data()) { $0.append($1) }
    }

    private func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
