import AppKit
import Foundation

public enum MigiProp: Equatable {
    case none
    case phone
    case book
    case laptop
}

public enum MigiMicroAction: Equatable, Hashable {
    case none
    case blink
    case inspectHand
    case palmObserver
    case sharpenTip
    case protectiveShield
    case detachedScoutReturn
    case rapidNotes
    case fineMotor
    case organDrift
    case logicCount
    case signalSampling
    case storagePocket
    case recoveryCare
    case calmDiagnosis
    case read
    case checkPhone
    case type
    case stretch
    case lookAround
    case dormant
}

public enum MigiWakePhase: Equatable, Sendable {
    case awake
    case deepSleep
    case dreamDisturbance
    case lookAround
}

public enum MigiScoutPhase: Equatable, Sendable {
    case anchored
    case outbound
    case returning
}

public enum MigiInteraction: Equatable, Sendable {
    case tap
}

enum MigiAnimationTiming {
    /// Keeps the final wake pose visible while the renderer dissolves into the
    /// work pose. Tool latches include this interval so their canonical
    /// gesture still receives its complete opaque hold afterward.
    static let wakeHandoffDuration: TimeInterval = 0.42

    /// The authored six-frame turn totals 1.01 seconds. A detached scout changes facing
    /// immediately so the renderer can start that row, but translation waits
    /// until the body has planted and completed the turn.
    static let patrolTurnDuration: TimeInterval = 1.01
}

public struct MigiBehaviorFrame {
    public let activity: CodexActivity
    public let prop: MigiProp
    public let microAction: MigiMicroAction
    /// The authoritative phase of Migi's deep-sleep and wake sequence.
    public let wakePhase: MigiWakePhase
    /// Normalized progress through the complete dream-and-look wake sequence.
    public let wakeProgress: CGFloat
    /// Horizontal orientation. `-1` looks left and `1` looks right.
    public let facing: CGFloat
    /// Whether short detached-scout locomotion is active. Translation pauses while the
    /// authored planted turn finishes.
    public let isMoving: Bool
    /// Offset from the host view's preferred resting point.
    public let worldOffset: CGPoint
    /// Normalized amount of deformation and secondary motion requested by the renderer.
    public let bodyEnergy: CGFloat
    /// Normalized attention level requested by the renderer.
    public let focus: CGFloat
    /// Failure metadata is separate from `.failed` so a routine tool error
    /// cannot be rendered as a physical survival threat.
    public let failureDisposition: CodexFailureDisposition
    /// A persistent, deliberately slow relationship signal for restrained
    /// long-term behavior changes.
    public let relationshipStage: MigiRelationshipStage
    public let scoutPhase: MigiScoutPhase
    /// A short, relationship-scaled acknowledgement of direct user presence.
    ///
    /// Renderers may use this to tighten eye tracking without replacing the
    /// semantic work, waiting, or diagnostic pose already on screen.
    public let isUserAttentionActive: Bool

    /// Compatibility surface for renderers that only distinguish deep sleep.
    public var isDeepSleeping: Bool {
        wakePhase == .deepSleep
    }

    /// Complete sleep and the entire authored wake sequence ignore pointer motion.
    public var suppressesPointerGaze: Bool {
        wakePhase != .awake
    }

    /// Movement is reserved for Migi's short, canon-derived detached scout.
    public var isDetachedScout: Bool {
        isMoving
    }

    /// Dream disturbance advances the dormant tissue clip slightly faster.
    public var clipPlaybackRate: Double {
        wakePhase == .dreamDisturbance ? 1.25 : 1
    }

    public init(
        activity: CodexActivity,
        prop: MigiProp,
        microAction: MigiMicroAction,
        wakePhase: MigiWakePhase = .awake,
        wakeProgress: CGFloat = 1,
        facing: CGFloat,
        isMoving: Bool,
        worldOffset: CGPoint,
        bodyEnergy: CGFloat,
        focus: CGFloat,
        failureDisposition: CodexFailureDisposition = .none,
        relationshipStage: MigiRelationshipStage = .cautious,
        scoutPhase: MigiScoutPhase = .anchored,
        isUserAttentionActive: Bool = false
    ) {
        self.activity = activity
        self.prop = prop
        self.microAction = microAction
        self.wakePhase = wakePhase
        self.wakeProgress = min(max(wakeProgress, 0), 1)
        self.facing = facing < 0 ? -1 : 1
        self.isMoving = isMoving
        self.worldOffset = worldOffset
        self.bodyEnergy = min(max(bodyEnergy, 0), 1)
        self.focus = min(max(focus, 0), 1)
        self.failureDisposition = failureDisposition
        self.relationshipStage = relationshipStage
        self.scoutPhase = scoutPhase
        self.isUserAttentionActive = isUserAttentionActive
    }
}

/// Turns terse Codex activity observations into long-lived, organic character behavior.
///
/// The controller deliberately owns no timers. Callers drive it from their render loop,
/// making both runtime behavior and seeded tests deterministic.
public final class MigiBehaviorController {
    private static let minimumWorkHold: TimeInterval = 20
    private static let failedReactionDuration: TimeInterval = 3.2
    private static let protectiveShieldDuration: TimeInterval = 0.9
    private static let readActionHoldDuration: TimeInterval = 1.8
    private static let writeActionHoldDuration: TimeInterval = 2.4
    private static let novelToolGestureDuration: TimeInterval = 0.96 * 2
    private static let novelToolCooldown: TimeInterval = 60
    private static let novelToolTTL: TimeInterval = 12
    private static let peerSignalEvaluationDuration: TimeInterval = 0.28 * 4
    private static let peerSignalEvaluationCooldown: TimeInterval = 12
    private static let recoveryCareDuration: TimeInterval = 0.9 * 4
    private static let interactionCooldown: TimeInterval = 8
    private static let interactionLookAroundDuration: TimeInterval = 1.04
    private static let idleActionSpecs: [MigiIdleActionSpec] = [
        .init(
            action: .read,
            prop: .book,
            weight: 18,
            duration: 8...14,
            cooldown: 90...150,
            family: .study
        ),
        .init(
            action: .checkPhone,
            prop: .phone,
            weight: 2,
            duration: 6...11,
            cooldown: 180...300,
            family: .study
        ),
        .init(
            action: .palmObserver,
            prop: .none,
            weight: 9,
            duration: 1.55...2.10,
            cooldown: 70...120,
            family: .hand
        ),
        .init(
            action: .signalSampling,
            prop: .none,
            weight: 16,
            duration: 1.8...2.8,
            cooldown: 60...105,
            family: .sensory
        ),
        .init(
            action: .stretch,
            prop: .none,
            weight: 3,
            duration: 1.20...1.65,
            cooldown: 90...150,
            family: .body
        ),
        .init(
            action: .dormant,
            prop: .none,
            weight: 5,
            duration: 6...10,
            cooldown: 180...300,
            family: .rest
        ),
        .init(
            action: .rapidNotes,
            prop: .none,
            weight: 4,
            duration: 5.2...8,
            cooldown: 120...210,
            family: .study
        ),
        .init(
            action: .fineMotor,
            prop: .none,
            weight: 17,
            duration: 3.4...5.2,
            cooldown: 75...130,
            family: .hand
        ),
        .init(
            action: .organDrift,
            prop: .none,
            weight: 10,
            duration: 1.35...1.85,
            cooldown: 180...300,
            family: .body
        ),
        .init(
            action: .logicCount,
            prop: .none,
            weight: 2,
            duration: 1.25...1.75,
            cooldown: 240...420,
            family: .hand
        ),
        .init(
            action: .storagePocket,
            prop: .none,
            weight: 11,
            duration: 2.8...4.4,
            cooldown: 120...210,
            family: .hand
        ),
        .init(
            action: .recoveryCare,
            prop: .none,
            weight: 9,
            duration: 3.2...5.2,
            cooldown: 150...240,
            family: .care
        )
    ]

    private var random: MigiSeededRandom
    private let deepSleepDelay: TimeInterval
    private let minimumDeepSleepDuration: TimeInterval
    private let dreamDisturbanceDuration: TimeInterval
    private let wakeDuration: TimeInterval
    private let scoutInterval: ClosedRange<TimeInterval>
    private let scoutDetachedDuration: ClosedRange<TimeInterval>
    private var latestSnapshot: CodexActivitySnapshot?
    private var snapshotGeneration: UInt64 = 0
    private var handledSnapshotGeneration: UInt64 = 0
    private var displayedActivity: CodexActivity
    private var recoveryActivity: CodexActivity

    private var clockIsInitialized = false
    private var workHoldUntil: TimeInterval = 0
    private var failureUntil: TimeInterval = 0
    private var failureIsLatched = false
    private var latchedFailureDisposition: CodexFailureDisposition = .none
    private var credibleThreatPresentationStartedAt: TimeInterval?
    private var recoveryCareUntil: TimeInterval = 0
    private var failureRecoveryWasScheduled = false
    private var latchedToolAction: CodexToolActionHint = .none
    private var toolActionUntil: TimeInterval = 0
    private var toolObservationIsActive = false
    private var consumedNovelToolSequences: Set<UInt64> = []
    private var handledNoveltySnapshotGeneration: UInt64 = 0
    private var novelToolActionUntil: TimeInterval = 0
    private var novelToolCooldownUntil: TimeInterval = 0
    private var handledPeerSnapshotGeneration: UInt64 = 0
    private var observedActiveAgents: Set<MonitoredAgent> = []
    private var peerSignalEvaluationUntil: TimeInterval = 0
    private var peerSignalEvaluationCooldownUntil: TimeInterval = 0
    private var snapshotIngestedAt = Date.distantPast

    private var idleSince: TimeInterval?
    private var deepSleepStartedAt: TimeInterval?
    private var wakePhase: MigiWakePhase = .awake
    private var wakeSequenceStartedAt: TimeInterval?
    private var pendingQAWakePhaseAnchor: MigiWakePhase?

    private var idleAction: MigiMicroAction = .none
    private var idleActionProp: MigiProp = .none
    private var idleActionUntil: TimeInterval = 0
    private var nextIdleActionAt: TimeInterval = 0
    private var idleSettleUntil: TimeInterval = 0
    private var idleActionCooldownUntil: [MigiMicroAction: TimeInterval] = [:]
    private var lastIdleActionFamily: MigiIdleActionFamily?
    private var blinkUntil: TimeInterval = 0
    private var nextBlinkAt: TimeInterval = 0
    private var wasIdle = false

    private var positionX: CGFloat = 0
    private var movementTargetX: CGFloat = 0
    private var movementSpeed: CGFloat = 0
    private var isMoving = false
    private var translationBeginsAt: TimeInterval = 0
    private var stopUntil: TimeInterval = 0
    private var scoutPhase: MigiScoutPhase = .anchored
    private var scoutMustReturnAt: TimeInterval = 0
    private var nextScoutAt: TimeInterval = 0
    private var scoutNeedsScheduling = false
    private var nextPatrolDirection: CGFloat
    private var facing: CGFloat
    private var anchoredAttentionIdentity: MigiAnchoredAttentionIdentity?
    private var nextAnchoredFacingChangeAt: TimeInterval = 0

    private var pendingInteractionGeneration: UInt64 = 0
    private var handledInteractionGeneration: UInt64 = 0
    private var nextInteractionAllowedAt: TimeInterval = 0
    private var userAttentionUntil: TimeInterval = 0
    private var interactionLookAroundUntil: TimeInterval = 0
    private var scoutInteractionPauseUntil: TimeInterval = 0
    private var scoutInteractionReturnPending = false
    private var scoutInteractionHoldOffset: CGPoint = .zero
    private var scoutReturnVerticalHandoffStartedAt: TimeInterval?
    private var lastWorldOffset: CGPoint = .zero

    private var energy: CGFloat = 0.32
    private var focus: CGFloat = 0.3

    /// A fixed seed gives exactly the same behavior choices for tests and recordings.
    public init(
        seed: UInt64 = 0x4D49_4749_4144_5631,
        initialActivity: CodexActivity = .idle,
        initialFacing requestedInitialFacing: CGFloat? = nil,
        deepSleepDelay: TimeInterval = 30 * 60,
        minimumDeepSleepDuration: TimeInterval = 20,
        dreamDisturbanceDuration: TimeInterval = 1.2,
        wakeDuration: TimeInterval = 1.6,
        scoutInterval: ClosedRange<TimeInterval> = 45...90,
        scoutDetachedDuration: ClosedRange<TimeInterval> = 5.5...8
    ) {
        var seededRandom = MigiSeededRandom(seed: seed)
        let randomInitialFacing: CGFloat = seededRandom.nextBool() ? -1 : 1
        let initialFacing = requestedInitialFacing.map { $0 < 0 ? CGFloat(-1) : CGFloat(1) }
            ?? randomInitialFacing

        random = seededRandom
        self.deepSleepDelay = max(
            deepSleepDelay.isFinite ? deepSleepDelay : 30 * 60,
            0
        )
        self.minimumDeepSleepDuration = max(
            minimumDeepSleepDuration.isFinite ? minimumDeepSleepDuration : 20,
            0
        )
        self.dreamDisturbanceDuration = max(
            dreamDisturbanceDuration.isFinite ? dreamDisturbanceDuration : 1.2,
            0
        )
        self.wakeDuration = max(
            wakeDuration.isFinite ? wakeDuration : 1.6,
            0
        )
        self.scoutInterval = Self.sanitizedRange(
            scoutInterval,
            fallback: 45...90
        )
        self.scoutDetachedDuration = Self.sanitizedRange(
            scoutDetachedDuration,
            fallback: 5.5...8
        )
        displayedActivity = initialActivity
        recoveryActivity = initialActivity == .failed ? .idle : initialActivity
        facing = initialFacing
        nextPatrolDirection = -initialFacing
    }

    /// Supplies the most recent Codex observation. State transitions are applied by
    /// `update`, where a monotonic animation clock is available.
    public func ingest(_ snapshot: CodexActivitySnapshot) {
        latestSnapshot = snapshot
        snapshotIngestedAt = Date()
        snapshotGeneration &+= 1
    }

    /// Queues a direct user interaction for consumption by the next `update`.
    ///
    /// The render loop's monotonic clock, rather than wall time or AppKit event
    /// time, owns the acknowledgement duration and cooldown. Sleep, authored
    /// wake motion, and credible-threat defense are non-interruptible.
    public func ingestInteraction(_ interaction: MigiInteraction) {
        guard interaction == .tap,
              wakePhase == .awake,
              !hasCredibleThreatObservation
        else {
            return
        }
        pendingInteractionGeneration &+= 1
    }

    /// Used by the explicit visual demo/QA route. It changes presentation state
    /// immediately and clears normal hysteresis without affecting patrol position.
    public func force(_ snapshot: CodexActivitySnapshot) {
        latestSnapshot = snapshot
        snapshotGeneration &+= 1
        handledSnapshotGeneration = snapshotGeneration
        displayedActivity = snapshot.activity
        recoveryActivity = snapshot.activity == .failed ? .idle : snapshot.activity
        workHoldUntil = 0
        failureUntil = 0
        failureIsLatched = false
        latchedFailureDisposition = .none
        credibleThreatPresentationStartedAt = nil
        recoveryCareUntil = 0
        failureRecoveryWasScheduled = false
        latchedToolAction = .none
        toolActionUntil = 0
        toolObservationIsActive = false
        consumedNovelToolSequences.removeAll(keepingCapacity: true)
        handledNoveltySnapshotGeneration = snapshotGeneration
        novelToolActionUntil = 0
        novelToolCooldownUntil = 0
        handledPeerSnapshotGeneration = snapshotGeneration
        observedActiveAgents = snapshot.activeAgents
        peerSignalEvaluationUntil = 0
        peerSignalEvaluationCooldownUntil = 0
        anchoredAttentionIdentity = nil
        nextAnchoredFacingChangeAt = 0
        scoutPhase = .anchored
        scoutMustReturnAt = 0
        nextScoutAt = 0
        scoutNeedsScheduling = true
        positionX = 0
        movementTargetX = 0
        isMoving = false
        translationBeginsAt = 0
        snapshotIngestedAt = .distantPast
        idleSince = nil
        deepSleepStartedAt = nil
        wakePhase = .awake
        wakeSequenceStartedAt = nil
        pendingQAWakePhaseAnchor = nil
        resetInteractionState()
        clearIdleBehavior()
        wasIdle = false
    }

    /// Stages a deterministic wake phase for visual QA. The next `update`
    /// anchors that phase to its supplied monotonic clock.
    public func forceWakePhaseForQA(_ phase: MigiWakePhase) {
        wakePhase = phase
        wakeSequenceStartedAt = nil
        pendingQAWakePhaseAnchor = phase
        idleSince = phase == .deepSleep ? 0 : nil
        deepSleepStartedAt = nil
        clearIdleBehavior()
        wasIdle = false
        isMoving = false
        scoutPhase = .anchored
        scoutMustReturnAt = 0
        positionX = 0
        movementTargetX = 0
        resetInteractionState()
    }

    public func update(
        time: TimeInterval,
        deltaTime: TimeInterval,
        availableWidth: CGFloat
    ) -> MigiBehaviorFrame {
        let safeTime = time.isFinite ? time : 0
        let safeDelta = min(max(deltaTime.isFinite ? deltaTime : 0, 0), 0.25)

        if !clockIsInitialized {
            initializeClock(at: safeTime)
        }
        if scoutNeedsScheduling {
            nextScoutAt = safeTime + random.next(in: scoutInterval)
            stopUntil = nextScoutAt
            scoutNeedsScheduling = false
        }

        anchorQAWakePhaseIfNeeded(at: safeTime)
        let activity = resolveActivity(at: safeTime)
        updateSleepState(for: activity, at: safeTime)
        updateToolActionLatch(at: safeTime)
        updateNovelToolLatch(for: activity, at: safeTime)
        updatePeerSignalEvaluation(for: activity, at: safeTime)
        consumePendingInteraction(for: activity, at: safeTime)
        var behavior = resolveMicroBehavior(for: activity, at: safeTime)
        let wakeProgress = wakeProgress(at: safeTime)
        let offset = updatePatrol(
            for: activity,
            action: behavior.action,
            prop: behavior.prop,
            wakePhase: wakePhase,
            at: safeTime,
            deltaTime: safeDelta,
            availableWidth: max(availableWidth, 0)
        )
        lastWorldOffset = offset
        if activity == .idle,
           scoutPhase == .returning,
           !isScoutInteractionPaused(at: safeTime)
        {
            behavior = (.detachedScoutReturn, .none)
        } else if behavior.action == .detachedScoutReturn {
            behavior = (.none, .none)
        }

        let targets = behaviorTargets(
            activity: activity,
            action: behavior.action,
            isMoving: isMoving,
            wakePhase: wakePhase,
            at: safeTime
        )
        if wakePhase == .dreamDisturbance || wakePhase == .lookAround {
            // Wake targets are already continuous curves. Applying another
            // response filter here would flatten the short dream phase and
            // obscure its deliberate 0.08 -> 0.20 energy rise.
            energy = targets.energy
            focus = targets.focus
        } else {
            energy = approach(energy, targets.energy, deltaTime: safeDelta, response: 4.2)
            focus = approach(focus, targets.focus, deltaTime: safeDelta, response: 5.5)
        }

        return MigiBehaviorFrame(
            activity: activity,
            prop: behavior.prop,
            microAction: behavior.action,
            wakePhase: wakePhase,
            wakeProgress: wakeProgress,
            facing: facing,
            isMoving: isMoving,
            worldOffset: offset,
            bodyEnergy: energy,
            focus: focus,
            failureDisposition: activity == .failed
                ? normalizedFailureDisposition
                : .none,
            relationshipStage: relationshipStage,
            scoutPhase: scoutPhase,
            isUserAttentionActive:
                wakePhase == .awake
                    && !isCredibleThreat(activity)
                    && safeTime < userAttentionUntil
        )
    }

    private func initializeClock(at time: TimeInterval) {
        clockIsInitialized = true
        nextIdleActionAt = time + random.next(in: 8...16)
        nextBlinkAt = time + random.next(in: 3.5...8.5)
        nextScoutAt = time + random.next(in: scoutInterval)
        stopUntil = nextScoutAt
    }

    private var relationshipStage: MigiRelationshipStage {
        latestSnapshot?.relationshipProfile.stage ?? .cautious
    }

    private var hasCredibleThreatObservation: Bool {
        if failureIsLatched,
           latchedFailureDisposition == .credibleThreat
        {
            return true
        }
        guard let snapshot = latestSnapshot else {
            return false
        }
        return snapshot.activity == .failed
            && snapshot.failureDisposition == .credibleThreat
    }

    private var normalizedFailureDisposition: CodexFailureDisposition {
        let disposition: CodexFailureDisposition
        if failureIsLatched, latchedFailureDisposition != .none {
            disposition = latchedFailureDisposition
        } else {
            disposition = latestSnapshot?.failureDisposition ?? .none
        }
        return disposition == .none ? .routine : disposition
    }

    private func isCredibleThreat(_ activity: CodexActivity) -> Bool {
        activity == .failed
            && normalizedFailureDisposition == .credibleThreat
    }

    private func attentionDuration(
        for stage: MigiRelationshipStage
    ) -> TimeInterval {
        switch stage {
        case .cautious:
            return 0.45
        case .cooperative:
            return 0.70
        case .protective:
            return 0.90
        }
    }

    private func consumePendingInteraction(
        for activity: CodexActivity,
        at time: TimeInterval
    ) {
        guard handledInteractionGeneration != pendingInteractionGeneration else {
            return
        }
        handledInteractionGeneration = pendingInteractionGeneration

        guard wakePhase == .awake,
              !isCredibleThreat(activity),
              time >= nextInteractionAllowedAt
        else {
            return
        }

        nextInteractionAllowedAt = time + Self.interactionCooldown
        userAttentionUntil =
            time + attentionDuration(for: relationshipStage)

        guard activity == .idle else {
            return
        }

        interactionLookAroundUntil =
            time + Self.interactionLookAroundDuration

        if scoutPhase != .anchored || abs(positionX) > 0.001 {
            // Freeze exactly where the detached body was observed. Returning
            // begins only after the authored acknowledgement has completed.
            scoutInteractionPauseUntil = interactionLookAroundUntil
            scoutInteractionReturnPending = true
            scoutInteractionHoldOffset = lastWorldOffset
            isMoving = false
            translationBeginsAt = 0
            return
        }

        clearIdleBehavior()
        idleSettleUntil = max(
            idleSettleUntil,
            interactionLookAroundUntil + 0.6
        )
        nextIdleActionAt = max(
            nextIdleActionAt,
            interactionLookAroundUntil + random.next(in: 8...16)
        )
    }

    private func resetInteractionState() {
        pendingInteractionGeneration = 0
        handledInteractionGeneration = 0
        nextInteractionAllowedAt = 0
        userAttentionUntil = 0
        interactionLookAroundUntil = 0
        scoutInteractionPauseUntil = 0
        scoutInteractionReturnPending = false
        scoutInteractionHoldOffset = .zero
        scoutReturnVerticalHandoffStartedAt = nil
        lastWorldOffset = .zero
    }

    private func isScoutInteractionPaused(at time: TimeInterval) -> Bool {
        scoutInteractionReturnPending
            && time < scoutInteractionPauseUntil
    }

    private func anchorQAWakePhaseIfNeeded(at time: TimeInterval) {
        guard let phase = pendingQAWakePhaseAnchor else {
            return
        }
        pendingQAWakePhaseAnchor = nil

        switch phase {
        case .awake:
            wakeSequenceStartedAt = nil
            deepSleepStartedAt = nil
        case .deepSleep:
            wakeSequenceStartedAt = nil
            deepSleepStartedAt = time
        case .dreamDisturbance:
            deepSleepStartedAt = nil
            wakeSequenceStartedAt = time
        case .lookAround:
            deepSleepStartedAt = nil
            wakeSequenceStartedAt = time - dreamDisturbanceDuration
        }
    }

    private func updateSleepState(
        for activity: CodexActivity,
        at time: TimeInterval
    ) {
        if wakePhase == .deepSleep {
            idleSince = nil
            if deepSleepStartedAt == nil {
                deepSleepStartedAt = time
            }

            switch activity {
            case .idle, .waiting, .review:
                // Passive states never wake Migi. In particular, an approval
                // request cannot turn an involuntary sleep cycle into hours of
                // phone tapping.
                return
            case .thinking, .tool, .failed:
                let sleptFor = time - (deepSleepStartedAt ?? time)
                guard sleptFor >= minimumDeepSleepDuration else {
                    return
                }
                clearIdleBehavior()
                wasIdle = false
                startWakeSequence(at: time)
                return
            }
        }

        // Once waking has begun, an approval request remains a semantic
        // interrupt. Failures do not bypass the authored wake sequence: even a
        // credible threat cannot give a completely sleeping organ perception.
        if activity == .waiting {
            idleSince = nil
            deepSleepStartedAt = nil
            wakePhase = .awake
            wakeSequenceStartedAt = nil
            return
        }

        if wakePhase == .dreamDisturbance || wakePhase == .lookAround {
            idleSince = nil
            advanceWakeSequence(at: time)
            return
        }

        if activity == .idle {
            if idleSince == nil {
                idleSince = time
            }

            if wakePhase == .awake,
               let idleSince,
                time - idleSince >= deepSleepDelay
            {
                wakePhase = .deepSleep
                deepSleepStartedAt = time
                wakeSequenceStartedAt = nil
                clearIdleBehavior()
            }
            return
        }

        idleSince = nil
    }

    private func startWakeSequence(at time: TimeInterval) {
        deepSleepStartedAt = nil
        wakeSequenceStartedAt = time
        wakePhase = .dreamDisturbance
        advanceWakeSequence(at: time)
    }

    private func advanceWakeSequence(at time: TimeInterval) {
        guard let wakeSequenceStartedAt else {
            wakePhase = .awake
            return
        }

        let elapsed = max(time - wakeSequenceStartedAt, 0)
        // Decimal render/test clocks such as 13.2 - 12 can land a few ulps
        // below 1.2. Treat that representation noise as the exact boundary.
        let boundaryTolerance: TimeInterval = 1e-9
        if elapsed + boundaryTolerance < dreamDisturbanceDuration {
            wakePhase = .dreamDisturbance
        } else if elapsed + boundaryTolerance
                    < dreamDisturbanceDuration + wakeDuration
        {
            wakePhase = .lookAround
        } else {
            wakePhase = .awake
            self.wakeSequenceStartedAt = nil
        }
    }

    private func wakeProgress(at time: TimeInterval) -> CGFloat {
        switch wakePhase {
        case .awake:
            return 1
        case .deepSleep:
            return 0
        case .dreamDisturbance, .lookAround:
            let totalDuration = dreamDisturbanceDuration + wakeDuration
            guard totalDuration > 0, let wakeSequenceStartedAt else {
                return wakePhase == .lookAround ? 1 : 0
            }
            return CGFloat(
                min(max((time - wakeSequenceStartedAt) / totalDuration, 0), 1)
            )
        }
    }

    private func phaseProgress(at time: TimeInterval) -> CGFloat {
        guard let wakeSequenceStartedAt else {
            return wakePhase == .awake ? 1 : 0
        }
        switch wakePhase {
        case .awake:
            return 1
        case .deepSleep:
            return 0
        case .dreamDisturbance:
            guard dreamDisturbanceDuration > 0 else { return 1 }
            return CGFloat(
                min(max((time - wakeSequenceStartedAt) / dreamDisturbanceDuration, 0), 1)
            )
        case .lookAround:
            guard wakeDuration > 0 else { return 1 }
            let elapsed = time - wakeSequenceStartedAt - dreamDisturbanceDuration
            return CGFloat(min(max(elapsed / wakeDuration, 0), 1))
        }
    }

    private func remainingWakeDuration(at time: TimeInterval) -> TimeInterval {
        guard wakePhase == .dreamDisturbance || wakePhase == .lookAround,
              let wakeSequenceStartedAt
        else {
            return 0
        }
        let end = wakeSequenceStartedAt + dreamDisturbanceDuration + wakeDuration
        return max(end - time, 0) + MigiAnimationTiming.wakeHandoffDuration
    }

    private func remainingBehaviorDeferral(at time: TimeInterval) -> TimeInterval {
        if wakePhase == .deepSleep {
            let sleptFor = time - (deepSleepStartedAt ?? time)
            return max(minimumDeepSleepDuration - sleptFor, 0)
                + dreamDisturbanceDuration
                + wakeDuration
                + MigiAnimationTiming.wakeHandoffDuration
        }
        return remainingWakeDuration(at: time)
    }

    private func updateToolActionLatch(at time: TimeInterval) {
        if handledSnapshotGeneration != snapshotGeneration {
            handledSnapshotGeneration = snapshotGeneration
            if let snapshot = latestSnapshot, snapshot.activity == .tool {
                let duration = toolActionHoldDuration(for: snapshot.toolActionHint)
                if duration > 0 {
                    latchedToolAction = snapshot.toolActionHint
                    toolObservationIsActive = true
                    // If the tool wakes Migi, preserve the complete semantic
                    // tool gesture after refractory sleep and the wake sequence.
                    toolActionUntil = max(
                        toolActionUntil,
                        time + duration + remainingBehaviorDeferral(at: time)
                    )
                } else {
                    toolObservationIsActive = false
                }
            } else if toolObservationIsActive {
                toolObservationIsActive = false
                let duration = toolActionHoldDuration(for: latchedToolAction)
                if duration > 0 {
                    // Completion often changes the monitor back to `.thinking`
                    // immediately. Renew once at that boundary so a completed
                    // operation never flashes away on its output frame.
                    toolActionUntil = max(
                        toolActionUntil,
                        time + duration + remainingBehaviorDeferral(at: time)
                    )
                }
            }
        }

        let incomingActivity = latestSnapshot?.activity
        if incomingActivity == .waiting || incomingActivity == .failed {
            latchedToolAction = .none
            toolActionUntil = 0
            toolObservationIsActive = false
        } else if time >= toolActionUntil, !toolObservationIsActive {
            latchedToolAction = .none
            toolActionUntil = 0
        }
    }

    private func updateNovelToolLatch(
        for activity: CodexActivity,
        at time: TimeInterval
    ) {
        if activity == .waiting || activity == .failed {
            novelToolActionUntil = 0
        } else if time >= novelToolActionUntil {
            novelToolActionUntil = 0
        }

        guard handledNoveltySnapshotGeneration != snapshotGeneration else {
            return
        }
        handledNoveltySnapshotGeneration = snapshotGeneration

        guard let snapshot = latestSnapshot,
              let event = snapshot.latestNovelTool,
              consumedNovelToolSequences.insert(event.sequence).inserted
        else {
            return
        }

        // Novelty is an independent semantic event and can coexist with a
        // higher-priority winner from another agent. Validate the event's own
        // identity, but never incorrectly bind it to snapshot.sourceAgent/path.
        let canonicalName = event.canonicalName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !canonicalName.isEmpty,
              !event.sourcePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              event.toolActionHint == .none
        else {
            return
        }

        let eventAge = snapshotIngestedAt.timeIntervalSince(event.observedAt)
        guard eventAge >= -1, eventAge <= Self.novelToolTTL,
              activity.isMigiWorkActivity,
              time >= novelToolCooldownUntil,
              latchedToolAction == .none,
              toolActionUntil <= time
        else {
            return
        }

        novelToolActionUntil =
            time + Self.novelToolGestureDuration + remainingBehaviorDeferral(at: time)
        novelToolCooldownUntil = time + Self.novelToolCooldown
    }

    private func updatePeerSignalEvaluation(
        for activity: CodexActivity,
        at time: TimeInterval
    ) {
        if activity == .waiting || activity == .failed {
            peerSignalEvaluationUntil = 0
        } else if peerSignalEvaluationUntil > 0 {
            let semanticWorkUntil = max(toolActionUntil, novelToolActionUntil)
            if semanticWorkUntil > time {
                // Queue the biological peer scan behind explicit work and keep
                // its complete authored duration even if a tool-output snapshot
                // renews the read/write latch.
                peerSignalEvaluationUntil = max(
                    peerSignalEvaluationUntil,
                    semanticWorkUntil + Self.peerSignalEvaluationDuration
                )
            } else if time >= peerSignalEvaluationUntil {
                peerSignalEvaluationUntil = 0
            }
        }

        guard handledPeerSnapshotGeneration != snapshotGeneration else {
            return
        }
        handledPeerSnapshotGeneration = snapshotGeneration

        let activeAgents = latestSnapshot?.activeAgents ?? []
        if activeAgents.count < 2 {
            observedActiveAgents = activeAgents
            return
        }

        // A peer set first observed while Migi is asleep, waiting, reviewing,
        // or reacting to failure remains pending. Consume it only when live work
        // can actually present the evaluation gesture.
        guard activity == .thinking || activity == .tool else {
            return
        }

        let peerSetChanged = activeAgents != observedActiveAgents
        observedActiveAgents = activeAgents
        guard peerSetChanged,
              time >= peerSignalEvaluationCooldownUntil
        else {
            return
        }

        let semanticWorkUntil = max(toolActionUntil, novelToolActionUntil)
        let presentationBeginsAt = max(
            time + remainingBehaviorDeferral(at: time),
            semanticWorkUntil
        )
        peerSignalEvaluationUntil =
            presentationBeginsAt + Self.peerSignalEvaluationDuration
        peerSignalEvaluationCooldownUntil =
            time + Self.peerSignalEvaluationCooldown
    }

    private func toolActionHoldDuration(
        for hint: CodexToolActionHint
    ) -> TimeInterval {
        switch hint {
        case .read:
            return Self.readActionHoldDuration
        case .write:
            return Self.writeActionHoldDuration
        case .none:
            return 0
        }
    }

    private func resolveActivity(at time: TimeInterval) -> CodexActivity {
        let incoming = latestSnapshot?.activity ?? displayedActivity

        if incoming == .failed {
            if !failureIsLatched {
                failureIsLatched = true
                let incomingDisposition =
                    latestSnapshot?.failureDisposition ?? .none
                latchedFailureDisposition =
                    incomingDisposition == .none ? .routine : incomingDisposition
                credibleThreatPresentationStartedAt = nil
                failureRecoveryWasScheduled = false
                recoveryActivity = displayedActivity == .failed ? .idle : displayedActivity
                displayedActivity = .failed
                failureUntil = time + Self.failedReactionDuration
            }

            if time < failureUntil {
                return .failed
            }

            // A stale failure observation must not leave Migi collapsed indefinitely.
            scheduleRecoveryCareIfNeeded(at: time)
            displayedActivity = recoveryActivity == .failed ? .idle : recoveryActivity
            return displayedActivity
        }

        if failureIsLatched {
            scheduleRecoveryCareIfNeeded(at: time)
            failureIsLatched = false
            failureUntil = 0
            latchedFailureDisposition = .none
            credibleThreatPresentationStartedAt = nil
        }

        if incoming.isMigiWorkActivity {
            displayedActivity = incoming
            recoveryActivity = incoming
            // As long as work observations remain current, every frame renews the lease.
            // A later idle observation therefore gets a full 20-second hysteresis.
            workHoldUntil = max(workHoldUntil, time + Self.minimumWorkHold)
            return displayedActivity
        }

        if incoming == .idle,
           displayedActivity.isMigiWorkActivity,
           time < workHoldUntil
        {
            return displayedActivity
        }

        displayedActivity = incoming
        if incoming != .failed {
            recoveryActivity = incoming
        }
        return displayedActivity
    }

    private func scheduleRecoveryCareIfNeeded(at time: TimeInterval) {
        guard !failureRecoveryWasScheduled else { return }
        failureRecoveryWasScheduled = true
        guard relationshipStage != .cautious else { return }
        recoveryCareUntil = max(
            recoveryCareUntil,
            time + Self.recoveryCareDuration
        )
    }

    private func resolveMicroBehavior(
        for activity: CodexActivity,
        at time: TimeInterval
    ) -> (action: MigiMicroAction, prop: MigiProp) {
        switch wakePhase {
        case .deepSleep, .dreamDisturbance:
            return (.dormant, .none)
        case .lookAround:
            return (.lookAround, .none)
        case .awake:
            break
        }

        if activity == .idle, time < interactionLookAroundUntil {
            return (.lookAround, .none)
        }

        if activity == .idle, scoutPhase == .returning {
            return (.detachedScoutReturn, .none)
        }

        if time < recoveryCareUntil,
           activity != .waiting,
           activity != .failed
        {
            return (.recoveryCare, .none)
        }

        guard activity == .idle else {
            if wasIdle {
                clearIdleBehavior()
            }
            wasIdle = false

            if activity == .waiting || activity == .failed {
                return activeBehavior(for: activity, at: time)
            }

            if time < toolActionUntil {
                switch latchedToolAction {
                case .read:
                    return (.read, .book)
                case .write:
                    return (.fineMotor, .none)
                case .none:
                    break
                }
            }
            if time < novelToolActionUntil {
                return (.signalSampling, .none)
            }
            if time < peerSignalEvaluationUntil {
                // Nearby active agents read as an unfamiliar biological signal:
                // Migi stops, lets the main eye acquire it, then brings the
                // shorter eye around a beat later. Explicit work semantics keep
                // priority so this reaction never shortens reading or writing.
                return (.signalSampling, .none)
            }
            return activeBehavior(for: activity, at: time)
        }

        if !wasIdle {
            wasIdle = true
            idleAction = .none
            idleActionProp = .none
            idleActionUntil = 0
            idleSettleUntil = 0
            blinkUntil = 0
            nextIdleActionAt = time + random.next(in: 8...16)
            nextBlinkAt = time + random.next(in: 3.5...8.5)
        }

        if idleAction != .none, time >= idleActionUntil {
            idleAction = .none
            idleActionProp = .none
            idleSettleUntil = time + random.next(in: 0.6...1.0)
            nextIdleActionAt = time + random.next(in: 18...34)
        }

        if idleAction == .none,
           !isMoving,
           scoutPhase == .anchored,
           time >= idleSettleUntil,
           time >= nextIdleActionAt
        {
            beginIdleAction(at: time)
        }

        if idleAction != .none {
            return (idleAction, idleActionProp)
        }

        if time >= blinkUntil, time >= nextBlinkAt {
            blinkUntil = time + random.next(in: 0.13...0.22)
            nextBlinkAt = blinkUntil + random.next(in: 3.5...8.5)
        }

        return time < blinkUntil ? (.blink, .none) : (.none, .none)
    }

    private func activeBehavior(
        for activity: CodexActivity,
        at time: TimeInterval
    ) -> (action: MigiMicroAction, prop: MigiProp) {
        switch activity {
        case .idle:
            return (.none, .none)
        case .thinking:
            // Reasoning stays visibly computational, while concrete tool work
            // uses study or fine-motor poses below.
            return (.type, .laptop)
        case .tool:
            switch latestSnapshot?.toolActionHint ?? .none {
            case .read:
                return (.read, .book)
            case .write:
                return (.fineMotor, .none)
            case .none:
                return (.fineMotor, .none)
            }
        case .waiting:
            return (.checkPhone, .phone)
        case .review:
            return (.signalSampling, .none)
        case .failed:
            guard normalizedFailureDisposition == .credibleThreat else {
                return (.calmDiagnosis, .none)
            }
            if credibleThreatPresentationStartedAt == nil {
                credibleThreatPresentationStartedAt = time
            }
            let elapsed = time - (credibleThreatPresentationStartedAt ?? time)
            return elapsed < Self.protectiveShieldDuration
                ? (.protectiveShield, .none)
                : (.sharpenTip, .none)
        }
    }

    private func beginIdleAction(at time: TimeInterval) {
        let candidates = Self.idleActionSpecs.filter { spec in
            time >= idleActionCooldownUntil[spec.action, default: 0]
                && spec.family != lastIdleActionFamily
        }
        guard !candidates.isEmpty else {
            nextIdleActionAt = time + random.next(in: 3...6)
            return
        }

        let totalWeight = candidates.reduce(0) {
            $0 + idleWeight(for: $1, stage: relationshipStage)
        }
        var choice = random.nextInt(upperBound: totalWeight)
        let selected = candidates.first { spec in
            let weight = idleWeight(for: spec, stage: relationshipStage)
            if choice < weight {
                return true
            }
            choice -= weight
            return false
        } ?? candidates[candidates.count - 1]

        idleAction = selected.action
        idleActionProp = selected.prop
        idleActionUntil = time + random.next(in: selected.duration)
        idleActionCooldownUntil[selected.action] =
            idleActionUntil + random.next(in: selected.cooldown)
        lastIdleActionFamily = selected.family
    }

    private func idleWeight(
        for spec: MigiIdleActionSpec,
        stage: MigiRelationshipStage
    ) -> Int {
        let adjustment: Int
        switch stage {
        case .cautious:
            switch spec.action {
            case .signalSampling:
                adjustment = 5
            case .recoveryCare:
                adjustment = -4
            default:
                adjustment = 0
            }
        case .cooperative:
            switch spec.action {
            case .fineMotor, .recoveryCare:
                adjustment = 4
            case .checkPhone, .logicCount:
                adjustment = -1
            default:
                adjustment = 0
            }
        case .protective:
            switch spec.action {
            case .recoveryCare:
                adjustment = 8
            case .fineMotor, .read, .storagePocket:
                adjustment = 3
            case .checkPhone, .logicCount:
                adjustment = -1
            default:
                adjustment = 0
            }
        }
        return max(spec.weight + adjustment, 1)
    }

    private func clearIdleBehavior() {
        idleAction = .none
        idleActionProp = .none
        idleActionUntil = 0
        blinkUntil = 0
    }

    private func updatePatrol(
        for activity: CodexActivity,
        action: MigiMicroAction,
        prop: MigiProp,
        wakePhase: MigiWakePhase,
        at time: TimeInterval,
        deltaTime: TimeInterval,
        availableWidth: CGFloat
    ) -> CGPoint {
        // Reserve room for Migi's body and reaching tentacles at both edges.
        let horizontalLimit = max(availableWidth * 0.5 - 108, 0)
        positionX = min(max(positionX, -horizontalLimit), horizontalLimit)

        let anchoredKind: MigiAnchoredAttentionKind?
        switch prop {
        case .laptop:
            anchoredKind = .laptop
        case .phone:
            anchoredKind = .phone
        case .book:
            anchoredKind = .book
        case .none:
            if activity != .idle, action == .rapidNotes {
                anchoredKind = .rapidNotes
            } else if activity != .idle, action == .fineMotor {
                anchoredKind = .fineMotor
            } else if activity != .idle, action == .signalSampling {
                anchoredKind = .signalSampling
            } else {
                anchoredKind = nil
            }
        }
        let anchoredIdentity =
            wakePhase == .awake && activity != .failed
                ? anchoredKind.map {
                    MigiAnchoredAttentionIdentity(
                        activity: activity,
                        kind: $0
                    )
                }
                : nil
        updateAnchoredAttentionFacing(
            identity: anchoredIdentity,
            at: time
        )

        guard horizontalLimit >= 8 else {
            anchorDetachedScout(at: time)
            return CGPoint(x: 0, y: 0)
        }

        if wakePhase != .awake {
            anchorDetachedScout(at: time)
            let verticalMotion: CGFloat
            switch wakePhase {
            case .deepSleep:
                verticalMotion = CGFloat(sin(time * 0.32)) * 0.08
            case .dreamDisturbance:
                verticalMotion = CGFloat(sin(time * 1.05)) * 0.18
            case .lookAround:
                verticalMotion = CGFloat(sin(time * 1.15)) * 0.28
            case .awake:
                verticalMotion = 0
            }
            return CGPoint(
                x: positionX,
                y: verticalMotion
            )
        }

        if activity == .failed {
            anchorDetachedScout(at: time)
            return CGPoint(x: 0, y: -0.4)
        }

        if activity == .idle, scoutInteractionReturnPending {
            if time < scoutInteractionPauseUntil {
                isMoving = false
                translationBeginsAt = 0
                return scoutInteractionHoldOffset
            }

            scoutInteractionReturnPending = false
            scoutInteractionPauseUntil = 0
            scoutReturnVerticalHandoffStartedAt = time
            resumeScoutReturnFromCurrentPosition(at: time)
        }

        if prop != .none {
            // Reading, typing, and checking a phone are anchored attention
            // states. Letting their rigid props drift across the desktop makes
            // focused work read as locomotion.
            anchorDetachedScout(at: time)
            return CGPoint(
                x: 0,
                y: CGFloat(sin(time * 1.15)) * 0.28
            )
        }

        // Canonical transformations read best when Migi anchors its base and
        // lets motion travel from root to tip. This applies to explicit Codex
        // tool gestures and wake-up motion as well as spontaneous idle clips.
        let isCanonicalTransformation: Bool
        switch action {
        case .inspectHand, .palmObserver, .sharpenTip, .protectiveShield,
             .rapidNotes, .fineMotor,
             .organDrift, .logicCount, .signalSampling, .storagePocket,
             .recoveryCare, .calmDiagnosis, .lookAround, .stretch, .dormant:
            isCanonicalTransformation = true
        case .none, .blink, .detachedScoutReturn, .read, .checkPhone, .type:
            isCanonicalTransformation = false
        }
        if isCanonicalTransformation
            || (
                activity == .idle
                    && action != .none
                    && action != .blink
                    && action != .detachedScoutReturn
            )
            || (activity == .idle && time < idleSettleUntil)
        {
            anchorDetachedScout(at: time)
            return CGPoint(
                x: 0,
                y: CGFloat(sin(time * 1.15)) * 0.28
            )
        }

        // The autonomous walking body is a rare, short-range detached scout,
        // never Migi's permanent topology. Any non-idle semantic state above
        // forces it back to the right-hand anchor.
        guard activity == .idle else {
            anchorDetachedScout(at: time)
            return CGPoint(
                x: 0,
                y: CGFloat(sin(time * 1.6)) * 0.18
            )
        }

        if scoutPhase == .anchored, time >= nextScoutAt {
            beginDetachedScout(
                within: horizontalLimit,
                activity: activity,
                at: time
            )
        }

        if scoutPhase == .outbound, time >= scoutMustReturnAt {
            beginScoutReturn(at: time)
        }

        let isPlantingTurn = isMoving && time < translationBeginsAt
        if isMoving {
            if !isPlantingTurn {
                let distance = movementTargetX - positionX
                let step = movementSpeed * deltaTime
                if abs(distance) <= max(step, 0.5) {
                    positionX = movementTargetX
                    if scoutPhase == .outbound {
                        beginScoutReturn(at: time)
                    } else {
                        finishDetachedScout(at: time)
                    }
                } else {
                    let direction: CGFloat = distance < 0 ? -1 : 1
                    facing = direction
                    positionX += direction * step
                }
            }
        }

        var verticalMotion: CGFloat
        if isPlantingTurn {
            verticalMotion = CGFloat(sin(time * 2.4)) * 0.28
        } else if isMoving {
            verticalMotion = CGFloat(sin(time * 7.2)) * 1.8
        } else {
            verticalMotion = CGFloat(sin(time * 1.6)) * 0.45
        }
        if scoutPhase == .returning,
           let handoffStartedAt = scoutReturnVerticalHandoffStartedAt
        {
            let handoffDuration: TimeInterval = 0.22
            let progress = CGFloat(
                min(max((time - handoffStartedAt) / handoffDuration, 0), 1)
            )
            verticalMotion = interpolate(
                from: scoutInteractionHoldOffset.y,
                to: verticalMotion,
                progress: progress
            )
            if progress >= 1 {
                scoutReturnVerticalHandoffStartedAt = nil
            }
        }
        return CGPoint(x: positionX, y: verticalMotion)
    }

    private func beginDetachedScout(
        within horizontalLimit: CGFloat,
        activity: CodexActivity,
        at time: TimeInterval
    ) {
        let direction = nextPatrolDirection
        nextPatrolDirection = -direction
        let reach = random.next(in: 0.24...0.48)
        movementTargetX = direction * horizontalLimit * reach
        movementSpeed = patrolSpeed(for: activity)
        scoutPhase = .outbound
        scoutMustReturnAt = time + random.next(in: scoutDetachedDuration)
        let changesFacing = direction != facing
        facing = direction
        isMoving = true
        translationBeginsAt =
            changesFacing ? time + MigiAnimationTiming.patrolTurnDuration : time
    }

    private func beginScoutReturn(at time: TimeInterval) {
        guard scoutPhase == .outbound else { return }
        resumeScoutReturnFromCurrentPosition(at: time)
    }

    private func resumeScoutReturnFromCurrentPosition(
        at time: TimeInterval
    ) {
        if abs(positionX) < 0.5 {
            finishDetachedScout(at: time)
            return
        }

        scoutPhase = .returning
        movementTargetX = 0
        let direction: CGFloat = positionX < 0 ? 1 : -1
        let changesFacing = direction != facing
        facing = direction
        if movementSpeed <= 0 {
            movementSpeed = patrolSpeed(for: .idle)
        }
        isMoving = true
        translationBeginsAt =
            changesFacing ? time + MigiAnimationTiming.patrolTurnDuration : time
    }

    private func finishDetachedScout(at time: TimeInterval) {
        positionX = 0
        movementTargetX = 0
        movementSpeed = 0
        isMoving = false
        translationBeginsAt = 0
        scoutPhase = .anchored
        scoutMustReturnAt = 0
        scoutInteractionPauseUntil = 0
        scoutInteractionReturnPending = false
        scoutInteractionHoldOffset = .zero
        scoutReturnVerticalHandoffStartedAt = nil
        nextScoutAt = time + random.next(in: scoutInterval)
        stopUntil = nextScoutAt
    }

    private func anchorDetachedScout(at time: TimeInterval) {
        if scoutInteractionReturnPending {
            scoutInteractionPauseUntil = 0
            scoutInteractionReturnPending = false
            interactionLookAroundUntil = 0
            scoutInteractionHoldOffset = .zero
            scoutReturnVerticalHandoffStartedAt = nil
        }
        guard scoutPhase != .anchored || abs(positionX) > 0.001 else {
            isMoving = false
            translationBeginsAt = 0
            return
        }
        finishDetachedScout(at: time)
    }

    private func updateAnchoredAttentionFacing(
        identity: MigiAnchoredAttentionIdentity?,
        at time: TimeInterval
    ) {
        guard let identity else {
            anchoredAttentionIdentity = nil
            nextAnchoredFacingChangeAt = 0
            return
        }

        if anchoredAttentionIdentity != identity {
            anchoredAttentionIdentity = identity
            nextAnchoredFacingChangeAt = time + random.next(in: 14...24)
            return
        }

        guard time >= nextAnchoredFacingChangeAt else { return }
        facing = -facing
        nextAnchoredFacingChangeAt = time + random.next(in: 18...34)
    }

    private func stopDuration(for activity: CodexActivity) -> TimeInterval {
        switch activity {
        case .idle:
            return random.next(in: 4...10)
        case .thinking, .tool, .review:
            return random.next(in: 6...14)
        case .waiting:
            return random.next(in: 6...15)
        case .failed:
            return 3
        }
    }

    private func patrolSpeed(for activity: CodexActivity) -> CGFloat {
        switch activity {
        case .idle:
            return random.next(in: 34...58)
        case .thinking, .tool, .review:
            return random.next(in: 19...34)
        case .waiting:
            return random.next(in: 27...46)
        case .failed:
            return 0
        }
    }

    private func behaviorTargets(
        activity: CodexActivity,
        action: MigiMicroAction,
        isMoving: Bool,
        wakePhase: MigiWakePhase,
        at time: TimeInterval
    ) -> (energy: CGFloat, focus: CGFloat) {
        if wakePhase == .deepSleep {
            return (0.025, 0.04)
        }

        let base: (energy: CGFloat, focus: CGFloat)
        switch activity {
        case .idle:
            base = (0.3, 0.28)
        case .thinking:
            base = (0.68, 0.94)
        case .tool:
            base = (0.86, 0.88)
        case .waiting:
            base = (0.34, 0.42)
        case .review:
            base = (0.58, 0.96)
        case .failed:
            base = normalizedFailureDisposition == .credibleThreat
                ? (0.82, 0.98)
                : (0.46, 0.90)
        }

        let actionBoost: CGFloat
        switch action {
        case .none, .blink:
            actionBoost = 0
        case .read, .checkPhone, .lookAround, .rapidNotes, .logicCount,
             .signalSampling, .palmObserver:
            actionBoost = 0.08
        case .inspectHand, .sharpenTip, .protectiveShield, .stretch,
             .fineMotor, .organDrift, .storagePocket:
            actionBoost = 0.14
        case .recoveryCare, .calmDiagnosis:
            actionBoost = 0.04
        case .detachedScoutReturn:
            actionBoost = 0.12
        case .type:
            actionBoost = 0.1
        case .dormant:
            actionBoost = -0.18
        }

        let movementBoost: CGFloat = isMoving ? 0.16 : 0
        let ordinary = (
            min(base.energy + actionBoost + movementBoost, 1),
            min(base.focus + (action == .none ? 0 : 0.04), 1)
        )

        switch wakePhase {
        case .awake:
            return ordinary
        case .deepSleep:
            return (0.025, 0.04)
        case .dreamDisturbance:
            let progress = phaseProgress(at: time)
            return (
                interpolate(from: 0.08, to: 0.20, progress: progress),
                interpolate(from: 0.08, to: 0.28, progress: progress)
            )
        case .lookAround:
            let rawProgress = phaseProgress(at: time)
            let smoothProgress = rawProgress * rawProgress * (3 - 2 * rawProgress)
            return (
                interpolate(
                    from: 0.20,
                    to: max(ordinary.0, 0.20),
                    progress: smoothProgress
                ),
                interpolate(
                    from: 0.28,
                    to: max(ordinary.1, 0.28),
                    progress: smoothProgress
                )
            )
        }
    }

    private func interpolate(
        from start: CGFloat,
        to end: CGFloat,
        progress: CGFloat
    ) -> CGFloat {
        start + (end - start) * min(max(progress, 0), 1)
    }

    private func approach(
        _ current: CGFloat,
        _ target: CGFloat,
        deltaTime: TimeInterval,
        response: Double
    ) -> CGFloat {
        let blend = CGFloat(1 - exp(-deltaTime * response))
        return current + (target - current) * blend
    }

    private static func sanitizedRange(
        _ range: ClosedRange<TimeInterval>,
        fallback: ClosedRange<TimeInterval>
    ) -> ClosedRange<TimeInterval> {
        let lower = range.lowerBound.isFinite
            ? max(range.lowerBound, 0)
            : fallback.lowerBound
        let upper = range.upperBound.isFinite
            ? max(range.upperBound, lower)
            : max(fallback.upperBound, lower)
        return lower...upper
    }
}

private enum MigiAnchoredAttentionKind: Equatable {
    case laptop
    case phone
    case book
    case rapidNotes
    case fineMotor
    case signalSampling
}

private struct MigiAnchoredAttentionIdentity: Equatable {
    let activity: CodexActivity
    let kind: MigiAnchoredAttentionKind
}

private extension CodexActivity {
    var isMigiWorkActivity: Bool {
        switch self {
        case .thinking, .tool, .review:
            return true
        case .idle, .waiting, .failed:
            return false
        }
    }
}

private enum MigiIdleActionFamily {
    case study
    case hand
    case sensory
    case body
    case rest
    case care
}

private struct MigiIdleActionSpec {
    let action: MigiMicroAction
    let prop: MigiProp
    let weight: Int
    let duration: ClosedRange<TimeInterval>
    let cooldown: ClosedRange<TimeInterval>
    let family: MigiIdleActionFamily
}

private struct MigiSeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func nextUnit() -> Double {
        Double(nextUInt64() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    mutating func next(in range: ClosedRange<TimeInterval>) -> TimeInterval {
        range.lowerBound + (range.upperBound - range.lowerBound) * nextUnit()
    }

    mutating func next(in range: ClosedRange<CGFloat>) -> CGFloat {
        range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(nextUnit())
    }

    mutating func nextBool() -> Bool {
        nextUInt64() & 1 == 0
    }

    mutating func nextInt(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        return Int(nextUInt64() % UInt64(upperBound))
    }
}
