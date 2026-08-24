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
    /// A monitored Agent spawned a detached sub-agent: the same canon image as
    /// the idle scout's return, but wrist-anchored, one shot, cooldown-gated.
    /// Deliberately a distinct case so the controller rule that clears an
    /// out-of-phase `.detachedScoutReturn` never erases this showpiece.
    case subAgentScout
    case rapidNotes
    case fineMotor
    case organDrift
    case logicCount
    case signalSampling
    /// A short biological focus transfer between two live Agent sources.
    /// The renderer gives it an independent look-around playback clock, then
    /// the controller performs one planted authored turn before work resumes.
    case agentHandoff
    /// The planted 1.01-second authored turn that commits an Agent handoff.
    /// It is independent from the following work clip so a thinking/tool/review
    /// change cannot consume the facing change without showing the turn.
    case agentTurn
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
    /// A semantic pose replacement is deliberately much slower than an authored
    /// animation cell advance. Interactive clips include this lead-in so their
    /// complete authored motion remains visible after the new pose has arrived.
    static let semanticHandoffDuration: TimeInterval = 0.36

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
    /// How many real monitored agents were concurrently active in the latest
    /// snapshot. Renderers use it to spread branch-eye scan sectors while
    /// Migi tracks parallel work.
    public let activeAgentCount: Int
    /// Persisted canon sleep-debt pressure, 0...1: quietens idle antics,
    /// shortens the road to deep sleep, lengthens its minimum hold, and
    /// lowers overall body tone.
    public let fatigue: CGFloat

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
        var rate = wakePhase == .dreamDisturbance ? 1.25 : 1
        if wakePhase == .awake, activity != .idle {
            switch microAction {
            case .type, .rapidNotes, .read:
                // Body honesty: fingers and page turns track the real fresh
                // bytes arriving in the monitored logs.
                rate *= clipPlaybackScale
            default:
                break
            }
        }
        return rate
    }

    /// Live throughput mapped into canonical bounds (1 = authored rate),
    /// neutral outside real monitored sessions and any demo/QA snapshot.
    public let clipPlaybackScale: Double

    /// True while the rare long-pose work blink is inside its window.
    /// Composed with the pose (never replaces it), unlike the idle `.blink`
    /// micro action which owns the anchored idle body outright.
    public let blinkActive: Bool

    /// Any blink source, for renderers driving the shared eyelid curve.
    public var blinkWanted: Bool {
        microAction == .blink || blinkActive
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
        isUserAttentionActive: Bool = false,
        activeAgentCount: Int = 1,
        fatigue: CGFloat = 0,
        blinkActive: Bool = false,
        clipPlaybackScale: Double = 1
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
        self.activeAgentCount = max(activeAgentCount, 1)
        self.fatigue = min(max(fatigue, 0), 1)
        self.blinkActive = blinkActive
        self.clipPlaybackScale = min(max(clipPlaybackScale, 0.5), 1.6)
    }
}

/// Turns terse Codex activity observations into long-lived, organic character behavior.
///
/// The controller deliberately owns no timers. Callers drive it from their render loop,
/// making both runtime behavior and seeded tests deterministic.
public final class MigiBehaviorController {
    private static let minimumWorkHold: TimeInterval = 20
    private static let failedReactionDuration: TimeInterval = 3.2
    /// The defensive shield is a reflex that strengthens with the bond: canon
    /// Migi intervenes faster and holds longer once coexistence becomes
    /// protection. Cautious 0.7s, cooperative 0.9s, protective 1.2s.
    private static func protectiveShieldDuration(
        for stage: MigiRelationshipStage
    ) -> TimeInterval {
        switch stage {
        case .cautious:
            return 0.7
        case .cooperative:
            return 0.9
        case .protective:
            return 1.2
        }
    }

    private static let readActionHoldDuration: TimeInterval = 1.8
    private static let writeActionHoldDuration: TimeInterval = 2.4
    /// `palm-observer` is an authored enter-hold-retract cycle of ~1.94 s.
    private static let searchActionHoldDuration: TimeInterval = 2.0
    /// One complete `logic-count` beat plus a short settle margin.
    private static let verifyActionHoldDuration: TimeInterval = 1.5
    /// One complete `storage-pocket` enter-hold-retract cycle (~2.10 s).
    private static let compactActionHoldDuration: TimeInterval = 2.25
    /// One complete `detached-scout-return` loop (~2.18 s).
    private static let scoutActionHoldDuration: TimeInterval = 2.35
    /// Sub-agent records arrive in bursts; the scout showpiece replays at most
    /// once per minute no matter how chatty the sub-agent is.
    private static let scoutGestureCooldown: TimeInterval = 60
    private static let compactGestureCooldown: TimeInterval = 45
    /// Silence beyond this means the reply stream has paused.
    private static let spokenStreamingGrace: TimeInterval = 1.4
    /// A user who leaves Migi waiting this long gets the bored canon self-check.
    private static let waitingEscalationDelay: TimeInterval = 90
    /// One sustained work turn earns a single tissue unwind on the way to idle.
    private static let sustainedWorkStretchThreshold: TimeInterval = 60
    private static let earnedStretchDuration: TimeInterval = 1.2
    /// A user holding their gaze on the body earns one deliberate turn toward
    /// them. Rare and short: staring back constantly would be surveillance,
    /// not coexistence.
    private static let stareHoldDuration: TimeInterval = 4.5
    private static let stareCooldown: TimeInterval = 20
    /// Canon: roughly four hours of deep sleep per day. Eight working hours
    /// accrue a full debt; deep sleep pays it back at five times the rate.
    private static let fatigueWorkRate: Double = 1.0 / (8 * 3600)
    private static let fatigueAmbientRate: Double = 0.15 / (8 * 3600)
    private static let fatigueSleepRecoveryRate: Double = 5.0 / (8 * 3600)
    private static let novelToolGestureDuration: TimeInterval = 0.96 * 2
    private static let novelToolCooldown: TimeInterval = 60
    private static let novelToolTTL: TimeInterval = 12
    /// `signal-sampling` is a six-frame enter/hold/retract action. Preserve its
    /// complete 1.88 s authored path, 0.70 s peak hold, and 0.36 s tissue entry.
    private static let peerSignalEvaluationDuration: TimeInterval =
        MigiAnimationTiming.semanticHandoffDuration + 2.58
    private static let peerSignalEvaluationCooldown: TimeInterval = 12
    /// One complete `look-around`, including the semantic tissue entry.
    private static let agentHandoffDuration: TimeInterval =
        MigiAnimationTiming.semanticHandoffDuration + 1.04
    private static let agentHandoffCooldown: TimeInterval = 3
    private static let agentTurnDuration = MigiAnimationTiming.patrolTurnDuration
    /// One complete, calm one-two-three reconciliation after a peer leaves.
    private static let peerAssimilationDuration: TimeInterval =
        MigiAnimationTiming.semanticHandoffDuration + 1.12
    private static let peerAssimilationCooldown: TimeInterval = 6
    private static let recoveryCareDuration: TimeInterval = 0.9 * 4
    private static let interactionCooldown: TimeInterval = 8
    private static let interactionLookAroundDuration: TimeInterval =
        MigiAnimationTiming.semanticHandoffDuration + 1.04
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
    /// Deterministic QA disables work-pose blinks so captures never race the
    /// stability timer. Production leaves this on.
    public var allowsWorkPoseBlinks = true
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
    private var lastObservedSpokenRevision: UInt64?
    private var spokenStreamingUntil: TimeInterval = 0
    private var waitingSince: TimeInterval?
    private var sustainedWorkBeganAt: TimeInterval?
    private var scoutGestureCooldownUntil: TimeInterval = 0
    private var compactGestureCooldownUntil: TimeInterval = 0
    private var toolActionUntil: TimeInterval = 0
    private var toolObservationIsActive = false
    private var consumedNovelToolSequences: Set<UInt64> = []
    private var handledNoveltySnapshotGeneration: UInt64 = 0
    private var novelToolActionUntil: TimeInterval = 0
    private var novelToolCooldownUntil: TimeInterval = 0
    private var handledPeerSnapshotGeneration: UInt64 = 0
    private var observedActiveAgents: Set<MonitoredAgent> = []
    private var observedSourceAgent: MonitoredAgent?
    private var observedMonitoringGeneration: UInt64?
    private var presentedSourceAgent: MonitoredAgent?
    private var peerSignalEvaluationUntil: TimeInterval = 0
    private var peerSignalEvaluationCooldownUntil: TimeInterval = 0
    private var peerAssimilationUntil: TimeInterval = 0
    private var peerAssimilationCooldownUntil: TimeInterval = 0
    private var agentHandoffUntil: TimeInterval = 0
    private var agentHandoffCooldownUntil: TimeInterval = 0
    private var agentHandoffTargetAgent: MonitoredAgent?
    private var agentTurnUntil: TimeInterval = 0
    private var sequentialHandoffContextUntil: TimeInterval = 0
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
    private var requestedStareDirection: CGFloat = 1
    private var pendingStareGeneration: UInt64 = 0
    private var handledStareGeneration: UInt64 = 0
    private var stareDirection: CGFloat?
    private var stareFacingHoldUntil: TimeInterval = 0
    private var stareCooldownUntil: TimeInterval = 0
    private var fatigue: Double = 0
    private var lastPoseSignature: (CodexActivity, MigiMicroAction, MigiProp)?
    private var lastPoseChangeAt: TimeInterval = 0
    private var nextWorkBlinkAt: TimeInterval = 0
    private var workBlinkUntil: TimeInterval = 0
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

    /// Queues a sustained-gaze acknowledgement. Gating (cooldown, sleep,
    /// threat, locomotion) happens in `update` where the monotonic clock lives.
    /// Pass nil to release the hold early when the pointer leaves the body.
    public func ingestStareAttention(_ direction: CGFloat?) {
        guard let direction else {
            stareDirection = nil
            stareFacingHoldUntil = 0
            return
        }
        requestedStareDirection = direction < 0 ? -1 : 1
        pendingStareGeneration &+= 1
    }

    private func consumePendingStare(
        for activity: CodexActivity,
        at time: TimeInterval
    ) {
        guard handledStareGeneration != pendingStareGeneration else {
            return
        }
        handledStareGeneration = pendingStareGeneration

        guard wakePhase == .awake,
              !isCredibleThreat(activity),
              activity == .idle || activity == .waiting,
              !isMoving,
              scoutPhase == .anchored,
              time >= stareCooldownUntil
        else {
            return
        }

        stareDirection = requestedStareDirection
        stareFacingHoldUntil = time + Self.stareHoldDuration
        stareCooldownUntil = time + Self.stareCooldown
    }

    private func updateStareFacing(at time: TimeInterval) {
        if stareDirection != nil,
           (time >= stareFacingHoldUntil || wakePhase != .awake)
        {
            stareDirection = nil
            stareFacingHoldUntil = 0
        }
        guard let stareDirection,
              time < stareFacingHoldUntil,
              !isMoving,
              facing != stareDirection
        else {
            return
        }
        // selectSprite observes the facing flip and owns the authored planted
        // turn from here.
        facing = stareDirection
    }

    /// Canon physiology: sustained cooperation accrues a sleep debt that only
    /// complete sleep repays. A tired Migi is quieter, sleeps sooner and
    /// longer — never faster or cuter.
    private func integrateFatigue(
        for activity: CodexActivity,
        deltaTime: TimeInterval
    ) {
        switch wakePhase {
        case .deepSleep:
            fatigue = max(fatigue - deltaTime * Self.fatigueSleepRecoveryRate, 0)
        case .awake, .dreamDisturbance, .lookAround:
            let rate =
                activity.isMigiWorkActivity || activity == .failed
                    ? Self.fatigueWorkRate
                    : Self.fatigueAmbientRate
            fatigue = min(fatigue + deltaTime * rate, 1)
        }
    }

    /// Restores the persisted sleep debt at launch. `value` is a clamped 0...1.
    public func restoreFatigue(_ value: Double) {
        fatigue = min(max(value.isFinite ? value : 0, 0), 1)
    }

    /// Exhaustion brings sleep sooner (30 min → 9 min at full debt).
    private var effectiveDeepSleepDelay: TimeInterval {
        deepSleepDelay * (1 - 0.7 * fatigue)
    }

    /// …and holds it longer once down (20 s → 60 s at full debt).
    private var effectiveMinimumDeepSleepDuration: TimeInterval {
        minimumDeepSleepDuration * (1 + 2 * fatigue)
    }

    /// Used by the explicit visual demo/QA route. It changes presentation state
    /// immediately and clears normal hysteresis without affecting patrol position.
    public func force(_ snapshot: CodexActivitySnapshot) {
        force(snapshot, resetFatigue: false)
    }

    /// QA routes additionally rebase the sleep debt so captures stay
    /// reproducible; the menu-driven demo keeps the user's real ledger.
    public func force(
        _ snapshot: CodexActivitySnapshot,
        resetFatigue: Bool
    ) {
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
        lastObservedSpokenRevision = snapshot.spokenRevision
        spokenStreamingUntil = 0
        waitingSince = nil
        sustainedWorkBeganAt = nil
        scoutGestureCooldownUntil = 0
        compactGestureCooldownUntil = 0
        consumedNovelToolSequences.removeAll(keepingCapacity: true)
        handledNoveltySnapshotGeneration = snapshotGeneration
        novelToolActionUntil = 0
        novelToolCooldownUntil = 0
        handledPeerSnapshotGeneration = snapshotGeneration
        observedActiveAgents = snapshot.activeAgents
        observedSourceAgent = snapshot.sourceAgent
        observedMonitoringGeneration = snapshot.monitoringGeneration
        presentedSourceAgent = snapshot.sourceAgent
        peerSignalEvaluationUntil = 0
        peerSignalEvaluationCooldownUntil = 0
        peerAssimilationUntil = 0
        peerAssimilationCooldownUntil = 0
        agentHandoffUntil = 0
        agentHandoffCooldownUntil = 0
        agentHandoffTargetAgent = nil
        agentTurnUntil = 0
        sequentialHandoffContextUntil = 0
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
        pendingStareGeneration = 0
        handledStareGeneration = 0
        stareDirection = nil
        stareFacingHoldUntil = 0
        stareCooldownUntil = 0
        if resetFatigue {
            fatigue = 0
        }
        lastPoseSignature = nil
        lastPoseChangeAt = 0
        nextWorkBlinkAt = 0
        workBlinkUntil = 0
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
        updateWorkObservation(for: activity, at: safeTime)
        updateNovelToolLatch(for: activity, at: safeTime)
        updatePeerSignalEvaluation(for: activity, at: safeTime)
        consumePendingInteraction(for: activity, at: safeTime)
        consumePendingStare(for: activity, at: safeTime)
        integrateFatigue(for: activity, deltaTime: safeDelta)
        updateStareFacing(at: safeTime)
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
        let poseSignature = (activity, behavior.action, behavior.prop)
        if lastPoseSignature.map({ $0 == poseSignature }) != true {
            lastPoseSignature = poseSignature
            lastPoseChangeAt = safeTime
            nextWorkBlinkAt = 0
            workBlinkUntil = 0
        }
        // Even an unblinking worker is not a statue: after a long, perfectly
        // stable pose Migi grants a single rare slow blink. Eye-only, so the
        // authored work pose is never interrupted. Deterministic QA keeps
        // pose timelines fully reproducible by opting out.
        let poseSupportsWorkBlink =
            allowsWorkPoseBlinks
            && wakePhase == .awake
            && (activity == .thinking || activity == .tool || activity == .review)
        if poseSupportsWorkBlink {
            if safeTime - lastPoseChangeAt > 8 {
                if nextWorkBlinkAt == 0 {
                    nextWorkBlinkAt = safeTime + random.next(in: 12...25)
                }
                if safeTime >= nextWorkBlinkAt {
                    workBlinkUntil = safeTime + 0.34
                    nextWorkBlinkAt = safeTime + random.next(in: 26...48)
                }
            } else {
                workBlinkUntil = 0
            }
        } else {
            workBlinkUntil = 0
        }
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
                    && safeTime < userAttentionUntil,
            activeAgentCount: observedActiveAgents.count,
            fatigue: CGFloat(fatigue),
            blinkActive: safeTime < workBlinkUntil,
            clipPlaybackScale: liveClipPlaybackScale(at: safeTime, activity: activity)
        )
    }

    private func initializeClock(at time: TimeInterval) {
        clockIsInitialized = true
        nextIdleActionAt = time + random.next(in: 8...16)
        nextBlinkAt = time + random.next(in: 6...18)
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
                guard sleptFor >= effectiveMinimumDeepSleepDuration else {
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
                time - idleSince >= effectiveDeepSleepDelay
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
            return max(effectiveMinimumDeepSleepDuration - sleptFor, 0)
                + dreamDisturbanceDuration
                + wakeDuration
                + MigiAnimationTiming.wakeHandoffDuration
        }
        return remainingWakeDuration(at: time)
    }

    private func updateToolActionLatch(at time: TimeInterval) {
        if handledSnapshotGeneration != snapshotGeneration {
            handledSnapshotGeneration = snapshotGeneration

            // A fresh speech revision during reasoning means the Agent is
            // actively transcribing its reply; Migi switches from internal
            // computation to rapid note-taking.
            if let revision = latestSnapshot?.spokenRevision {
                if revision != lastObservedSpokenRevision {
                    lastObservedSpokenRevision = revision
                    if latestSnapshot?.activity == .thinking {
                        spokenStreamingUntil = time + Self.spokenStreamingGrace
                    }
                }
            } else {
                lastObservedSpokenRevision = nil
            }

            if let snapshot = latestSnapshot, snapshot.activity == .tool {
                var duration = toolActionHoldDuration(for: snapshot.toolActionHint)
                if duration > 0 {
                    switch snapshot.toolActionHint {
                    case .scout where time < scoutGestureCooldownUntil,
                         .compact where time < compactGestureCooldownUntil:
                        // Bursting records must not loop the showpiece.
                        duration = 0
                    case .scout:
                        scoutGestureCooldownUntil =
                            time + Self.scoutGestureCooldown
                    case .compact:
                        compactGestureCooldownUntil =
                            time + Self.compactGestureCooldown
                    default:
                        break
                    }
                }
                if duration > 0 {
                    latchedToolAction = snapshot.toolActionHint
                    toolObservationIsActive = true
                    // If the tool wakes Migi, preserve the complete semantic
                    // tool gesture after refractory sleep and the wake sequence.
                    toolActionUntil = max(
                        toolActionUntil,
                        time
                            + duration
                            + remainingBehaviorDeferral(at: time)
                            + remainingAgentTurnDuration(at: time)
                    )
                } else {
                    toolObservationIsActive = false
                }
            } else if toolObservationIsActive {
                toolObservationIsActive = false
                var duration = toolActionHoldDuration(for: latchedToolAction)
                if latchedToolAction == .scout || latchedToolAction == .compact {
                    // One-shot showpieces never renew at the completion
                    // boundary; their cooldown owns any replay. A renewal
                    // here would silently double the authored full-body loop.
                    duration = 0
                }
                if duration > 0 {
                    // Completion often changes the monitor back to `.thinking`
                    // immediately. Renew once at that boundary so a completed
                    // operation never flashes away on its output frame.
                    toolActionUntil = max(
                        toolActionUntil,
                        time
                            + duration
                            + remainingBehaviorDeferral(at: time)
                            + remainingAgentTurnDuration(at: time)
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
            time
                + Self.novelToolGestureDuration
                + remainingBehaviorDeferral(at: time)
                + remainingAgentTurnDuration(at: time)
        novelToolCooldownUntil = time + Self.novelToolCooldown
    }

    private func updatePeerSignalEvaluation(
        for activity: CodexActivity,
        at time: TimeInterval
    ) {
        if activity == .waiting || activity == .failed {
            clearPeerTransitionPresentation(cancelCommittedTurn: true)
            if let snapshot = latestSnapshot {
                observedActiveAgents = snapshot.activeAgents
                observedSourceAgent = snapshot.sourceAgent
                observedMonitoringGeneration = snapshot.monitoringGeneration
                presentedSourceAgent = snapshot.sourceAgent
            }
            handledPeerSnapshotGeneration = snapshotGeneration
            return
        }

        let semanticWorkUntil = max(toolActionUntil, novelToolActionUntil)
        if semanticWorkUntil > time {
            // A newly observed explicit read/write or unfamiliar tool always
            // completes first. Returning to a hidden cue restarts its complete
            // biological motion instead of resuming halfway through retraction.
            if peerSignalEvaluationUntil > 0 {
                peerSignalEvaluationUntil = max(
                    peerSignalEvaluationUntil,
                    semanticWorkUntil + Self.peerSignalEvaluationDuration
                )
            }
            if peerAssimilationUntil > 0 {
                peerAssimilationUntil = max(
                    peerAssimilationUntil,
                    semanticWorkUntil + Self.peerAssimilationDuration
                )
            }
            if agentHandoffUntil > 0 {
                agentHandoffUntil = max(
                    agentHandoffUntil,
                    semanticWorkUntil + Self.agentHandoffDuration
                )
            }
        }

        if peerSignalEvaluationUntil > 0, time >= peerSignalEvaluationUntil {
            peerSignalEvaluationUntil = 0
        }
        if peerAssimilationUntil > 0, time >= peerAssimilationUntil {
            peerAssimilationUntil = 0
        }
        guard handledPeerSnapshotGeneration != snapshotGeneration else {
            scheduleAgentHandoffIfNeeded(
                for: activity,
                semanticWorkUntil: semanticWorkUntil,
                at: time
            )
            commitExpiredAgentHandoff(at: time)
            return
        }
        handledPeerSnapshotGeneration = snapshotGeneration

        guard let snapshot = latestSnapshot else { return }
        let activeAgents = snapshot.activeAgents
        let sourceAgent = snapshot.sourceAgent

        if let previousGeneration = observedMonitoringGeneration,
           previousGeneration != snapshot.monitoringGeneration
        {
            // A user-selected monitoring-mode epoch is a new coordinate system,
            // not an Agent-to-Agent handoff. Rebaseline the lead direction, but
            // still acknowledge an already-live collaboration once.
            clearPeerTransitionPresentation(cancelCommittedTurn: true)
            observedMonitoringGeneration = snapshot.monitoringGeneration
            observedActiveAgents = activeAgents
            observedSourceAgent = sourceAgent
            presentedSourceAgent = sourceAgent
            if activeAgents.count >= 2,
               activity == .thinking || activity == .tool
            {
                schedulePeerSignalEvaluation(
                    semanticWorkUntil: semanticWorkUntil,
                    at: time
                )
            }
            return
        }
        observedMonitoringGeneration = snapshot.monitoringGeneration

        let previousAgents = observedActiveAgents
        let previousSource = observedSourceAgent
        let enteredCollaboration =
            previousAgents.count < 2 && activeAgents.count >= 2
        let leftCollaboration =
            previousAgents.count >= 2 && activeAgents.count < 2
        let liveSourceChanged =
            previousSource != nil
                && sourceAgent != nil
                && previousSource != sourceAgent
                && previousSource != .zcode
                && sourceAgent != .zcode
        let sequentialContext =
            liveSourceChanged
                && previousAgents.union(activeAgents).count >= 2

        observedActiveAgents = activeAgents
        observedSourceAgent = sourceAgent
        if presentedSourceAgent == nil {
            presentedSourceAgent = sourceAgent
        }

        if enteredCollaboration,
           activity == .thinking || activity == .tool
        {
            schedulePeerSignalEvaluation(
                semanticWorkUntil: semanticWorkUntil,
                at: time
            )
        }

        if activeAgents.isEmpty {
            // All live sources can disappear in the same 0.8 s polling pass.
            // There is no remaining branch to count or direction to acquire,
            // even when this was a one-Agent rather than two-Agent episode.
            clearPeerTransitionPresentation()
            presentedSourceAgent = sourceAgent
            return
        }

        if leftCollaboration,
           activeAgents.count == 1,
           activity == .thinking || activity == .tool || activity == .review,
           time >= peerAssimilationCooldownUntil
        {
            let presentationBeginsAt = max(
                time + remainingBehaviorDeferral(at: time),
                semanticWorkUntil,
                peerSignalEvaluationUntil,
                agentTurnUntil
            )
            peerAssimilationUntil =
                presentationBeginsAt + Self.peerAssimilationDuration
            peerAssimilationCooldownUntil =
                time + Self.peerAssimilationCooldown
            // The remaining lead owns the now-reconciled direction; do not add
            // another long turn immediately after the completion gesture.
            presentedSourceAgent = sourceAgent
            agentHandoffUntil = 0
            agentHandoffTargetAgent = nil
        }

        if sequentialContext {
            sequentialHandoffContextUntil =
                max(sequentialHandoffContextUntil, time + 3.5)
        }
        if activeAgents.count >= 2 || time < sequentialHandoffContextUntil {
            if let sourceAgent, sourceAgent != .zcode {
                agentHandoffTargetAgent = sourceAgent
            } else if sourceAgent == .zcode {
                agentHandoffTargetAgent = nil
            }
        }
        scheduleAgentHandoffIfNeeded(
            for: activity,
            semanticWorkUntil: semanticWorkUntil,
            at: time
        )
        commitExpiredAgentHandoff(at: time)
    }

    private func schedulePeerSignalEvaluation(
        semanticWorkUntil: TimeInterval,
        at time: TimeInterval
    ) {
        guard time >= peerSignalEvaluationCooldownUntil else { return }
        let presentationBeginsAt = max(
            time + remainingBehaviorDeferral(at: time),
            semanticWorkUntil
        )
        peerSignalEvaluationUntil =
            presentationBeginsAt + Self.peerSignalEvaluationDuration
        peerSignalEvaluationCooldownUntil =
            time + Self.peerSignalEvaluationCooldown
    }

    private func scheduleAgentHandoffIfNeeded(
        for activity: CodexActivity,
        semanticWorkUntil: TimeInterval,
        at time: TimeInterval
    ) {
        guard activity == .thinking || activity == .tool,
              agentHandoffUntil == 0,
              agentTurnUntil <= time,
              time >= agentHandoffCooldownUntil,
              let target = agentHandoffTargetAgent,
              target != presentedSourceAgent,
              observedActiveAgents.count >= 2
                || time < sequentialHandoffContextUntil
        else {
            return
        }
        let presentationBeginsAt = max(
            time + remainingBehaviorDeferral(at: time),
            semanticWorkUntil,
            peerSignalEvaluationUntil,
            peerAssimilationUntil
        )
        agentHandoffUntil =
            presentationBeginsAt + Self.agentHandoffDuration
        agentHandoffCooldownUntil =
            time + Self.agentHandoffCooldown
    }

    private func remainingAgentTurnDuration(at time: TimeInterval) -> TimeInterval {
        max(agentTurnUntil - time, 0)
    }

    private func commitExpiredAgentHandoff(at time: TimeInterval) {
        guard agentHandoffUntil > 0, time >= agentHandoffUntil else { return }
        agentHandoffUntil = 0
        defer { agentHandoffTargetAgent = nil }
        guard let target = agentHandoffTargetAgent,
              target != .zcode,
              target != presentedSourceAgent,
              observedActiveAgents.contains(target)
                || time < sequentialHandoffContextUntil
        else {
            return
        }

        // Commit only after the newest snapshot has updated the target. This
        // prevents a source reversal arriving on the expiry frame from first
        // turning toward a stale Agent. The authored turn then owns its full
        // clock independently from whichever work pose follows it.
        facing = -facing
        presentedSourceAgent = target
        agentTurnUntil = time + Self.agentTurnDuration
    }

    private func clearPeerTransitionPresentation(
        cancelCommittedTurn: Bool = false
    ) {
        peerSignalEvaluationUntil = 0
        peerAssimilationUntil = 0
        agentHandoffUntil = 0
        agentHandoffTargetAgent = nil
        if cancelCommittedTurn {
            agentTurnUntil = 0
        }
        sequentialHandoffContextUntil = 0
    }

    /// Waiting and sustained-work bookkeeping. Canon Migi does not vibrate
    /// while left alone: it settles into a bored self-check, and it unwinds
    /// once after a genuinely long work turn.
    private func updateWorkObservation(
        for activity: CodexActivity,
        at time: TimeInterval
    ) {
        if activity == .waiting {
            if waitingSince == nil { waitingSince = time }
        } else {
            waitingSince = nil
        }
        switch activity {
        case .thinking, .tool, .review:
            if sustainedWorkBeganAt == nil { sustainedWorkBeganAt = time }
        case .idle, .waiting, .failed:
            break
        }
    }

    private func toolActionHoldDuration(
        for hint: CodexToolActionHint
    ) -> TimeInterval {
        switch hint {
        case .read:
            return Self.readActionHoldDuration
        case .write:
            return Self.writeActionHoldDuration
        case .search:
            return Self.searchActionHoldDuration
        case .verify:
            return Self.verifyActionHoldDuration
        case .compact:
            return Self.compactActionHoldDuration
        case .scout:
            return Self.scoutActionHoldDuration
        case .none, .execute:
            // General shell work stays a sustained pose; only its semantic
            // beats (a verification run) earn a latched gesture.
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

        if time < agentTurnUntil,
           activity != .waiting,
           activity != .failed
        {
            return (.agentTurn, .none)
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
                // The latched showpiece plays its authored path once;
                // sustained states keep their own fallback pose below.
                switch latchedToolAction {
                case .read:
                    return (.read, .book)
                case .write:
                    return (.fineMotor, .none)
                case .search:
                    return (.palmObserver, .none)
                case .verify:
                    return (.logicCount, .none)
                case .compact:
                    return (.storagePocket, .none)
                case .scout:
                    return (.subAgentScout, .none)
                case .none, .execute:
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
            if time < peerAssimilationUntil {
                // One-two-three is Migi's restrained queue reconciliation: the
                // completed branch has already withdrawn, and the remaining
                // work is counted before the ordinary task pose resumes.
                return (.logicCount, .none)
            }
            if time < agentHandoffUntil {
                return (.agentHandoff, .none)
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
            nextBlinkAt = time + random.next(in: 6...18)
            // One sustained real work turn earns a single tissue unwind on
            // the way back — not a celebration, just the body releasing.
            if let began = sustainedWorkBeganAt,
               time - began >= Self.sustainedWorkStretchThreshold,
               time >= idleActionCooldownUntil[.stretch, default: 0]
            {
                idleAction = .stretch
                idleActionProp = .none
                idleActionUntil = time + Self.earnedStretchDuration
                idleActionCooldownUntil[.stretch] = time + 180
                lastIdleActionFamily = .body
                nextIdleActionAt =
                    idleActionUntil + random.next(in: 8...16)
            }
            sustainedWorkBeganAt = nil
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
            // Canon discipline: Migi almost never blinks. Rare, deliberate,
            // slow blinks instead of a conversational cadence.
            blinkUntil = time + random.next(in: 0.30...0.44)
            nextBlinkAt = blinkUntil + random.next(in: 16...38)
        }

        return time < blinkUntil ? (.blink, .none) : (.none, .none)
    }

    /// Fresh rollout bytes/second → playback scale, log-compressed so streamed
    /// text reads as faster fingers/page turns while silence settles to a slow
    /// thinking stroke. Neutral (1) for idle, sleep phases, and any snapshot
    /// without a real monitored source (demo/QA stay canonical).
    private func liveClipPlaybackScale(
        at time: TimeInterval,
        activity: CodexActivity
    ) -> Double {
        guard wakePhase == .awake,
              activity != .idle,
              latestSnapshot?.sourcePath != nil,
              let bps = latestSnapshot?.logThroughput
        else {
            return 1
        }
        let level = log10(1 + max(bps, 0) / 512)
        return 0.75 + min(max(level, 0), 1) * 0.65
    }

    private func activeBehavior(
        for activity: CodexActivity,
        at time: TimeInterval
    ) -> (action: MigiMicroAction, prop: MigiProp) {
        switch activity {
        case .idle:
            return (.none, .none)
        case .thinking:
            // An actively streaming reply means the Agent is transcribing its
            // answer: rapid notes, not internal computation.
            if time < spokenStreamingUntil {
                return (.rapidNotes, .none)
            }
            // Reasoning stays visibly computational, while concrete tool work
            // uses study or fine-motor poses below.
            return (.type, .laptop)
        case .tool:
            switch latestSnapshot?.toolActionHint ?? .none {
            case .read:
                return (.read, .book)
            case .write:
                return (.fineMotor, .none)
            case .search:
                // Examining a remote specimen held at distance.
                return (.palmObserver, .none)
            case .execute, .verify:
                // Sustained shell output reads as fast transcription; the
                // verification beat itself is the latched logic-count above.
                return (.rapidNotes, .none)
            case .compact, .scout:
                // If the burst outlives the showpiece, Migi plainly
                // coordinates the extra work with all tendrils.
                return (.fineMotor, .none)
            case .none:
                return (.fineMotor, .none)
            }
        case .waiting:
            if let waitingSince,
               time - waitingSince >= Self.waitingEscalationDelay
            {
                // Long, truly unattended waiting: Migi sets the phone down
                // and checks its own fingers.
                return (.inspectHand, .none)
            }
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
            return elapsed < Self.protectiveShieldDuration(for: relationshipStage)
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

        // Exhaustion culls idle antics before any weighting happens: a tired
        // Migi increasingly chooses to simply remain a hand.
        if fatigue > 0.55 {
            let skipProbability = (fatigue - 0.55) / 0.45 * 0.75
            if random.nextUnit() < skipProbability {
                nextIdleActionAt = time + random.next(in: 26...44)
                return
            }
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
                // Non-sinusoidal breath: sharp inhale, slow exhale. Amplitude
                // stays at the authored ±0.08 so silhouette QA never drifts.
                let w = time * 0.32
                verticalMotion = CGFloat(
                    (sin(w) + 0.18 * sin(2 * w + 1.1)) * 0.847
                ) * 0.08
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
            // states. Their organic breathing already lives inside the Metal
            // mesh; moving the NSPanel by sub-pixel amounts makes its drawable
            // alternate between backing pixels and reads as a shimmer.
            anchorDetachedScout(at: time)
            return .zero
        }

        // Canonical transformations read best when Migi anchors its base and
        // lets motion travel from root to tip. This applies to explicit Codex
        // tool gestures and wake-up motion as well as spontaneous idle clips.
        let isCanonicalTransformation: Bool
        switch action {
        case .inspectHand, .palmObserver, .sharpenTip, .protectiveShield,
             .rapidNotes, .fineMotor,
             .organDrift, .logicCount, .signalSampling, .agentHandoff, .agentTurn,
             .storagePocket,
             .recoveryCare, .calmDiagnosis, .lookAround, .stretch, .dormant:
            isCanonicalTransformation = true
        case .subAgentScout:
            // Wrist-anchored single clip, driven from root like every other
            // authored canonical pose.
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
            return .zero
        }

        // The autonomous walking body is a rare, short-range detached scout,
        // never Migi's permanent topology. Any non-idle semantic state above
        // forces it back to the right-hand anchor.
        guard activity == .idle else {
            anchorDetachedScout(at: time)
            return .zero
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
        // A live stare-back owns facing; routine re-anchoring resumes after it.
        guard stareDirection == nil else { return }
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

        // A tired organism lowers its overall tone rather than moving faster.
        let fatigueEnergyScale = CGFloat(1 - 0.30 * fatigue)

        let actionBoost: CGFloat
        switch action {
        case .none, .blink:
            actionBoost = 0
        case .read, .checkPhone, .lookAround, .rapidNotes, .logicCount,
             .signalSampling, .agentHandoff, .agentTurn, .palmObserver:
            actionBoost = 0.08
        case .inspectHand, .sharpenTip, .protectiveShield, .stretch,
             .fineMotor, .organDrift, .storagePocket:
            actionBoost = 0.14
        case .recoveryCare, .calmDiagnosis:
            actionBoost = 0.04
        case .detachedScoutReturn, .subAgentScout:
            actionBoost = 0.12
        case .type:
            actionBoost = 0.1
        case .dormant:
            actionBoost = -0.18
        }

        let movementBoost: CGFloat = isMoving ? 0.16 : 0
        let ordinary = (
            min(base.energy * fatigueEnergyScale + actionBoost + movementBoost, 1),
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
