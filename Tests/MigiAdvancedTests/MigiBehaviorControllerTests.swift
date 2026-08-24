import XCTest
@testable import MigiAdvanced

final class MigiBehaviorControllerTests: XCTestCase {
    func testHalfSizeMigrationKeepsTheOldCenterAndBottomEdge() {
        let suiteName = "MigiAdvancedTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated defaults.")
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(230, forKey: "petWidth")
        defaults.set(270, forKey: "petHeight")
        defaults.set(2, forKey: "petSizePreferenceVersion")
        defaults.set(1_000, forKey: "anchorOriginX")
        defaults.set(80, forKey: "anchorOriginY")

        let size = MigiOverlayController.initialSize(defaults: defaults)

        XCTAssertEqual(size.width, 115)
        XCTAssertEqual(size.height, 135)
        XCTAssertEqual(defaults.double(forKey: "anchorOriginX"), 1_057.5)
        XCTAssertEqual(defaults.double(forKey: "anchorOriginY"), 80)
        XCTAssertEqual(defaults.integer(forKey: "petSizePreferenceVersion"), 3)
    }

    func testHalfSizeIsAValidPersistedSize() {
        let suiteName = "MigiAdvancedTests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            return XCTFail("Unable to create isolated defaults.")
        }
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        defaults.set(115, forKey: "petWidth")
        defaults.set(135, forKey: "petHeight")
        defaults.set(3, forKey: "petSizePreferenceVersion")

        let size = MigiOverlayController.initialSize(defaults: defaults)

        XCTAssertEqual(size.width, 115)
        XCTAssertEqual(size.height, 135)
    }

    func testSingleInstanceGateBlocksASecondOwnerAndRecovers() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MigiAdvancedTests-\(UUID().uuidString)")
        let lockURL = directory.appendingPathComponent("instance.lock")
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        var firstGate: MigiSingleInstanceGate?
        switch MigiSingleInstanceGate.acquire(at: lockURL) {
        case .acquired(let gate):
            firstGate = gate
        case .alreadyRunning:
            return XCTFail("The first lock attempt was unexpectedly blocked.")
        case .failed(let message):
            return XCTFail(message)
        }
        XCTAssertNotNil(firstGate)

        switch MigiSingleInstanceGate.acquire(at: lockURL) {
        case .alreadyRunning:
            break
        case .acquired:
            XCTFail("A second owner acquired the same instance lock.")
        case .failed(let message):
            XCTFail(message)
        }

        firstGate = nil

        switch MigiSingleInstanceGate.acquire(at: lockURL) {
        case .acquired:
            break
        case .alreadyRunning:
            XCTFail("The lock remained held after its owner was released.")
        case .failed(let message):
            XCTFail(message)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: lockURL.path))
    }

    func testWorkStateHoldsForTwentySecondsAfterIdleSignal() {
        let controller = MigiBehaviorController(seed: 7)
        controller.ingest(snapshot(.tool))
        XCTAssertEqual(
            controller.update(time: 100, deltaTime: 0, availableWidth: 500).activity,
            .tool
        )

        controller.ingest(snapshot(.idle))
        XCTAssertEqual(
            controller.update(time: 119.9, deltaTime: 0.1, availableWidth: 500).activity,
            .tool
        )
        XCTAssertEqual(
            controller.update(time: 120.1, deltaTime: 0.2, availableWidth: 500).activity,
            .idle
        )
    }

    func testWaitingImmediatelyPreemptsWorkHold() {
        let controller = MigiBehaviorController(seed: 17)
        controller.ingest(snapshot(.tool))
        _ = controller.update(time: 100, deltaTime: 0, availableWidth: 500)

        controller.ingest(snapshot(.waiting))
        let frame = controller.update(time: 101, deltaTime: 0.1, availableWidth: 500)
        XCTAssertEqual(frame.activity, .waiting)
        XCTAssertEqual(frame.prop, .phone)
    }

    func testThinkingIsAnUnmistakableLaptopWorkPose() {
        let controller = MigiBehaviorController(seed: 23)
        controller.ingest(snapshot(.thinking))
        let frame = controller.update(time: 200, deltaTime: 0, availableWidth: 500)
        XCTAssertEqual(frame.microAction, .type)
        XCTAssertEqual(frame.prop, .laptop)
    }

    func testToolActionHintsUseStudyAndFineMotorWithoutRoutineBladeUse() {
        let cases: [(CodexToolActionHint, MigiMicroAction, MigiProp)] = [
            (.read, .read, .book),
            (.write, .fineMotor, .none),
            (.none, .fineMotor, .none)
        ]

        for (index, item) in cases.enumerated() {
            let controller = MigiBehaviorController(seed: UInt64(index + 31))
            controller.ingest(snapshot(.tool, toolActionHint: item.0))
            let frame = controller.update(
                time: 100,
                deltaTime: 0,
                availableWidth: 500
            )
            XCTAssertEqual(frame.microAction, item.1)
            XCTAssertEqual(frame.prop, item.2)
        }
    }

    func testReadAndWriteGesturesRemainLatchedAfterToolOutput() {
        let cases: [
            (
                hint: CodexToolActionHint,
                action: MigiMicroAction,
                prop: MigiProp,
                heldTime: TimeInterval
            )
        ] = [
            (.read, .read, .book, 1.8),
            (.write, .fineMotor, .none, 2.4)
        ]

        for (index, item) in cases.enumerated() {
            let controller = MigiBehaviorController(seed: UInt64(index + 41))
            controller.ingest(snapshot(.tool, toolActionHint: item.hint))
            XCTAssertEqual(
                controller.update(
                    time: 100,
                    deltaTime: 0,
                    availableWidth: 500
                ).microAction,
                item.action
            )

            controller.ingest(snapshot(.thinking))
            let outputTime = 100.25
            let outputFrame = controller.update(
                time: outputTime,
                deltaTime: 0.25,
                availableWidth: 500
            )
            XCTAssertEqual(outputFrame.activity, .thinking)
            XCTAssertEqual(outputFrame.microAction, item.action)

            let heldFrame = controller.update(
                time: outputTime + item.heldTime - 0.01,
                deltaTime: 0.1,
                availableWidth: 500
            )
            XCTAssertEqual(heldFrame.activity, .thinking)
            XCTAssertEqual(heldFrame.microAction, item.action)
            XCTAssertEqual(heldFrame.prop, item.prop)

            let releasedFrame = controller.update(
                time: outputTime + item.heldTime + 0.01,
                deltaTime: 0.02,
                availableWidth: 500
            )
            XCTAssertEqual(releasedFrame.microAction, .type)
            XCTAssertEqual(releasedFrame.prop, .laptop)
        }
    }

    func testWaitingAndRoutineFailureImmediatelyPreemptToolGestureLatch() {
        let waitingController = MigiBehaviorController(seed: 51)
        waitingController.ingest(snapshot(.tool, toolActionHint: .write))
        _ = waitingController.update(time: 10, deltaTime: 0, availableWidth: 500)
        waitingController.ingest(snapshot(.waiting))
        let waitingFrame = waitingController.update(
            time: 10.1,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertEqual(waitingFrame.activity, .waiting)
        XCTAssertEqual(waitingFrame.microAction, .checkPhone)
        XCTAssertEqual(waitingFrame.prop, .phone)

        let failedController = MigiBehaviorController(seed: 52)
        failedController.ingest(snapshot(.tool, toolActionHint: .read))
        _ = failedController.update(time: 20, deltaTime: 0, availableWidth: 500)
        failedController.ingest(snapshot(.failed))
        let failedFrame = failedController.update(
            time: 20.1,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertEqual(failedFrame.activity, .failed)
        XCTAssertEqual(failedFrame.microAction, .calmDiagnosis)
        XCTAssertEqual(failedFrame.prop, .none)
        XCTAssertEqual(failedFrame.failureDisposition, .routine)
    }

    func testCredibleThreatShieldsBeforeUsingTheBlade() {
        let controller = MigiBehaviorController(seed: 53)
        controller.ingest(
            snapshot(
                .failed,
                failureDisposition: .credibleThreat
            )
        )

        let shield = controller.update(
            time: 20,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertEqual(shield.microAction, .protectiveShield)
        XCTAssertEqual(shield.failureDisposition, .credibleThreat)

        let blade = controller.update(
            time: 20.91,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertEqual(blade.microAction, .sharpenTip)
        XCTAssertEqual(blade.failureDisposition, .credibleThreat)
    }

    func testShieldDurationScalesWithRelationshipStage() {
        func shieldState(
            at elapsed: TimeInterval,
            profile: MigiRelationshipProfile
        ) -> MigiMicroAction {
            let controller = MigiBehaviorController(seed: 53)
            controller.ingest(
                snapshot(
                    .failed,
                    failureDisposition: .credibleThreat,
                    relationshipProfile: profile
                )
            )
            _ = controller.update(time: 20, deltaTime: 0, availableWidth: 500)
            return controller.update(
                time: 20 + elapsed,
                deltaTime: elapsed,
                availableWidth: 500
            ).microAction
        }

        let cautious = MigiRelationshipProfile(
            cooperationDuration: 0,
            familiarToolCount: 0
        )
        let cooperative = MigiRelationshipProfile(
            cooperationDuration: 90 * 60,
            familiarToolCount: 6
        )
        let protective = MigiRelationshipProfile(
            cooperationDuration: 13 * 3600,
            familiarToolCount: 12
        )

        // 警戒期 0.7s:0.75 已进入刃化
        XCTAssertEqual(shieldState(at: 0.75, profile: cautious), .sharpenTip)
        // 协作期 0.9s:0.85 仍是盾
        XCTAssertEqual(shieldState(at: 0.85, profile: cooperative), .protectiveShield)
        // 保护期 1.2s:1.10 仍是盾,1.25 进入刃化
        XCTAssertEqual(shieldState(at: 1.10, profile: protective), .protectiveShield)
        XCTAssertEqual(shieldState(at: 1.25, profile: protective), .sharpenTip)
    }

    func testEstablishedCooperationAddsARestrainedRecoveryCareGesture() {
        let profile = MigiRelationshipProfile(
            cooperationDuration: 45 * 60,
            familiarToolCount: 5
        )
        let controller = MigiBehaviorController(seed: 54)
        controller.ingest(
            snapshot(
                .failed,
                relationshipProfile: profile
            )
        )
        let diagnostic = controller.update(
            time: 10,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertEqual(diagnostic.microAction, .calmDiagnosis)
        XCTAssertEqual(diagnostic.relationshipStage, .cooperative)

        controller.ingest(
            snapshot(
                .thinking,
                relationshipProfile: profile
            )
        )
        let care = controller.update(
            time: 10.1,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertEqual(care.microAction, .recoveryCare)
        XCTAssertEqual(care.prop, .none)
        XCTAssertEqual(care.relationshipStage, .cooperative)
    }

    func testCautiousStageDiagnosesWithoutInventingAffection() {
        let controller = MigiBehaviorController(seed: 55)
        controller.ingest(snapshot(.failed))
        _ = controller.update(time: 10, deltaTime: 0, availableWidth: 500)
        controller.ingest(snapshot(.thinking))
        let resumed = controller.update(
            time: 10.1,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertEqual(resumed.microAction, .type)
        XCTAssertEqual(resumed.relationshipStage, .cautious)
    }

    func testExtendedIdleEntersPersistentLowEnergyDeepSleep() {
        let controller = MigiBehaviorController(
            seed: 61,
            deepSleepDelay: 5,
            wakeDuration: 1.6
        )
        controller.ingest(snapshot(.idle))

        let awakeFrame = controller.update(
            time: 100,
            deltaTime: 0,
            availableWidth: 620
        )
        XCTAssertFalse(awakeFrame.isDeepSleeping)
        XCTAssertEqual(awakeFrame.wakePhase, .awake)
        XCTAssertEqual(awakeFrame.wakeProgress, 1)
        XCTAssertFalse(awakeFrame.suppressesPointerGaze)
        XCTAssertEqual(awakeFrame.clipPlaybackRate, 1)

        let almostAsleepFrame = controller.update(
            time: 104.99,
            deltaTime: 0.25,
            availableWidth: 620
        )
        XCTAssertFalse(almostAsleepFrame.isDeepSleeping)

        var sleepingFrame = controller.update(
            time: 105,
            deltaTime: 0.01,
            availableWidth: 620
        )
        let sleepingX = sleepingFrame.worldOffset.x
        XCTAssertTrue(sleepingFrame.isDeepSleeping)
        XCTAssertEqual(sleepingFrame.wakePhase, .deepSleep)
        XCTAssertEqual(sleepingFrame.wakeProgress, 0)
        XCTAssertTrue(sleepingFrame.suppressesPointerGaze)
        XCTAssertEqual(sleepingFrame.clipPlaybackRate, 1)
        XCTAssertEqual(sleepingFrame.activity, .idle)
        XCTAssertEqual(sleepingFrame.microAction, .dormant)
        XCTAssertEqual(sleepingFrame.prop, .none)
        XCTAssertFalse(sleepingFrame.isMoving)

        for step in 1...24 {
            sleepingFrame = controller.update(
                time: 105 + Double(step) * 0.25,
                deltaTime: 0.25,
                availableWidth: 620
            )
            XCTAssertTrue(sleepingFrame.isDeepSleeping)
            XCTAssertEqual(sleepingFrame.microAction, .dormant)
            XCTAssertFalse(sleepingFrame.isMoving)
            XCTAssertEqual(sleepingFrame.worldOffset.x, sleepingX, accuracy: 0.001)
        }
        XCTAssertLessThan(sleepingFrame.bodyEnergy, 0.04)
        XCTAssertLessThan(sleepingFrame.focus, 0.06)
    }

    func testThinkingRespectsMinimumDeepSleepWindowBeforeWaking() {
        let controller = MigiBehaviorController(
            seed: 66,
            deepSleepDelay: 1,
            minimumDeepSleepDuration: 5,
            dreamDisturbanceDuration: 1.2,
            wakeDuration: 1.6
        )
        controller.ingest(snapshot(.idle))
        _ = controller.update(time: 10, deltaTime: 0, availableWidth: 500)
        XCTAssertTrue(
            controller.update(
                time: 11,
                deltaTime: 0.25,
                availableWidth: 500
            ).isDeepSleeping
        )

        controller.ingest(snapshot(.thinking))
        let refractory = controller.update(
            time: 15.99,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(refractory.activity, .thinking)
        XCTAssertEqual(refractory.wakePhase, .deepSleep)
        XCTAssertEqual(refractory.microAction, .dormant)

        let waking = controller.update(
            time: 16,
            deltaTime: 0.01,
            availableWidth: 500
        )
        XCTAssertEqual(waking.wakePhase, .dreamDisturbance)
        XCTAssertEqual(waking.microAction, .dormant)
    }

    func testDeepSleepWakeUsesExactDreamLookAndAwakeBoundaries() {
        let controller = MigiBehaviorController(
            seed: 71,
            deepSleepDelay: 1,
            minimumDeepSleepDuration: 0,
            dreamDisturbanceDuration: 1.2,
            wakeDuration: 1.6
        )
        controller.ingest(snapshot(.idle))
        _ = controller.update(time: 10, deltaTime: 0, availableWidth: 500)
        XCTAssertTrue(
            controller.update(
                time: 11,
                deltaTime: 0.25,
                availableWidth: 500
            ).isDeepSleeping
        )

        controller.ingest(snapshot(.thinking))
        let firstWakeFrame = controller.update(
            time: 12,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertFalse(firstWakeFrame.isDeepSleeping)
        XCTAssertEqual(firstWakeFrame.wakePhase, .dreamDisturbance)
        XCTAssertEqual(firstWakeFrame.wakeProgress, 0, accuracy: 0.0001)
        XCTAssertEqual(firstWakeFrame.activity, .thinking)
        XCTAssertEqual(firstWakeFrame.microAction, .dormant)
        XCTAssertEqual(firstWakeFrame.prop, .none)
        XCTAssertTrue(firstWakeFrame.suppressesPointerGaze)
        XCTAssertEqual(firstWakeFrame.clipPlaybackRate, 1.25)
        XCTAssertEqual(firstWakeFrame.bodyEnergy, 0.08, accuracy: 0.001)
        XCTAssertFalse(firstWakeFrame.isMoving)
        let anchoredX = firstWakeFrame.worldOffset.x

        let finalDreamFrame = controller.update(
            time: 13.19,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(finalDreamFrame.wakePhase, .dreamDisturbance)
        XCTAssertEqual(finalDreamFrame.microAction, .dormant)
        XCTAssertGreaterThan(finalDreamFrame.bodyEnergy, 0.198)
        XCTAssertLessThanOrEqual(finalDreamFrame.bodyEnergy, 0.20)
        XCTAssertEqual(finalDreamFrame.worldOffset.x, anchoredX, accuracy: 0.001)

        let firstLookFrame = controller.update(
            time: 13.2,
            deltaTime: 0.01,
            availableWidth: 500
        )
        XCTAssertEqual(firstLookFrame.wakePhase, .lookAround)
        XCTAssertEqual(
            firstLookFrame.wakeProgress,
            CGFloat(1.2 / 2.8),
            accuracy: 0.0001
        )
        XCTAssertEqual(firstLookFrame.microAction, .lookAround)
        XCTAssertTrue(firstLookFrame.suppressesPointerGaze)
        XCTAssertEqual(firstLookFrame.clipPlaybackRate, 1)
        XCTAssertEqual(firstLookFrame.bodyEnergy, 0.20, accuracy: 0.001)
        XCTAssertEqual(firstLookFrame.worldOffset.x, anchoredX, accuracy: 0.001)

        let finalLookFrame = controller.update(
            time: 14.79,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(finalLookFrame.wakePhase, .lookAround)
        XCTAssertEqual(finalLookFrame.microAction, .lookAround)
        XCTAssertGreaterThan(finalLookFrame.bodyEnergy, firstLookFrame.bodyEnergy)
        XCTAssertEqual(finalLookFrame.worldOffset.x, anchoredX, accuracy: 0.001)

        let workingFrame = controller.update(
            time: 14.8,
            deltaTime: 0.01,
            availableWidth: 500
        )
        XCTAssertEqual(workingFrame.wakePhase, .awake)
        XCTAssertEqual(workingFrame.wakeProgress, 1)
        XCTAssertEqual(workingFrame.activity, .thinking)
        XCTAssertEqual(workingFrame.microAction, .type)
        XCTAssertEqual(workingFrame.prop, .laptop)
    }

    func testWaitingAndReviewCannotWakeDeepSleep() {
        for (index, activity) in [CodexActivity.waiting, .review].enumerated() {
            let controller = MigiBehaviorController(
                seed: UInt64(index + 81),
                deepSleepDelay: 1,
                minimumDeepSleepDuration: 20,
                wakeDuration: 1.6
            )
            controller.ingest(snapshot(.idle))
            _ = controller.update(time: 20, deltaTime: 0, availableWidth: 500)
            _ = controller.update(time: 21, deltaTime: 0.25, availableWidth: 500)

            controller.ingest(snapshot(activity))
            let frame = controller.update(
                time: 41.1,
                deltaTime: 0.1,
                availableWidth: 500
            )
            XCTAssertTrue(frame.isDeepSleeping)
            XCTAssertEqual(frame.activity, activity)
            XCTAssertEqual(frame.microAction, .dormant)
            XCTAssertEqual(frame.prop, .none)
            XCTAssertFalse(frame.isMoving)
        }
    }

    func testEvenCredibleThreatCannotBreakCompleteSleepWindow() {
        let controller = MigiBehaviorController(
            seed: 83,
            deepSleepDelay: 1,
            minimumDeepSleepDuration: 20
        )
        controller.ingest(snapshot(.idle))
        _ = controller.update(time: 20, deltaTime: 0, availableWidth: 500)
        _ = controller.update(time: 21, deltaTime: 0.25, availableWidth: 500)

        controller.ingest(
            snapshot(
                .failed,
                failureDisposition: .credibleThreat
            )
        )
        let frame = controller.update(
            time: 21.1,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertTrue(frame.isDeepSleeping)
        XCTAssertEqual(frame.activity, .failed)
        XCTAssertEqual(frame.microAction, .dormant)
        XCTAssertEqual(frame.prop, .none)
        XCTAssertTrue(frame.suppressesPointerGaze)
    }

    func testWaitingPreemptsEveryActiveWakePhase() {
        for (phaseIndex, phase) in [
            MigiWakePhase.dreamDisturbance,
            .lookAround
        ].enumerated() {
            let controller = MigiBehaviorController(
                seed: UInt64(90 + phaseIndex),
                dreamDisturbanceDuration: 1.2,
                wakeDuration: 1.6
            )
            controller.force(snapshot(.thinking))
            controller.forceWakePhaseForQA(phase)
            _ = controller.update(time: 100, deltaTime: 0, availableWidth: 500)

            controller.ingest(snapshot(.waiting))
            let frame = controller.update(
                time: 100.1,
                deltaTime: 0.1,
                availableWidth: 500
            )
            XCTAssertEqual(frame.wakePhase, .awake)
            XCTAssertEqual(frame.activity, .waiting)
            XCTAssertFalse(frame.suppressesPointerGaze)
            XCTAssertEqual(frame.microAction, .checkPhone)
            XCTAssertEqual(frame.prop, .phone)
        }
    }

    func testFailureDoesNotSkipAnActiveWakePhase() {
        for (index, phase) in [
            MigiWakePhase.dreamDisturbance,
            .lookAround
        ].enumerated() {
            let controller = MigiBehaviorController(
                seed: UInt64(94 + index),
                dreamDisturbanceDuration: 1.2,
                wakeDuration: 1.6
            )
            controller.force(snapshot(.thinking))
            controller.forceWakePhaseForQA(phase)
            _ = controller.update(time: 100, deltaTime: 0, availableWidth: 500)

            controller.ingest(snapshot(.failed))
            let frame = controller.update(
                time: 100.1,
                deltaTime: 0.1,
                availableWidth: 500
            )
            XCTAssertEqual(frame.wakePhase, phase)
            XCTAssertEqual(frame.activity, .failed)
            XCTAssertTrue(frame.suppressesPointerGaze)
            XCTAssertEqual(
                frame.microAction,
                phase == .dreamDisturbance ? .dormant : .lookAround
            )
        }
    }

    func testRepeatedSnapshotsAndWorkTypeChangesDoNotRestartWake() {
        let controller = MigiBehaviorController(
            seed: 101,
            deepSleepDelay: 1,
            minimumDeepSleepDuration: 0,
            dreamDisturbanceDuration: 1.2,
            wakeDuration: 1.6
        )
        controller.ingest(snapshot(.idle))
        _ = controller.update(time: 10, deltaTime: 0, availableWidth: 500)
        XCTAssertEqual(
            controller.update(
                time: 11,
                deltaTime: 0.25,
                availableWidth: 500
            ).wakePhase,
            .deepSleep
        )

        controller.ingest(snapshot(.thinking))
        XCTAssertEqual(
            controller.update(
                time: 12,
                deltaTime: 0,
                availableWidth: 500
            ).wakePhase,
            .dreamDisturbance
        )
        controller.ingest(snapshot(.thinking))
        XCTAssertEqual(
            controller.update(
                time: 12.8,
                deltaTime: 0.25,
                availableWidth: 500
            ).wakePhase,
            .dreamDisturbance
        )
        controller.ingest(snapshot(.review))
        XCTAssertEqual(
            controller.update(
                time: 13.2,
                deltaTime: 0.25,
                availableWidth: 500
            ).wakePhase,
            .lookAround
        )
        controller.ingest(snapshot(.tool))
        XCTAssertEqual(
            controller.update(
                time: 13.4,
                deltaTime: 0.2,
                availableWidth: 500
            ).wakePhase,
            .lookAround
        )

        let awake = controller.update(
            time: 14.8,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(awake.wakePhase, .awake)
        XCTAssertEqual(awake.activity, .tool)
        XCTAssertEqual(awake.microAction, .fineMotor)
        XCTAssertEqual(awake.prop, .none)
    }

    func testReadAndWriteGestureHoldsBeginAfterTheCompleteWakeSequence() {
        let cases: [
            (
                hint: CodexToolActionHint,
                action: MigiMicroAction,
                holdDuration: TimeInterval
            )
        ] = [
            (.read, .read, 1.8),
            (.write, .fineMotor, 2.4)
        ]

        for (index, item) in cases.enumerated() {
            let controller = MigiBehaviorController(
                seed: UInt64(111 + index),
                deepSleepDelay: 1,
                minimumDeepSleepDuration: 0,
                dreamDisturbanceDuration: 1.2,
                wakeDuration: 1.6
            )
            controller.ingest(snapshot(.idle))
            _ = controller.update(time: 10, deltaTime: 0, availableWidth: 500)
            _ = controller.update(time: 11, deltaTime: 0.25, availableWidth: 500)

            controller.ingest(snapshot(.tool, toolActionHint: item.hint))
            XCTAssertEqual(
                controller.update(
                    time: 12,
                    deltaTime: 0,
                    availableWidth: 500
                ).wakePhase,
                .dreamDisturbance
            )
            controller.ingest(snapshot(.thinking))
            _ = controller.update(time: 12.1, deltaTime: 0.1, availableWidth: 500)

            let firstAwake = controller.update(
                time: 14.8,
                deltaTime: 0.25,
                availableWidth: 500
            )
            XCTAssertEqual(firstAwake.wakePhase, .awake)
            XCTAssertEqual(firstAwake.microAction, item.action)
            XCTAssertEqual(
                firstAwake.prop,
                item.hint == .read ? .book : .none
            )

            XCTAssertEqual(
                controller.update(
                    time: 14.8
                        + MigiAnimationTiming.wakeHandoffDuration
                        + item.holdDuration
                        - 0.01,
                    deltaTime: 0.25,
                    availableWidth: 500
                ).microAction,
                item.action
            )
            let released = controller.update(
                time: 14.8
                    + MigiAnimationTiming.wakeHandoffDuration
                    + item.holdDuration
                    + 0.01,
                deltaTime: 0.02,
                availableWidth: 500
            )
            XCTAssertEqual(released.microAction, .type)
            XCTAssertEqual(released.prop, .laptop)
        }
    }

    func testForcedWakePhaseUsesTheNextUpdateClockAsItsAnchor() {
        let controller = MigiBehaviorController(
            seed: 121,
            dreamDisturbanceDuration: 1.2,
            wakeDuration: 1.6
        )
        controller.force(snapshot(.thinking))
        controller.forceWakePhaseForQA(.dreamDisturbance)

        let dream = controller.update(
            time: 1_000,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertEqual(dream.wakePhase, .dreamDisturbance)
        XCTAssertEqual(dream.wakeProgress, 0)

        let look = controller.update(
            time: 1_001.2,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(look.wakePhase, .lookAround)
        XCTAssertEqual(look.wakeProgress, CGFloat(1.2 / 2.8), accuracy: 0.0001)

        controller.forceWakePhaseForQA(.lookAround)
        let forcedLook = controller.update(
            time: 2_000,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertEqual(forcedLook.wakePhase, .lookAround)
        XCTAssertEqual(
            forcedLook.wakeProgress,
            CGFloat(1.2 / 2.8),
            accuracy: 0.0001
        )

        controller.force(snapshot(.idle))
        controller.forceWakePhaseForQA(.deepSleep)
        let sleep = controller.update(
            time: 3_000,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertEqual(sleep.wakePhase, .deepSleep)
        XCTAssertTrue(sleep.isDeepSleeping)
    }

    func testRightEdgeBirthCanExplicitlyFaceIntoTheScreen() {
        let controller = MigiBehaviorController(seed: 1, initialFacing: -1)
        controller.ingest(snapshot(.idle))
        let frame = controller.update(time: 10, deltaTime: 0, availableWidth: 500)
        XCTAssertEqual(frame.facing, -1)
    }

    func testCoreCodexActivitiesRemainSemanticallyDistinct() {
        let cases: [(CodexActivity, MigiMicroAction, MigiProp)] = [
            (.thinking, .type, .laptop),
            (.tool, .fineMotor, .none),
            (.waiting, .checkPhone, .phone),
            (.review, .signalSampling, .none),
            (.failed, .calmDiagnosis, .none)
        ]

        let sampleTimes: [TimeInterval] = [200, 208, 202, 204, 206]
        for (index, item) in cases.enumerated() {
            let controller = MigiBehaviorController(seed: UInt64(index + 1))
            controller.ingest(snapshot(item.0))
            let frame = controller.update(
                time: sampleTimes[index],
                deltaTime: 0,
                availableWidth: 500
            )
            XCTAssertEqual(frame.microAction, item.1)
            XCTAssertEqual(frame.prop, item.2)
        }
    }

    func testDetachedScoutIsLowFrequencyShortAndAlwaysReturns() {
        let quietController = MigiBehaviorController(
            seed: 42,
            deepSleepDelay: 1_000_000
        )
        quietController.ingest(snapshot(.idle))
        for step in 0..<400 {
            let frame = quietController.update(
                time: Double(step) * 0.1,
                deltaTime: 0.1,
                availableWidth: 620
            )
            XCTAssertFalse(frame.isMoving)
            XCTAssertEqual(frame.scoutPhase, .anchored)
        }

        let controller = MigiBehaviorController(
            seed: 42,
            deepSleepDelay: 1_000_000,
            scoutInterval: 1...1,
            scoutDetachedDuration: 2...2
        )
        controller.ingest(snapshot(.idle))
        var facings = Set<Int>()
        var minimumX = CGFloat.greatestFiniteMagnitude
        var maximumX = -CGFloat.greatestFiniteMagnitude
        var scoutStartedAt: TimeInterval?
        var completedScouts = 0
        var sawReturnClip = false

        for step in 0..<1_200 {
            let time = Double(step) * 0.1
            let frame = controller.update(
                time: time,
                deltaTime: 0.1,
                availableWidth: 620
            )
            facings.insert(frame.facing < 0 ? -1 : 1)
            minimumX = min(minimumX, frame.worldOffset.x)
            maximumX = max(maximumX, frame.worldOffset.x)
            if frame.isMoving, scoutStartedAt == nil {
                scoutStartedAt = time
            }
            if frame.scoutPhase == .returning {
                sawReturnClip = true
                XCTAssertEqual(frame.microAction, .detachedScoutReturn)
            }
            if !frame.isMoving, let startedAt = scoutStartedAt {
                XCTAssertLessThan(time - startedAt, 8)
                XCTAssertEqual(frame.worldOffset.x, 0, accuracy: 0.001)
                scoutStartedAt = nil
                completedScouts += 1
            }
        }

        XCTAssertEqual(facings, Set([-1, 1]))
        XCTAssertLessThan(minimumX, -5)
        XCTAssertGreaterThan(maximumX, 5)
        XCTAssertTrue(sawReturnClip)
        XCTAssertGreaterThanOrEqual(completedScouts, 2)
    }

    func testWorkForcesDetachedScoutBackToTheHandAnchor() {
        let controller = MigiBehaviorController(
            seed: 44,
            deepSleepDelay: 1_000_000,
            scoutInterval: 0...0,
            scoutDetachedDuration: 5...5
        )
        controller.ingest(snapshot(.idle))

        var time: TimeInterval = 0
        var movingFrame: MigiBehaviorFrame?
        for _ in 0..<200 where movingFrame == nil {
            let frame = controller.update(
                time: time,
                deltaTime: 0.25,
                availableWidth: 620
            )
            if frame.isMoving, abs(frame.worldOffset.x) > 1 {
                movingFrame = frame
            }
            time += 0.25
        }
        guard let movingFrame else {
            return XCTFail("Idle patrol never began.")
        }

        controller.ingest(snapshot(.thinking))
        let anchored = controller.update(
            time: time,
            deltaTime: 0.25,
            availableWidth: 620
        )
        XCTAssertFalse(anchored.isMoving)
        XCTAssertEqual(anchored.prop, .laptop)
        XCTAssertNotEqual(movingFrame.worldOffset.x, 0)
        XCTAssertEqual(anchored.worldOffset.x, 0, accuracy: 0.001)
        XCTAssertEqual(anchored.scoutPhase, .anchored)

        let stillAnchored = controller.update(
            time: time + 10,
            deltaTime: 0.25,
            availableWidth: 620
        )
        XCTAssertFalse(stillAnchored.isMoving)
        XCTAssertEqual(
            stillAnchored.worldOffset.x,
            0,
            accuracy: 0.001
        )
    }

    func testLongAnchoredWorkTurnsBothWaysWithoutDrifting() {
        let cases: [(CodexActivity, CodexToolActionHint)] = [
            (.thinking, .none),
            (.tool, .none),
            (.review, .none),
            (.waiting, .none),
        ]

        for (index, item) in cases.enumerated() {
            let controller = MigiBehaviorController(
                seed: UInt64(45 + index),
                initialFacing: -1,
                deepSleepDelay: 1_000_000
            )
            controller.ingest(
                snapshot(item.0, toolActionHint: item.1)
            )
            var facings = Set<Int>()
            var anchoredX: CGFloat?
            for step in 0..<320 {
                let frame = controller.update(
                    time: Double(step) * 0.25,
                    deltaTime: 0.25,
                    availableWidth: 620
                )
                facings.insert(frame.facing < 0 ? -1 : 1)
                if let anchoredX {
                    XCTAssertEqual(frame.worldOffset.x, anchoredX, accuracy: 0.001)
                } else {
                    anchoredX = frame.worldOffset.x
                }
                XCTAssertFalse(frame.isMoving)
            }
            XCTAssertEqual(facings, Set([-1, 1]))
        }
    }

    func testShortSemanticWorkGestureResetsTheAnchoredTurnClock() {
        let seed: UInt64 = 73
        let probe = MigiBehaviorController(
            seed: seed,
            initialFacing: -1,
            deepSleepDelay: 1_000_000
        )
        probe.ingest(snapshot(.thinking))
        var firstTurnStep: Int?
        for step in 0..<200 where firstTurnStep == nil {
            let frame = probe.update(
                time: Double(step) * 0.25,
                deltaTime: 0.25,
                availableWidth: 620
            )
            if frame.facing > 0 {
                firstTurnStep = step
            }
        }
        guard let firstTurnStep else {
            return XCTFail("Probe work pose never reached its first anchored turn.")
        }

        for (index, hint) in [CodexToolActionHint.read, .write].enumerated() {
            let controller = MigiBehaviorController(
                seed: seed,
                initialFacing: -1,
                deepSleepDelay: 1_000_000
            )
            controller.ingest(snapshot(.thinking))
            for step in 0..<firstTurnStep {
                _ = controller.update(
                    time: Double(step) * 0.25,
                    deltaTime: 0.25,
                    availableWidth: 620
                )
            }

            controller.ingest(snapshot(.tool, toolActionHint: hint))
            for offset in 0..<13 {
                let frame = controller.update(
                    time: Double(firstTurnStep + offset) * 0.25,
                    deltaTime: 0.25,
                    availableWidth: 620
                )
                XCTAssertEqual(
                    frame.facing,
                    -1,
                    "Semantic case \(index) inherited the old turn deadline."
                )
                XCTAssertFalse(frame.isMoving)
            }
        }
    }

    func testTurnPresentationIdentityUsesTargetFacingInBothDirections() {
        XCTAssertTrue(
            MigiFullSpriteView.presentationMirroring(
                selectionMirrored: false,
                turnTargetMirrored: true
            )
        )
        XCTAssertFalse(
            MigiFullSpriteView.presentationMirroring(
                selectionMirrored: false,
                turnTargetMirrored: false
            )
        )
        XCTAssertTrue(
            MigiFullSpriteView.presentationMirroring(
                selectionMirrored: true,
                turnTargetMirrored: nil
            )
        )
    }

    func testTransitionLayersRemainComplementaryForPremultipliedCompositing() {
        let tuning = MigiOrganicMotionTuning.preset(
            for: "fine-motor",
            containsProp: false
        )
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            let incoming = MigiTissueTransition(
                progress: progress,
                role: .incoming,
                tuning: tuning
            )
            let outgoing = MigiTissueTransition(
                progress: progress,
                role: .outgoing,
                tuning: tuning
            )
            for rootDistance in stride(from: 0.0, through: 1.0, by: 0.1) {
                for rigidity in [CGFloat(0), 0.5, 1] {
                    let incomingAlpha = incoming.visibility(
                        rootDistance: rootDistance,
                        displayX: 0.43,
                        rigidity: rigidity
                    )
                    let outgoingAlpha = outgoing.visibility(
                        rootDistance: rootDistance,
                        displayX: 0.43,
                        rigidity: rigidity
                    )
                    XCTAssertEqual(
                        incomingAlpha + outgoingAlpha,
                        1,
                        accuracy: 0.000_001
                    )
                }
            }
        }
    }

    func testMultipleActiveAgentsCompleteTheFullPeerSignalEvaluation() {
        let controller = MigiBehaviorController(seed: 48)
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        controller.ingest(snapshot(.thinking, activeAgents: peers))

        let first = controller.update(
            time: 100,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertEqual(first.microAction, .signalSampling)
        XCTAssertEqual(first.prop, .none)
        XCTAssertFalse(first.isMoving)

        XCTAssertEqual(
            controller.update(
                time: 102.93,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .signalSampling
        )
        XCTAssertEqual(
            controller.update(
                time: 102.95,
                deltaTime: 0.02,
                availableWidth: 500
            ).microAction,
            .type
        )

        // An unchanged active set is not a new signal.
        controller.ingest(snapshot(.thinking, activeAgents: peers))
        XCTAssertEqual(
            controller.update(
                time: 113,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .type
        )

        // A later drop and rise is a new collaborative episode.
        controller.ingest(snapshot(.thinking, activeAgents: [.codex]))
        _ = controller.update(time: 113.1, deltaTime: 0.1, availableWidth: 500)
        controller.ingest(snapshot(.thinking, activeAgents: peers))
        XCTAssertEqual(
            controller.update(
                time: 113.2,
                deltaTime: 0.1,
                availableWidth: 500
            ).microAction,
            .signalSampling
        )
    }

    func testExplicitReadCompletesBeforeConcurrentPeerSignalScan() {
        let controller = MigiBehaviorController(seed: 49)
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        controller.ingest(
            snapshot(
                .tool,
                toolActionHint: .read,
                activeAgents: peers
            )
        )

        let first = controller.update(
            time: 100,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertEqual(first.microAction, .read)
        XCTAssertEqual(first.prop, .book)

        // Tool output renews the semantic read hold. The peer scan remains
        // queued and must not consume any of that visible duration.
        controller.ingest(snapshot(.thinking, activeAgents: peers))
        XCTAssertEqual(
            controller.update(
                time: 100.25,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .read
        )
        XCTAssertEqual(
            controller.update(
                time: 102.04,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .read
        )

        let queuedScan = controller.update(
            time: 102.06,
            deltaTime: 0.02,
            availableWidth: 500
        )
        XCTAssertEqual(queuedScan.microAction, .signalSampling)
        XCTAssertEqual(queuedScan.prop, .none)
        XCTAssertEqual(
            controller.update(
                time: 104.98,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .signalSampling
        )
        XCTAssertEqual(
            controller.update(
                time: 105,
                deltaTime: 0.02,
                availableWidth: 500
            ).microAction,
            .type
        )
    }

    func testLiveSourceHandoffCompletesThenFlipsFacingOnce() {
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        let controller = MigiBehaviorController(seed: 481, initialFacing: -1)
        controller.force(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: peers
            )
        )

        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: .grok,
                activeAgents: peers
            )
        )
        let first = controller.update(
            time: 100,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertEqual(first.microAction, .agentHandoff)
        XCTAssertEqual(first.facing, -1)
        XCTAssertFalse(first.isMoving)

        let finalLook = controller.update(
            time: 101.39,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(finalLook.microAction, .agentHandoff)
        XCTAssertEqual(finalLook.facing, -1)

        let turned = controller.update(
            time: 101.41,
            deltaTime: 0.02,
            availableWidth: 500
        )
        XCTAssertEqual(turned.microAction, .agentTurn)
        XCTAssertEqual(turned.facing, 1)

        let settled = controller.update(
            time: 102.43,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(settled.microAction, .type)
        XCTAssertEqual(settled.facing, 1)
    }

    func testDuplicateSourceSnapshotDoesNotRestartAgentHandoff() {
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        let controller = MigiBehaviorController(seed: 482, initialFacing: -1)
        controller.force(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: peers
            )
        )
        let grok = snapshot(
            .thinking,
            sourceAgent: .grok,
            activeAgents: peers
        )

        controller.ingest(grok)
        XCTAssertEqual(
            controller.update(
                time: 100,
                deltaTime: 0,
                availableWidth: 500
            ).microAction,
            .agentHandoff
        )
        controller.ingest(grok)
        XCTAssertEqual(
            controller.update(
                time: 100.8,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .agentHandoff
        )

        let completed = controller.update(
            time: 101.41,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(completed.microAction, .agentTurn)
        XCTAssertEqual(completed.facing, 1)
        XCTAssertEqual(
            controller.update(
                time: 102.43,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .type
        )
    }

    func testAgentTurnSurvivesReviewAndDefersAReadGesture() {
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        let controller = MigiBehaviorController(seed: 4821, initialFacing: -1)
        controller.force(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: peers
            )
        )
        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: .grok,
                activeAgents: peers
            )
        )
        _ = controller.update(time: 100, deltaTime: 0, availableWidth: 500)

        let turn = controller.update(
            time: 101.41,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(turn.microAction, .agentTurn)
        XCTAssertEqual(turn.facing, 1)

        controller.ingest(
            snapshot(
                .review,
                sourceAgent: .grok,
                activeAgents: peers
            )
        )
        XCTAssertEqual(
            controller.update(
                time: 101.7,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .agentTurn
        )

        controller.ingest(
            snapshot(
                .tool,
                toolActionHint: .read,
                sourceAgent: .grok,
                activeAgents: peers
            )
        )
        XCTAssertEqual(
            controller.update(
                time: 101.8,
                deltaTime: 0.1,
                availableWidth: 500
            ).microAction,
            .agentTurn
        )
        XCTAssertEqual(
            controller.update(
                time: 102.43,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .read
        )
        XCTAssertEqual(
            controller.update(
                time: 104.21,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .read
        )
    }

    func testRapidSourceSwitchBackDoesNotFlipTowardStaleAgent() {
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        let controller = MigiBehaviorController(seed: 483, initialFacing: -1)
        controller.force(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: peers
            )
        )

        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: .grok,
                activeAgents: peers
            )
        )
        XCTAssertEqual(
            controller.update(
                time: 100,
                deltaTime: 0,
                availableWidth: 500
            ).microAction,
            .agentHandoff
        )

        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: peers
            )
        )
        XCTAssertEqual(
            controller.update(
                time: 100.5,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .agentHandoff
        )

        let settled = controller.update(
            time: 101.41,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(settled.microAction, .type)
        XCTAssertEqual(settled.facing, -1)
    }

    func testSourceReversalOnHandoffExpiryFrameDoesNotTurnTowardStaleAgent() {
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        let controller = MigiBehaviorController(seed: 4831, initialFacing: -1)
        controller.force(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: peers
            )
        )
        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: .grok,
                activeAgents: peers
            )
        )
        _ = controller.update(time: 100, deltaTime: 0, availableWidth: 500)

        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: peers
            )
        )
        let expiry = controller.update(
            time: 101.41,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(expiry.microAction, .type)
        XCTAssertEqual(expiry.facing, -1)
    }

    func testAllLiveAgentsEndingTogetherCancelsPendingHandoff() {
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        let controller = MigiBehaviorController(seed: 4832, initialFacing: -1)
        controller.force(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: peers
            )
        )
        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: .grok,
                activeAgents: peers
            )
        )
        XCTAssertEqual(
            controller.update(
                time: 100,
                deltaTime: 0,
                availableWidth: 500
            ).microAction,
            .agentHandoff
        )

        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: nil,
                activeAgents: []
            )
        )
        let noLiveAgent = controller.update(
            time: 100.5,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(noLiveAgent.microAction, .type)
        XCTAssertEqual(noLiveAgent.facing, -1)

        let later = controller.update(
            time: 102,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertNotEqual(later.microAction, .agentTurn)
        XCTAssertEqual(later.facing, -1)
    }

    func testCommittedAgentTurnFinishesWhenAllLiveAgentsEnd() {
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        let controller = MigiBehaviorController(seed: 4833, initialFacing: -1)
        controller.force(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: peers
            )
        )
        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: .grok,
                activeAgents: peers
            )
        )
        _ = controller.update(time: 100, deltaTime: 0, availableWidth: 500)
        XCTAssertEqual(
            controller.update(
                time: 101.41,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .agentTurn
        )

        controller.ingest(
            snapshot(
                .idle,
                sourceAgent: nil,
                activeAgents: []
            )
        )
        let stillTurning = controller.update(
            time: 101.7,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(stillTurning.microAction, .agentTurn)
        XCTAssertEqual(stillTurning.facing, 1)

        XCTAssertNotEqual(
            controller.update(
                time: 102.43,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .agentTurn
        )
    }

    func testPeerDepartureReconciliationWaitsForCommittedAgentTurn() {
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        let controller = MigiBehaviorController(seed: 4834, initialFacing: -1)
        controller.force(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: peers
            )
        )
        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: .grok,
                activeAgents: peers
            )
        )
        _ = controller.update(time: 100, deltaTime: 0, availableWidth: 500)
        _ = controller.update(time: 101.41, deltaTime: 0.25, availableWidth: 500)

        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: .grok,
                activeAgents: [.grok]
            )
        )
        XCTAssertEqual(
            controller.update(
                time: 101.7,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .agentTurn
        )
        XCTAssertEqual(
            controller.update(
                time: 102.43,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .logicCount
        )
        XCTAssertEqual(
            controller.update(
                time: 103.89,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .logicCount
        )
        XCTAssertEqual(
            controller.update(
                time: 103.91,
                deltaTime: 0.02,
                availableWidth: 500
            ).microAction,
            .type
        )
    }

    func testMonitoringGenerationChangeRebaselinesWithoutAgentHandoff() {
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        let controller = MigiBehaviorController(seed: 484, initialFacing: -1)
        controller.force(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                monitoringGeneration: 7,
                activeAgents: peers
            )
        )

        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: .grok,
                monitoringGeneration: 8,
                activeAgents: peers
            )
        )
        let rebaseline = controller.update(
            time: 100,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertEqual(rebaseline.microAction, .signalSampling)
        XCTAssertNotEqual(rebaseline.microAction, .agentHandoff)
        XCTAssertEqual(rebaseline.facing, -1)

        let settled = controller.update(
            time: 102.95,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(settled.microAction, .type)
        XCTAssertEqual(settled.facing, -1)
    }

    func testSequentialCodexToGrokHandoffWorksButZCodeDoesNot() {
        let liveController = MigiBehaviorController(
            seed: 485,
            initialFacing: -1
        )
        liveController.force(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: [.codex]
            )
        )
        liveController.ingest(
            snapshot(
                .thinking,
                sourceAgent: .grok,
                activeAgents: [.grok]
            )
        )
        XCTAssertEqual(
            liveController.update(
                time: 100,
                deltaTime: 0,
                availableWidth: 500
            ).microAction,
            .agentHandoff
        )

        let zcodeController = MigiBehaviorController(
            seed: 486,
            initialFacing: -1
        )
        zcodeController.force(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: [.codex]
            )
        )
        zcodeController.ingest(
            snapshot(
                .thinking,
                sourceAgent: .zcode,
                activeAgents: [.zcode]
            )
        )
        let zcode = zcodeController.update(
            time: 100,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertNotEqual(zcode.microAction, .agentHandoff)
        XCTAssertEqual(zcode.facing, -1)
    }

    func testExplicitReadAndWriteCompleteBeforeAgentHandoff() {
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        let cases: [
            (
                hint: CodexToolActionHint,
                semanticAction: MigiMicroAction,
                holdDuration: TimeInterval
            )
        ] = [
            (.read, .read, 1.8),
            (.write, .fineMotor, 2.4),
        ]

        for (index, item) in cases.enumerated() {
            let controller = MigiBehaviorController(
                seed: UInt64(487 + index),
                initialFacing: -1
            )
            controller.force(
                snapshot(
                    .thinking,
                    sourceAgent: .codex,
                    activeAgents: peers
                )
            )
            controller.ingest(
                snapshot(
                    .tool,
                    toolActionHint: item.hint,
                    sourceAgent: .grok,
                    activeAgents: peers
                )
            )

            XCTAssertEqual(
                controller.update(
                    time: 100,
                    deltaTime: 0,
                    availableWidth: 500
                ).microAction,
                item.semanticAction
            )
            XCTAssertEqual(
                controller.update(
                    time: 100 + item.holdDuration - 0.01,
                    deltaTime: 0.25,
                    availableWidth: 500
                ).microAction,
                item.semanticAction
            )

            let handoff = controller.update(
                time: 100 + item.holdDuration + 0.01,
                deltaTime: 0.02,
                availableWidth: 500
            )
            XCTAssertEqual(handoff.microAction, .agentHandoff)
            XCTAssertEqual(handoff.facing, -1)
        }
    }

    func testWaitingAndFailureCancelAnActiveAgentHandoff() {
        for (index, interruption) in [
            CodexActivity.waiting,
            .failed,
        ].enumerated() {
            let peers: Set<MonitoredAgent> = [.codex, .grok]
            let controller = MigiBehaviorController(
                seed: UInt64(489 + index),
                initialFacing: -1
            )
            controller.force(
                snapshot(
                    .thinking,
                    sourceAgent: .codex,
                    activeAgents: peers
                )
            )
            controller.ingest(
                snapshot(
                    .thinking,
                    sourceAgent: .grok,
                    activeAgents: peers
                )
            )
            XCTAssertEqual(
                controller.update(
                    time: 100,
                    deltaTime: 0,
                    availableWidth: 500
                ).microAction,
                .agentHandoff
            )

            controller.ingest(
                snapshot(
                    interruption,
                    sourceAgent: .grok,
                    activeAgents: peers
                )
            )
            let interrupted = controller.update(
                time: 100.2,
                deltaTime: 0.2,
                availableWidth: 500
            )
            XCTAssertNotEqual(interrupted.microAction, .agentHandoff)
            XCTAssertEqual(interrupted.facing, -1)
        }
    }

    func testPeerDepartureCompletesOneLogicCountReconciliation() {
        let peers: Set<MonitoredAgent> = [.codex, .grok]
        let controller = MigiBehaviorController(seed: 491, initialFacing: -1)
        controller.force(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: peers
            )
        )

        controller.ingest(
            snapshot(
                .thinking,
                sourceAgent: .codex,
                activeAgents: [.codex]
            )
        )
        XCTAssertEqual(
            controller.update(
                time: 100,
                deltaTime: 0,
                availableWidth: 500
            ).microAction,
            .logicCount
        )
        XCTAssertEqual(
            controller.update(
                time: 101.47,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .logicCount
        )

        let settled = controller.update(
            time: 101.49,
            deltaTime: 0.02,
            availableWidth: 500
        )
        XCTAssertEqual(settled.microAction, .type)
        XCTAssertEqual(settled.facing, -1)
    }

    func testPatrolPlantsInPlaceForTheAuthoredTurnBeforeTranslating() {
        let controller = MigiBehaviorController(
            seed: 50,
            initialFacing: -1,
            deepSleepDelay: 1_000_000,
            scoutInterval: 0...0,
            scoutDetachedDuration: 5...5
        )
        controller.ingest(snapshot(.idle))

        var previousFacing: CGFloat = -1
        var turnStartTime: TimeInterval?
        var plantedX: CGFloat = 0
        for step in 0..<80 where turnStartTime == nil {
            let time = Double(step) * 0.1
            let frame = controller.update(
                time: time,
                deltaTime: 0.1,
                availableWidth: 620
            )
            if frame.isMoving, frame.facing != previousFacing {
                turnStartTime = time
                plantedX = frame.worldOffset.x
            }
            previousFacing = frame.facing
        }
        guard let turnStartTime else {
            return XCTFail("Patrol never began its first facing change.")
        }

        for offset in [0.2, 0.55, 0.95] {
            let planted = controller.update(
                time: turnStartTime + offset,
                deltaTime: 0.25,
                availableWidth: 620
            )
            XCTAssertTrue(planted.isMoving)
            XCTAssertEqual(planted.worldOffset.x, plantedX, accuracy: 0.001)
        }

        let translating = controller.update(
            time: turnStartTime + MigiAnimationTiming.patrolTurnDuration + 0.02,
            deltaTime: 0.25,
            availableWidth: 620
        )
        XCTAssertNotEqual(translating.worldOffset.x, plantedX)
    }

    func testFailureDefenseRecoversInsteadOfRemainingLatched() {
        let controller = MigiBehaviorController(seed: 9)
        controller.ingest(snapshot(.failed))
        XCTAssertEqual(
            controller.update(time: 10, deltaTime: 0, availableWidth: 500).activity,
            .failed
        )
        XCTAssertNotEqual(
            controller.update(time: 13.3, deltaTime: 0.1, availableWidth: 500).activity,
            .failed
        )
    }

    func testIdleCycleActuallyUsesEveryCanonicalWholeBodyAction() {
        let controller = MigiBehaviorController(
            seed: 0x4D49_4749,
            deepSleepDelay: 1_000_000
        )
        controller.ingest(snapshot(.idle))
        var actions = Set<MigiMicroAction>()

        for step in 0..<20_000 {
            let frame = controller.update(
                time: Double(step) * 0.25,
                deltaTime: 0.25,
                availableWidth: 620
            )
            actions.insert(frame.microAction)
            if frame.microAction == .dormant {
                XCTAssertEqual(frame.wakePhase, .awake)
                XCTAssertFalse(frame.isDeepSleeping)
                XCTAssertFalse(frame.suppressesPointerGaze)
            }
        }

        XCTAssertTrue(actions.contains(.palmObserver))
        XCTAssertFalse(actions.contains(.sharpenTip))
        XCTAssertTrue(actions.contains(.signalSampling))
        XCTAssertTrue(actions.contains(.stretch))
        XCTAssertTrue(actions.contains(.dormant))
        XCTAssertTrue(actions.contains(.rapidNotes))
        XCTAssertTrue(actions.contains(.fineMotor))
        XCTAssertTrue(actions.contains(.organDrift))
        XCTAssertTrue(actions.contains(.logicCount))
        XCTAssertTrue(actions.contains(.storagePocket))
        XCTAssertTrue(actions.contains(.recoveryCare))
    }

    func testOneShotIdleActionsDoNotFreezeOnTheirLastFrameForSeconds() {
        let controller = MigiBehaviorController(
            seed: 0x4D49_4749,
            deepSleepDelay: 1_000_000
        )
        controller.ingest(snapshot(.idle))
        let oneShotActions: Set<MigiMicroAction> = [
            .palmObserver,
            .signalSampling,
            .stretch,
            .organDrift,
            .logicCount,
        ]
        var activeAction: MigiMicroAction?
        var activeStartedAt: TimeInterval = 0
        var maximumDurations: [MigiMicroAction: TimeInterval] = [:]

        for step in 0..<50_000 {
            let time = Double(step) * 0.1
            let action = controller.update(
                time: time,
                deltaTime: 0.1,
                availableWidth: 620
            ).microAction

            if action != activeAction {
                if let activeAction, oneShotActions.contains(activeAction) {
                    maximumDurations[activeAction] = max(
                        maximumDurations[activeAction, default: 0],
                        time - activeStartedAt
                    )
                }
                activeAction = action
                activeStartedAt = time
            }
        }

        XCTAssertEqual(Set(maximumDurations.keys), oneShotActions)
        for (action, duration) in maximumDurations {
            let limit: TimeInterval = action == .signalSampling ? 2.9 : 2.2
            XCTAssertLessThanOrEqual(duration, limit)
        }
    }

    func testAuthoredTurnTimelineMatchesPatrolTranslationDelay() throws {
        guard let url = Bundle.module.url(
            forResource: "migi-v4-atlas",
            withExtension: "json"
        ) else {
            return XCTFail("Missing bundled Migi atlas manifest.")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        guard let root = object as? [String: Any],
              let clips = root["clips"] as? [String: Any]
        else {
            return XCTFail("Invalid Migi atlas manifest.")
        }

        for name in ["turn-left", "turn-right"] {
            guard let clip = clips[name] as? [String: Any],
                  let durations = clip["frame_durations"] as? [Double]
            else {
                return XCTFail("Missing authored duration for \(name).")
            }
            XCTAssertEqual(
                durations.reduce(0, +),
                MigiAnimationTiming.patrolTurnDuration,
                accuracy: 0.0001
            )
        }
    }

    func testCanonicalTransformationsAnchorBeforeTheyPlay() {
        let controller = MigiBehaviorController(
            seed: 0x4D49_4749,
            deepSleepDelay: 1_000_000
        )
        controller.ingest(snapshot(.idle))
        var previous: MigiBehaviorFrame?
        var observedAnchoredAction = false

        for step in 0..<4_000 {
            let frame = controller.update(
                time: Double(step) * 0.25,
                deltaTime: 0.25,
                availableWidth: 620
            )
            if [
                .palmObserver,
                .sharpenTip,
                .protectiveShield,
                .rapidNotes,
                .fineMotor,
                .organDrift,
                .logicCount,
                .signalSampling,
                .storagePocket,
                .recoveryCare,
                .calmDiagnosis,
                .lookAround,
                .stretch,
                .dormant
            ]
                .contains(frame.microAction)
            {
                XCTAssertFalse(frame.isMoving)
                if let previous, previous.microAction == frame.microAction {
                    XCTAssertEqual(
                        frame.worldOffset.x,
                        previous.worldOffset.x,
                        accuracy: 0.001
                    )
                    observedAnchoredAction = true
                }
            }
            previous = frame
        }

        XCTAssertTrue(observedAnchoredAction)
    }

    func testNewIdleActionsOnlyBeginAfterPatrolStops() {
        let controller = MigiBehaviorController(
            seed: 0x4D49_4749,
            deepSleepDelay: 1_000_000
        )
        controller.ingest(snapshot(.idle))
        let newActions: Set<MigiMicroAction> = [
            .rapidNotes,
            .fineMotor,
            .organDrift,
            .logicCount,
            .palmObserver,
            .signalSampling,
            .storagePocket,
            .recoveryCare
        ]
        var previous: MigiBehaviorFrame?
        var startsObserved = 0

        for step in 0..<20_000 {
            let frame = controller.update(
                time: Double(step) * 0.25,
                deltaTime: 0.25,
                availableWidth: 620
            )
            if newActions.contains(frame.microAction),
               previous?.microAction != frame.microAction
            {
                XCTAssertFalse(frame.isMoving)
                XCTAssertFalse(previous?.isMoving ?? true)
                startsObserved += 1
            }
            previous = frame
        }

        XCTAssertGreaterThan(startsObserved, 3)
    }

    func testWorkImmediatelyPreemptsEveryNewIdleAction() {
        let controller = MigiBehaviorController(
            seed: 0x4D49_4749,
            deepSleepDelay: 1_000_000
        )
        controller.ingest(snapshot(.idle))
        let newActions: Set<MigiMicroAction> = [
            .rapidNotes,
            .fineMotor,
            .organDrift,
            .logicCount,
            .palmObserver,
            .signalSampling,
            .storagePocket,
            .recoveryCare
        ]
        var preempted = Set<MigiMicroAction>()
        var time: TimeInterval = 0

        for _ in 0..<40_000 where preempted != newActions {
            let frame = controller.update(
                time: time,
                deltaTime: 0.25,
                availableWidth: 620
            )
            if newActions.contains(frame.microAction),
               !preempted.contains(frame.microAction)
            {
                let interruptedAction = frame.microAction
                controller.ingest(snapshot(.thinking))
                let working = controller.update(
                    time: time + 0.01,
                    deltaTime: 0.01,
                    availableWidth: 620
                )
                XCTAssertEqual(working.activity, .thinking)
                XCTAssertEqual(working.microAction, .type)
                XCTAssertEqual(working.prop, .laptop)
                preempted.insert(interruptedAction)
                controller.force(snapshot(.idle))
            }
            time += 0.25
        }

        XCTAssertEqual(preempted, newActions)
    }

    func testNovelUnknownToolPlaysExactlyTwoSignalLoopsAndDoesNotRestart() {
        let controller = MigiBehaviorController(seed: 131)
        let event = novelTool(sequence: 1)
        let toolSnapshot = snapshot(
            .tool,
            sourcePath: event.sourcePath,
            sourceAgent: event.agent,
            latestNovelTool: event
        )
        controller.ingest(toolSnapshot)

        let first = controller.update(
            time: 100,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertEqual(first.microAction, .signalSampling)
        XCTAssertEqual(first.prop, .none)
        XCTAssertFalse(first.isMoving)

        controller.ingest(toolSnapshot)
        XCTAssertEqual(
            controller.update(
                time: 100.8,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .signalSampling
        )
        XCTAssertEqual(
            controller.update(
                time: 101.919,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .signalSampling
        )
        let released = controller.update(
            time: 101.921,
            deltaTime: 0.01,
            availableWidth: 500
        )
        XCTAssertEqual(released.microAction, .fineMotor)
        XCTAssertEqual(released.prop, .none)

        controller.ingest(toolSnapshot)
        XCTAssertEqual(
            controller.update(
                time: 102,
                deltaTime: 0.1,
                availableWidth: 500
            ).microAction,
            .fineMotor
        )
    }

    func testNovelToolCooldownConsumesSuppressedSequencesOnce() {
        let controller = MigiBehaviorController(seed: 141)
        controller.ingest(
            snapshot(.thinking, latestNovelTool: novelTool(sequence: 1))
        )
        XCTAssertEqual(
            controller.update(
                time: 100,
                deltaTime: 0,
                availableWidth: 500
            ).microAction,
            .signalSampling
        )

        let suppressed = novelTool(sequence: 2)
        controller.ingest(snapshot(.thinking, latestNovelTool: suppressed))
        XCTAssertEqual(
            controller.update(
                time: 120,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .type
        )

        // The cooldown has expired, but sequence 2 was already consumed and
        // cannot be resurrected by a repeated snapshot.
        controller.ingest(snapshot(.thinking, latestNovelTool: suppressed))
        XCTAssertEqual(
            controller.update(
                time: 160.01,
                deltaTime: 0.25,
                availableWidth: 500
            ).microAction,
            .type
        )

        controller.ingest(
            snapshot(.thinking, latestNovelTool: novelTool(sequence: 3))
        )
        XCTAssertEqual(
            controller.update(
                time: 160.02,
                deltaTime: 0.01,
                availableWidth: 500
            ).microAction,
            .signalSampling
        )
    }

    func testNovelToolIsIndependentFromTheActivityWinnerAgentAndSource() {
        let controller = MigiBehaviorController(seed: 151)
        let event = novelTool(
            sequence: 1,
            agent: .codex,
            sourcePath: "/tmp/codex/rollout.jsonl"
        )
        controller.ingest(
            snapshot(
                .thinking,
                sourcePath: "/tmp/grok/session.jsonl",
                sourceAgent: .grok,
                latestNovelTool: event
            )
        )

        let frame = controller.update(
            time: 100,
            deltaTime: 0,
            availableWidth: 500
        )
        XCTAssertEqual(frame.activity, .thinking)
        XCTAssertEqual(frame.microAction, .signalSampling)
        XCTAssertEqual(frame.prop, .none)
    }

    func testReadAndWriteNoveltyNeverOverridesCanonicalToolGestures() {
        let cases: [
            (
                hint: CodexToolActionHint,
                expected: MigiMicroAction,
                holdDuration: TimeInterval
            )
        ] = [
            (.read, .read, 1.8),
            (.write, .fineMotor, 2.4)
        ]

        for (index, item) in cases.enumerated() {
            let controller = MigiBehaviorController(seed: UInt64(161 + index))
            let event = novelTool(
                sequence: 1,
                hint: item.hint
            )
            controller.ingest(
                snapshot(
                    .tool,
                    toolActionHint: item.hint,
                    sourcePath: event.sourcePath,
                    sourceAgent: event.agent,
                    latestNovelTool: event
                )
            )
            XCTAssertEqual(
                controller.update(
                    time: 100,
                    deltaTime: 0,
                    availableWidth: 500
                ).microAction,
                item.expected
            )

            controller.ingest(snapshot(.thinking))
            _ = controller.update(
                time: 100.1,
                deltaTime: 0.1,
                availableWidth: 500
            )
            let released = controller.update(
                time: 100.1 + item.holdDuration + 0.01,
                deltaTime: 0.25,
                availableWidth: 500
            )
            XCTAssertEqual(released.microAction, .type)
            XCTAssertEqual(released.prop, .laptop)
        }
    }

    func testWaitingAndFailureImmediatelyPreemptNovelToolGesture() {
        for (index, activity) in [
            CodexActivity.waiting,
            .failed
        ].enumerated() {
            let controller = MigiBehaviorController(seed: UInt64(171 + index))
            controller.ingest(
                snapshot(
                    .thinking,
                    latestNovelTool: novelTool(sequence: 1)
                )
            )
            XCTAssertEqual(
                controller.update(
                    time: 100,
                    deltaTime: 0,
                    availableWidth: 500
                ).microAction,
                .signalSampling
            )

            controller.ingest(snapshot(activity))
            let frame = controller.update(
                time: 100.1,
                deltaTime: 0.1,
                availableWidth: 500
            )
            XCTAssertEqual(frame.activity, activity)
            XCTAssertNotEqual(frame.microAction, .signalSampling)
            if activity == .waiting {
                XCTAssertEqual(frame.microAction, .checkPhone)
                XCTAssertEqual(frame.prop, .phone)
            } else {
                XCTAssertEqual(frame.microAction, .calmDiagnosis)
                XCTAssertEqual(frame.prop, .none)
            }
        }
    }

    func testNovelToolTTLAndIdentityValidationRejectStaleOrMalformedEvents() {
        let staleController = MigiBehaviorController(seed: 181)
        staleController.ingest(
            snapshot(
                .thinking,
                latestNovelTool: novelTool(
                    sequence: 1,
                    observedAt: Date(timeIntervalSinceNow: -20)
                )
            )
        )
        XCTAssertEqual(
            staleController.update(
                time: 100,
                deltaTime: 0,
                availableWidth: 500
            ).microAction,
            .type
        )

        let malformedController = MigiBehaviorController(seed: 182)
        malformedController.ingest(
            snapshot(
                .thinking,
                latestNovelTool: novelTool(
                    sequence: 2,
                    sourcePath: ""
                )
            )
        )
        XCTAssertEqual(
            malformedController.update(
                time: 100,
                deltaTime: 0,
                availableWidth: 500
            ).microAction,
            .type
        )
    }

    func testForceClearsWakeAndNoveltyLatchesAndCooldown() {
        let controller = MigiBehaviorController(seed: 191)
        let event = novelTool(sequence: 1)
        controller.ingest(snapshot(.thinking, latestNovelTool: event))
        XCTAssertEqual(
            controller.update(
                time: 100,
                deltaTime: 0,
                availableWidth: 500
            ).microAction,
            .signalSampling
        )
        controller.forceWakePhaseForQA(.lookAround)
        XCTAssertEqual(
            controller.update(
                time: 100.1,
                deltaTime: 0.1,
                availableWidth: 500
            ).wakePhase,
            .lookAround
        )

        controller.force(snapshot(.thinking))
        let reset = controller.update(
            time: 100.2,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertEqual(reset.wakePhase, .awake)
        XCTAssertEqual(reset.microAction, .type)

        // The same semantic sequence may be used again after an explicit QA
        // reset, proving both the consumed set and cooldown were cleared.
        controller.ingest(snapshot(.thinking, latestNovelTool: event))
        XCTAssertEqual(
            controller.update(
                time: 100.3,
                deltaTime: 0.1,
                availableWidth: 500
            ).microAction,
            .signalSampling
        )
    }

    func testTapCooldownUsesTheNextUpdateClockAndDoesNotQueue() {
        let controller = MigiBehaviorController(
            seed: 301,
            deepSleepDelay: 1_000_000,
            scoutInterval: 1_000...1_000
        )
        controller.ingest(snapshot(.idle))
        _ = controller.update(time: 90, deltaTime: 0, availableWidth: 500)

        controller.ingestInteraction(.tap)
        let accepted = controller.update(
            time: 100,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertTrue(accepted.isUserAttentionActive)
        XCTAssertEqual(accepted.microAction, .lookAround)

        // This tap is consumed and discarded inside the eight-second window.
        controller.ingestInteraction(.tap)
        let cooledDown = controller.update(
            time: 101,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertFalse(cooledDown.isUserAttentionActive)

        let noDelayedReplay = controller.update(
            time: 107.99,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertFalse(noDelayedReplay.isUserAttentionActive)
        XCTAssertNotEqual(noDelayedReplay.microAction, .lookAround)

        controller.ingestInteraction(.tap)
        let acceptedAfterCooldown = controller.update(
            time: 108,
            deltaTime: 0.01,
            availableWidth: 500
        )
        XCTAssertTrue(acceptedAfterCooldown.isUserAttentionActive)
        XCTAssertEqual(acceptedAfterCooldown.microAction, .lookAround)
    }

    func testTapAttentionDurationTracksAllThreeRelationshipStages() {
        let cases: [
            (
                profile: MigiRelationshipProfile,
                stage: MigiRelationshipStage,
                duration: TimeInterval
            )
        ] = [
            (.init(), .cautious, 0.45),
            (
                .init(cooperationDuration: 30 * 60, familiarToolCount: 3),
                .cooperative,
                0.70
            ),
            (
                .init(cooperationDuration: 12 * 60 * 60, familiarToolCount: 10),
                .protective,
                0.90
            ),
        ]

        for (index, item) in cases.enumerated() {
            let controller = MigiBehaviorController(seed: UInt64(310 + index))
            controller.ingest(
                snapshot(
                    .thinking,
                    relationshipProfile: item.profile
                )
            )
            _ = controller.update(time: 10, deltaTime: 0, availableWidth: 500)

            controller.ingestInteraction(.tap)
            let started = controller.update(
                time: 100,
                deltaTime: 0.1,
                availableWidth: 500
            )
            XCTAssertEqual(started.relationshipStage, item.stage)
            XCTAssertTrue(started.isUserAttentionActive)
            XCTAssertEqual(started.microAction, .type)
            XCTAssertEqual(started.prop, .laptop)

            XCTAssertTrue(
                controller.update(
                    time: 100 + item.duration - 0.001,
                    deltaTime: 0.1,
                    availableWidth: 500
                ).isUserAttentionActive
            )
            XCTAssertFalse(
                controller.update(
                    time: 100 + item.duration,
                    deltaTime: 0.001,
                    availableWidth: 500
                ).isUserAttentionActive
            )
        }
    }

    func testTapPreservesWorkWaitingReviewAndRoutineFailurePoses() {
        let cases: [
            (
                activity: CodexActivity,
                hint: CodexToolActionHint,
                action: MigiMicroAction,
                prop: MigiProp
            )
        ] = [
            (.thinking, .none, .type, .laptop),
            (.tool, .read, .read, .book),
            (.review, .none, .signalSampling, .none),
            (.waiting, .none, .checkPhone, .phone),
            (.failed, .none, .calmDiagnosis, .none),
        ]

        for (index, item) in cases.enumerated() {
            let controller = MigiBehaviorController(seed: UInt64(320 + index))
            controller.ingest(
                snapshot(
                    item.activity,
                    toolActionHint: item.hint
                )
            )
            let before = controller.update(
                time: 20,
                deltaTime: 0,
                availableWidth: 500
            )
            XCTAssertEqual(before.microAction, item.action)
            XCTAssertEqual(before.prop, item.prop)

            controller.ingestInteraction(.tap)
            let tapped = controller.update(
                time: 20.1,
                deltaTime: 0.1,
                availableWidth: 500
            )
            XCTAssertEqual(tapped.activity, item.activity)
            XCTAssertEqual(tapped.microAction, item.action)
            XCTAssertEqual(tapped.prop, item.prop)
            XCTAssertTrue(tapped.isUserAttentionActive)
        }
    }

    func testTapClearsAnchoredIdleActionAndShowsOneCompleteLookAround() {
        let controller = MigiBehaviorController(
            seed: 329,
            deepSleepDelay: 1_000_000,
            scoutInterval: 1_000...1_000
        )
        controller.ingest(snapshot(.idle))

        var time: TimeInterval = 0
        var foundIdleAction = false
        for step in 0..<1_000 where !foundIdleAction {
            time = Double(step) * 0.1
            let frame = controller.update(
                time: time,
                deltaTime: 0.1,
                availableWidth: 500
            )
            foundIdleAction =
                frame.scoutPhase == .anchored
                    && frame.microAction != .none
                    && frame.microAction != .blink
        }
        XCTAssertTrue(foundIdleAction)

        controller.ingestInteraction(.tap)
        let tapTime = time + 0.01
        let tapped = controller.update(
            time: tapTime,
            deltaTime: 0.01,
            availableWidth: 500
        )
        XCTAssertEqual(tapped.microAction, .lookAround)
        XCTAssertEqual(tapped.prop, .none)

        let finalAuthoredFrame = controller.update(
            time: tapTime + 1.39,
            deltaTime: 0.25,
            availableWidth: 500
        )
        XCTAssertEqual(finalAuthoredFrame.microAction, .lookAround)

        let completed = controller.update(
            time: tapTime + 1.41,
            deltaTime: 0.02,
            availableWidth: 500
        )
        XCTAssertNotEqual(completed.microAction, .lookAround)
    }

    func testAnchoredWorkAndTransformationPosesKeepThePanelOriginStable() {
        let cases: [(CodexActivity, CodexToolActionHint)] = [
            (.thinking, .none),
            (.tool, .read),
            (.tool, .write),
            (.waiting, .none),
            (.review, .none),
        ]

        for (index, item) in cases.enumerated() {
            let controller = MigiBehaviorController(seed: UInt64(390 + index))
            controller.ingest(
                snapshot(item.0, toolActionHint: item.1)
            )
            for time in stride(from: 10.0, through: 12.0, by: 0.1) {
                let frame = controller.update(
                    time: time,
                    deltaTime: 0.1,
                    availableWidth: 500
                )
                XCTAssertEqual(frame.scoutPhase, .anchored)
                XCTAssertEqual(frame.worldOffset.x, 0, accuracy: 0.001)
                XCTAssertEqual(frame.worldOffset.y, 0, accuracy: 0.001)
            }
        }
    }

    func testTapDuringSleepWakeOrCredibleThreatIsDiscarded() {
        for (index, phase) in [
            MigiWakePhase.deepSleep,
            .dreamDisturbance,
            .lookAround,
        ].enumerated() {
            let controller = MigiBehaviorController(seed: UInt64(330 + index))
            controller.force(snapshot(.idle))
            controller.forceWakePhaseForQA(phase)
            _ = controller.update(time: 100, deltaTime: 0, availableWidth: 500)

            controller.ingestInteraction(.tap)
            let ignored = controller.update(
                time: 100.1,
                deltaTime: 0.1,
                availableWidth: 500
            )
            XCTAssertFalse(ignored.isUserAttentionActive)

            // Becoming awake later must not replay the ignored tap.
            controller.forceWakePhaseForQA(.awake)
            let awake = controller.update(
                time: 101,
                deltaTime: 0.1,
                availableWidth: 500
            )
            XCTAssertFalse(awake.isUserAttentionActive)
            XCTAssertNotEqual(awake.microAction, .lookAround)
        }

        let threatController = MigiBehaviorController(seed: 334)
        threatController.ingest(snapshot(.idle))
        _ = threatController.update(
            time: 200,
            deltaTime: 0,
            availableWidth: 500
        )
        threatController.ingestInteraction(.tap)
        threatController.ingest(
            snapshot(
                .failed,
                failureDisposition: .credibleThreat
            )
        )
        let defense = threatController.update(
            time: 200.1,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertFalse(defense.isUserAttentionActive)
        XCTAssertEqual(defense.microAction, .protectiveShield)

        threatController.ingest(snapshot(.idle))
        let noDelayedThreatTap = threatController.update(
            time: 200.2,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertFalse(noDelayedThreatTap.isUserAttentionActive)
        XCTAssertNotEqual(noDelayedThreatTap.microAction, .lookAround)
    }

    func testTapPausesDetachedScoutInPlaceThenReturnsContinuously() {
        let controller = MigiBehaviorController(
            seed: 341,
            initialFacing: -1,
            deepSleepDelay: 1_000_000,
            scoutInterval: 0...0,
            scoutDetachedDuration: 20...20
        )
        controller.ingest(snapshot(.idle))

        var time: TimeInterval = 0
        var outbound: MigiBehaviorFrame?
        for _ in 0..<200 where outbound == nil {
            let frame = controller.update(
                time: time,
                deltaTime: 0.1,
                availableWidth: 620
            )
            if frame.scoutPhase == .outbound,
               abs(frame.worldOffset.x) > 2
            {
                outbound = frame
            }
            time += 0.1
        }
        guard let outbound else {
            return XCTFail("Detached scout never translated away from its anchor.")
        }

        controller.ingestInteraction(.tap)
        let tapTime = time
        let paused = controller.update(
            time: tapTime,
            deltaTime: 0.1,
            availableWidth: 620
        )
        XCTAssertFalse(paused.isMoving)
        XCTAssertEqual(paused.scoutPhase, .outbound)
        XCTAssertEqual(paused.microAction, .lookAround)
        XCTAssertEqual(
            paused.worldOffset.x,
            outbound.worldOffset.x,
            accuracy: 0.001
        )
        XCTAssertEqual(
            paused.worldOffset.y,
            outbound.worldOffset.y,
            accuracy: 0.001
        )

        let finalPause = controller.update(
            time: tapTime + 1.39,
            deltaTime: 0.25,
            availableWidth: 620
        )
        XCTAssertFalse(finalPause.isMoving)
        XCTAssertEqual(finalPause.microAction, .lookAround)
        XCTAssertEqual(
            finalPause.worldOffset.x,
            outbound.worldOffset.x,
            accuracy: 0.001
        )
        XCTAssertEqual(
            finalPause.worldOffset.y,
            outbound.worldOffset.y,
            accuracy: 0.001
        )

        var returning = controller.update(
            time: tapTime + 1.41,
            deltaTime: 0.02,
            availableWidth: 620
        )
        XCTAssertTrue(returning.isMoving)
        XCTAssertEqual(returning.scoutPhase, .returning)
        XCTAssertEqual(returning.microAction, .detachedScoutReturn)
        XCTAssertEqual(
            returning.worldOffset.x,
            outbound.worldOffset.x,
            accuracy: 0.001
        )
        XCTAssertEqual(
            returning.worldOffset.y,
            outbound.worldOffset.y,
            accuracy: 0.001
        )

        var previousX = returning.worldOffset.x
        var returnedToAnchor = false
        time = tapTime + 1.41
        for _ in 0..<200 where !returnedToAnchor {
            time += 0.1
            returning = controller.update(
                time: time,
                deltaTime: 0.1,
                availableWidth: 620
            )
            XCTAssertLessThanOrEqual(
                abs(returning.worldOffset.x - previousX),
                6.0
            )
            previousX = returning.worldOffset.x
            returnedToAnchor = returning.scoutPhase == .anchored
        }

        XCTAssertTrue(returnedToAnchor)
        XCTAssertEqual(returning.worldOffset.x, 0, accuracy: 0.001)
        XCTAssertFalse(returning.isMoving)
    }

    func testForceAndQAWakeResetClearInteractionAndCooldown() {
        let controller = MigiBehaviorController(
            seed: 351,
            deepSleepDelay: 1_000_000,
            scoutInterval: 1_000...1_000
        )
        controller.ingest(snapshot(.idle))
        _ = controller.update(time: 10, deltaTime: 0, availableWidth: 500)
        controller.ingestInteraction(.tap)
        XCTAssertTrue(
            controller.update(
                time: 10.1,
                deltaTime: 0.1,
                availableWidth: 500
            ).isUserAttentionActive
        )

        controller.force(snapshot(.idle))
        let forced = controller.update(
            time: 10.2,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertFalse(forced.isUserAttentionActive)
        XCTAssertNotEqual(forced.microAction, .lookAround)

        // A force reset also clears the old eight-second cooldown.
        controller.ingestInteraction(.tap)
        XCTAssertTrue(
            controller.update(
                time: 10.3,
                deltaTime: 0.1,
                availableWidth: 500
            ).isUserAttentionActive
        )

        controller.forceWakePhaseForQA(.awake)
        let qaReset = controller.update(
            time: 10.4,
            deltaTime: 0.1,
            availableWidth: 500
        )
        XCTAssertFalse(qaReset.isUserAttentionActive)
        XCTAssertNotEqual(qaReset.microAction, .lookAround)
    }

    // MARK: - Fine-grained canon work poses

    func testStreamingReplySwitchesThinkingToRapidNotes() {
        let controller = MigiBehaviorController(seed: 91)
        controller.ingest(snapshot(.thinking))
        var frame = controller.update(
            time: 100, deltaTime: 0, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .type)
        XCTAssertEqual(frame.prop, .laptop)

        // 回复文本开始流出 → 转述速记,而不是内部推算
        controller.ingest(
            snapshot(.thinking, spokenText: "chunk", spokenRevision: 1)
        )
        frame = controller.update(
            time: 100.5, deltaTime: 0.5, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .rapidNotes)

        // 宽限期后仍无新片段 → 回到电脑打字
        frame = controller.update(
            time: 102.2, deltaTime: 1.7, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .type)
        XCTAssertEqual(frame.prop, .laptop)
    }

    func testSubAgentScoutPlaysOncePerMinuteThenCoordinates() {
        let controller = MigiBehaviorController(seed: 92)
        controller.ingest(snapshot(.tool, toolActionHint: .scout))
        var frame = controller.update(
            time: 100, deltaTime: 0, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .subAgentScout)

        // 完整原画播完后,子代理仍在刷屏 → 回落为多触手协调,不循环表演
        frame = controller.update(
            time: 102.5, deltaTime: 2.5, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .fineMotor)

        // 冷却期内的子代理记录不再触发离体侦察
        controller.ingest(snapshot(.tool, toolActionHint: .scout))
        frame = controller.update(
            time: 103, deltaTime: 0.5, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .fineMotor)

        // 冷却结束后 → 重新侦察—回归
        controller.ingest(snapshot(.thinking))
        frame = controller.update(
            time: 170, deltaTime: 1, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .type)
        controller.ingest(snapshot(.tool, toolActionHint: .scout))
        frame = controller.update(
            time: 170.5, deltaTime: 0.5, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .subAgentScout)
    }

    func testOneShotShowpieceNeverRenewedAtCompletionBoundary() {
        // 一次性手势(scout/compact)在“完成瞬间快照回切 thinking”的边界
        // 不得像 read/write 那样续期重播——冷却机制才拥有重播权。
        let controller = MigiBehaviorController(seed: 99)
        controller.ingest(snapshot(.tool, toolActionHint: .scout))
        var frame = controller.update(
            time: 100, deltaTime: 0, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .subAgentScout)

        // 完成边界:activity 回切 thinking,锁存本不应续期
        controller.ingest(snapshot(.thinking))
        frame = controller.update(
            time: 101.0, deltaTime: 1.0, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .subAgentScout)

        // 2.35s 手势窗口结束后立即回到 thinking 姿态,不再出现第二段循环
        frame = controller.update(
            time: 102.4, deltaTime: 1.4, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .type)
        XCTAssertEqual(frame.prop, .laptop)

        // 对照组:read 锁存在完成边界续期一次(语义保持原有设计)
        let readController = MigiBehaviorController(seed: 100)
        readController.ingest(snapshot(.tool, toolActionHint: .read))
        _ = readController.update(time: 100, deltaTime: 0, availableWidth: 500)
        readController.ingest(snapshot(.thinking))
        _ = readController.update(time: 101.0, deltaTime: 1.0, availableWidth: 500)
        let renewed = readController.update(
            time: 102.5, deltaTime: 1.5, availableWidth: 500
        )
        XCTAssertEqual(renewed.microAction, .read)
    }

    func testCompactionPlaysStoragePocketOnceThenCoordinates() {
        let controller = MigiBehaviorController(seed: 93)
        controller.ingest(snapshot(.tool, toolActionHint: .compact))
        var frame = controller.update(
            time: 50, deltaTime: 0, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .storagePocket)
        frame = controller.update(
            time: 52.24, deltaTime: 2.24, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .storagePocket)
        frame = controller.update(
            time: 52.30, deltaTime: 0.06, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .fineMotor)
    }

    func testVerifyRunPlaysOneLogicCountThenStreamsOutput() {
        let controller = MigiBehaviorController(seed: 94)
        controller.ingest(snapshot(.tool, toolActionHint: .verify))
        var frame = controller.update(
            time: 50, deltaTime: 0, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .logicCount)
        frame = controller.update(
            time: 51.49, deltaTime: 1.49, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .logicCount)
        frame = controller.update(
            time: 51.60, deltaTime: 0.11, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .rapidNotes)
    }

    func testSearchHintSustainsPalmObserver() {
        let controller = MigiBehaviorController(seed: 95)
        controller.ingest(snapshot(.tool, toolActionHint: .search))
        var frame = controller.update(
            time: 50, deltaTime: 0, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .palmObserver)
        frame = controller.update(
            time: 53.5, deltaTime: 3.5, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .palmObserver)
    }

    func testLongWaitingEscalatesToBoredSelfCheck() {
        let controller = MigiBehaviorController(seed: 96)
        controller.ingest(snapshot(.waiting))
        var frame = controller.update(
            time: 300, deltaTime: 0, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .checkPhone)
        XCTAssertEqual(frame.prop, .phone)

        frame = controller.update(
            time: 389.9, deltaTime: 89.9, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .checkPhone)

        frame = controller.update(
            time: 390.1, deltaTime: 0.2, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .inspectHand)
        XCTAssertEqual(frame.prop, .none)

        // 工作一旦恢复,等待计时立刻归零
        controller.ingest(snapshot(.thinking))
        frame = controller.update(
            time: 391, deltaTime: 0.9, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .type)
    }

    func testSustainedWorkEarnsOneStretchOnIdle() {
        let controller = MigiBehaviorController(seed: 97)
        controller.ingest(snapshot(.thinking))
        _ = controller.update(time: 100, deltaTime: 0, availableWidth: 500)
        controller.ingest(snapshot(.thinking))
        var frame = controller.update(
            time: 170, deltaTime: 70, availableWidth: 500
        )
        XCTAssertEqual(frame.activity, .thinking)

        controller.ingest(snapshot(.idle))
        _ = controller.update(time: 172, deltaTime: 2, availableWidth: 500)
        frame = controller.update(
            time: 179, deltaTime: 7, availableWidth: 500
        )
        XCTAssertEqual(frame.activity, .thinking)

        // 20 秒工作保持结束后进入待机:长工作赢得一次组织舒展
        frame = controller.update(
            time: 191.05, deltaTime: 12, availableWidth: 500
        )
        XCTAssertEqual(frame.activity, .idle)
        XCTAssertEqual(frame.microAction, .stretch)

        frame = controller.update(
            time: 192.6, deltaTime: 1.55, availableWidth: 500
        )
        XCTAssertEqual(frame.microAction, .none)

        // 冷却期内另一段长工作回到待机 → 不再重复伸展
        controller.ingest(snapshot(.thinking))
        _ = controller.update(time: 200, deltaTime: 7.4, availableWidth: 500)
        _ = controller.update(time: 280, deltaTime: 80, availableWidth: 500)
        controller.ingest(snapshot(.idle))
        _ = controller.update(time: 290, deltaTime: 10, availableWidth: 500)
        frame = controller.update(
            time: 320, deltaTime: 30, availableWidth: 500
        )
        XCTAssertEqual(frame.activity, .idle)
        XCTAssertNotEqual(frame.microAction, .stretch)
    }

    func testBriefWorkReturnsToIdleWithoutStretch() {
        let controller = MigiBehaviorController(seed: 98)
        controller.ingest(snapshot(.thinking))
        _ = controller.update(time: 100, deltaTime: 0, availableWidth: 500)
        _ = controller.update(time: 110, deltaTime: 10, availableWidth: 500)
        controller.ingest(snapshot(.idle))
        _ = controller.update(time: 112, deltaTime: 2, availableWidth: 500)
        let frame = controller.update(
            time: 131.1, deltaTime: 19, availableWidth: 500
        )
        XCTAssertEqual(frame.activity, .idle)
        XCTAssertEqual(frame.microAction, .none)
    }

    func testRareWorkBlinkComposesWithStablePoses() {
        let controller = MigiBehaviorController(seed: 130)
        controller.ingest(snapshot(.tool, toolActionHint: .write))

        var sawBlink = false
        var blinkWindows = 0
        var lastActive = false
        for step in 0..<200 {
            let time = 10.0 + Double(step) * 0.4
            let frame = controller.update(
                time: time, deltaTime: 0.4, availableWidth: 500
            )
            // 姿态不因眨眼而变:写工具全程 fineMotor
            XCTAssertEqual(frame.microAction, .fineMotor)
            XCTAssertEqual(frame.activity, .tool)
            if frame.blinkActive {
                sawBlink = true
            }
            if frame.blinkActive && !lastActive { blinkWindows += 1 }
            lastActive = frame.blinkActive
        }
        XCTAssertTrue(sawBlink)
        XCTAssertGreaterThanOrEqual(blinkWindows, 1)
        XCTAssertLessThanOrEqual(blinkWindows, 4)
    }

    // MARK: - Canon stare-back and sleep debt

    func testSustainedGazeEarnsAStareBackDuringIdle() {
        let controller = MigiBehaviorController(seed: 120)
        controller.ingest(snapshot(.idle))
        let facingBefore = controller.update(
            time: 10, deltaTime: 0, availableWidth: 500
        ).facing

        controller.ingestStareAttention(-facingBefore)
        let turned = controller.update(
            time: 10.2, deltaTime: 0.2, availableWidth: 500
        )
        XCTAssertEqual(turned.facing, -facingBefore)

        // 冷却期内的第二次注视不重复转身
        controller.ingestStareAttention(facingBefore)
        let cooling = controller.update(
            time: 10.4, deltaTime: 0.2, availableWidth: 500
        )
        XCTAssertEqual(cooling.facing, -facingBefore)

        // 视线移开释放保持;冷却结束后下一次注视仍可获得回视
        controller.ingestStareAttention(nil)
        _ = controller.update(time: 15, deltaTime: 4.6, availableWidth: 500)
        controller.ingestStareAttention(facingBefore)
        let restared = controller.update(
            time: 31.2, deltaTime: 16.2, availableWidth: 500
        )
        XCTAssertEqual(restared.facing, facingBefore)
    }

    func testStareIsIgnoredDuringWorkThreatAndPatrol() {
        let controller = MigiBehaviorController(seed: 121)
        controller.ingest(snapshot(.thinking))
        let initial = controller.update(
            time: 10, deltaTime: 0, availableWidth: 500
        )
        controller.ingestStareAttention(-initial.facing)
        let working = controller.update(
            time: 10.2, deltaTime: 0.2, availableWidth: 500
        )
        XCTAssertEqual(working.facing, initial.facing)

        let threatController = MigiBehaviorController(seed: 122)
        threatController.ingest(
            snapshot(.failed, failureDisposition: .credibleThreat)
        )
        let locked = threatController.update(
            time: 10, deltaTime: 0, availableWidth: 500
        )
        threatController.ingestStareAttention(-locked.facing)
        let threatened = threatController.update(
            time: 10.2, deltaTime: 0.2, availableWidth: 500
        )
        XCTAssertEqual(threatened.facing, locked.facing)
    }

    func testSleepDebtAccumulatesShortensBedtimeAndExtendsSleep() {
        let controller = MigiBehaviorController(
            seed: 123,
            deepSleepDelay: 100,
            minimumDeepSleepDuration: 20
        )
        controller.restoreFatigue(1)

        // 满债时:30min 阈值的 30% → 100s 变为 30s
        controller.ingest(snapshot(.idle))
        var frame = controller.update(
            time: 0, deltaTime: 0, availableWidth: 500
        )
        XCTAssertEqual(frame.wakePhase, .awake)
        frame = controller.update(
            time: 29.9, deltaTime: 29.9, availableWidth: 500
        )
        XCTAssertEqual(frame.wakePhase, .awake)
        frame = controller.update(
            time: 30.1, deltaTime: 0.2, availableWidth: 500
        )
        XCTAssertEqual(frame.wakePhase, .deepSleep)

        // 满债的最小睡眠从 20s 拉长到 60s:工作信号在 50s 时仍叫不醒
        controller.ingest(snapshot(.thinking))
        frame = controller.update(
            time: 80.0, deltaTime: 49.9, availableWidth: 500
        )
        XCTAssertEqual(frame.wakePhase, .deepSleep)
        frame = controller.update(
            time: 90.5, deltaTime: 10.5, availableWidth: 500
        )
        XCTAssertNotEqual(frame.wakePhase, .deepSleep)

        // 睡眠实际偿还了债务:fatigue 应明显下降且能量回升空间恢复
        XCTAssertLessThan(frame.fatigue, 1)
    }

    func testZeroDebtKeepsAuthoredSleepTimings() {
        let controller = MigiBehaviorController(
            seed: 124,
            deepSleepDelay: 100,
            minimumDeepSleepDuration: 20
        )
        controller.ingest(snapshot(.idle))
        var frame = controller.update(
            time: 0, deltaTime: 0, availableWidth: 500
        )
        XCTAssertEqual(frame.wakePhase, .awake)
        frame = controller.update(
            time: 99.9, deltaTime: 99.9, availableWidth: 500
        )
        XCTAssertEqual(frame.wakePhase, .awake)
        frame = controller.update(
            time: 100.1, deltaTime: 0.2, availableWidth: 500
        )
        XCTAssertEqual(frame.wakePhase, .deepSleep)

        controller.ingest(snapshot(.thinking))
        frame = controller.update(
            time: 119.9, deltaTime: 19.8, availableWidth: 500
        )
        XCTAssertEqual(frame.wakePhase, .deepSleep)
        frame = controller.update(
            time: 120.4, deltaTime: 0.5, availableWidth: 500
        )
        XCTAssertNotEqual(frame.wakePhase, .deepSleep)
    }

    func testFatigueDampsIdleEnergyButNeverBelowCanonFloor() {
        let rested = MigiBehaviorController(seed: 125)
        rested.ingest(snapshot(.tool, toolActionHint: .write))
        _ = rested.update(time: 10, deltaTime: 10, availableWidth: 500)
        let restedFrame = rested.update(
            time: 10.5, deltaTime: 0.5, availableWidth: 500
        )

        let tired = MigiBehaviorController(seed: 125)
        tired.restoreFatigue(1)
        tired.ingest(snapshot(.tool, toolActionHint: .write))
        _ = tired.update(time: 10, deltaTime: 10, availableWidth: 500)
        let tiredFrame = tired.update(
            time: 10.5, deltaTime: 0.5, availableWidth: 500
        )

        XCTAssertLessThan(tiredFrame.bodyEnergy, restedFrame.bodyEnergy)
        XCTAssertGreaterThan(tiredFrame.bodyEnergy, 0)
    }

    func testSleepPhasesNeverBlink() {
        let controller = MigiBehaviorController(
            seed: 131,
            deepSleepDelay: 5,
            minimumDeepSleepDuration: 20
        )
        controller.ingest(snapshot(.idle))
        _ = controller.update(time: 0, deltaTime: 0, availableWidth: 500)
        _ = controller.update(time: 5.2, deltaTime: 5.2, availableWidth: 500)
        var anyBlink = false
        for step in 0..<100 {
            let frame = controller.update(
                time: 6.0 + Double(step) * 0.4,
                deltaTime: 0.4,
                availableWidth: 500
            )
            if frame.blinkActive || frame.microAction == .blink {
                anyBlink = true
            }
        }
        XCTAssertFalse(anyBlink)
    }

    func testPlaybackRateTracksRealLogThroughput() {
        // 高速流式输出:速率贴近上限 1.4x
        let fast = MigiBehaviorController(seed: 140)
        fast.ingest(
            snapshot(
                .thinking,
                sourcePath: "/tmp/live/rollout.jsonl",
                logThroughput: 40_000
            )
        )
        let fastFrame = fast.update(time: 10, deltaTime: 0, availableWidth: 500)
        XCTAssertEqual(fastFrame.clipPlaybackScale, 1.4, accuracy: 0.01)
        // thinking 姿态(type)实际应用倍率
        XCTAssertEqual(fastFrame.clipPlaybackRate, 1.4, accuracy: 0.02)

        // 静默:慢速思忖笔画 0.75x
        let quiet = MigiBehaviorController(seed: 141)
        quiet.ingest(
            snapshot(.thinking, sourcePath: "/tmp/live/rollout.jsonl", logThroughput: 0)
        )
        let quietFrame = quiet.update(time: 10, deltaTime: 0, availableWidth: 500)
        XCTAssertEqual(quietFrame.clipPlaybackScale, 0.75, accuracy: 0.01)

        // 无真实来源(demo/QA 路径)永远保持原速
        let demo = MigiBehaviorController(seed: 142)
        demo.ingest(snapshot(.thinking, logThroughput: 40_000))
        let demoFrame = demo.update(time: 10, deltaTime: 0, availableWidth: 500)
        XCTAssertEqual(demoFrame.clipPlaybackScale, 1)
        XCTAssertEqual(demoFrame.clipPlaybackRate, 1)

        // 闲置阅读不吃倍率
        let idleReader = MigiBehaviorController(seed: 143)
        idleReader.ingest(
            snapshot(.idle, sourcePath: "/tmp/x", logThroughput: 40_000)
        )
        let idleFrame = idleReader.update(time: 10, deltaTime: 0, availableWidth: 500)
        XCTAssertEqual(idleFrame.clipPlaybackScale, 1)
    }

    private func snapshot(
        _ activity: CodexActivity,
        toolActionHint: CodexToolActionHint = .none,
        sourcePath: String? = nil,
        sourceAgent: MonitoredAgent? = nil,
        monitoringGeneration: UInt64 = 0,
        latestNovelTool: ToolNoveltyEvent? = nil,
        activeAgents: Set<MonitoredAgent> = [],
        failureDisposition: CodexFailureDisposition = .none,
        relationshipProfile: MigiRelationshipProfile = .init(),
        spokenText: String? = nil,
        spokenRevision: UInt64? = nil,
        logThroughput: Double = 0
    ) -> CodexActivitySnapshot {
        CodexActivitySnapshot(
            activity: activity,
            detail: "test",
            observedAt: Date(),
            sourcePath: sourcePath,
            toolActionHint: toolActionHint,
            sourceAgent: sourceAgent,
            monitoringGeneration: monitoringGeneration,
            latestNovelTool: latestNovelTool,
            activeAgents: activeAgents,
            failureDisposition: failureDisposition,
            relationshipProfile: relationshipProfile,
            spokenText: spokenText,
            spokenRevision: spokenRevision,
            logThroughput: logThroughput
        )
    }

    private func novelTool(
        sequence: UInt64,
        agent: MonitoredAgent = .codex,
        sourcePath: String = "/tmp/codex/rollout.jsonl",
        hint: CodexToolActionHint = .none,
        observedAt: Date = Date()
    ) -> ToolNoveltyEvent {
        ToolNoveltyEvent(
            sequence: sequence,
            agent: agent,
            canonicalName: "mcp__novel__\(sequence)",
            observedAt: observedAt,
            sourcePath: sourcePath,
            toolActionHint: hint
        )
    }
}
