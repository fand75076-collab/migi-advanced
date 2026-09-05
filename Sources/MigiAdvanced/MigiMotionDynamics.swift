import CoreGraphics
import Foundation
import simd

/// Authored animation time is integrated forward. A new throughput estimate
/// changes future cadence, never the phase of frames that already played.
struct MigiClipPlaybackClock {
    private var identity: String?
    private var startedAt: TimeInterval = 0
    private var sampledAt: TimeInterval = 0
    private var rate: Double = 1
    private(set) var elapsed: TimeInterval = 0
    private static let rateResponse: Double = 5

    mutating func sample(
        identity: String,
        startedAt: TimeInterval,
        time: TimeInterval,
        targetRate: Double
    ) -> TimeInterval {
        guard time.isFinite, startedAt.isFinite else { return elapsed }
        let target = min(max(targetRate.isFinite ? targetRate : 1, 0.05), 4)
        if self.identity != identity || self.startedAt != startedAt {
            self.identity = identity
            self.startedAt = startedAt
            sampledAt = startedAt
            elapsed = 0
            rate = target
        }
        // Semantic handoffs intentionally move startedAt into the future.
        // That lead-in must not consume the new gesture's authored frames.
        guard time > sampledAt else { return elapsed }
        let delta = time - sampledAt
        let response = Self.rateResponse
        let settledFraction = -expm1(-response * delta)
        elapsed += target * delta + (rate - target) * settledFraction / response
        rate += (target - rate) * settledFraction
        sampledAt = time
        return elapsed
    }
}

/// Frequency changes affect the next increment, independently of system uptime.
struct MigiBreathingPhase {
    private(set) var phase: Double = 0

    mutating func advance(deltaTime: TimeInterval, energy: CGFloat) -> CGFloat {
        let delta = max(deltaTime.isFinite ? deltaTime : 0, 0)
        let safeEnergy = Double(min(max(energy.isFinite ? energy : 0, 0), 1))
        phase = (phase + delta * (0.88 + safeEnergy * 0.08))
            .truncatingRemainder(dividingBy: 2 * .pi)
        return CGFloat(sin(phase))
    }
}

enum MigiDampedMotion {
    /// Exact critically damped step for a held target. Unlike Euler integration,
    /// this has the same response at 15, 30 and 60 Hz and after a late GPU frame.
    static func advance(
        value: inout SIMD2<Double>,
        velocity: inout SIMD2<Double>,
        target: SIMD2<Double>,
        stiffness: Double,
        deltaTime: TimeInterval
    ) {
        guard deltaTime.isFinite, deltaTime > 0 else { return }
        let omega = sqrt(max(stiffness.isFinite ? stiffness : 1, 1))
        let displacement = value - target
        let coefficient = velocity + displacement * omega
        let decay = exp(-omega * deltaTime)
        value = target + (displacement + coefficient * deltaTime) * decay
        velocity = (velocity - coefficient * omega * deltaTime) * decay
    }
}

struct MigiFrameRateGovernor {
    private(set) var current = 60
    private var pendingRate: Int?
    private var pendingSince: TimeInterval = 0
    static let settleDuration: TimeInterval = 0.55

    mutating func update(requested: Int, time: TimeInterval) -> Int {
        if requested >= current {
            current = requested
            pendingRate = nil
        } else if pendingRate != requested {
            pendingRate = requested
            pendingSince = time
        } else if time - pendingSince >= Self.settleDuration {
            current = requested
            pendingRate = nil
        }
        return current
    }
}

/// Normalized horizontal boundaries of two opaque lids. The upper lid travels
/// slightly farther; at full closure both meet below the eye's center.
struct MigiEyelidShape {
    let upperCut: CGFloat
    let lowerCut: CGFloat

    init(closure: CGFloat) {
        let amount = min(max(closure.isFinite ? closure : 0, 0), 1)
        upperCut = 1 - 1.12 * amount
        lowerCut = -1 + 0.88 * amount
    }
}

enum MigiBlinkEnvelope {
    static func sample(
        startedAt: TimeInterval?, releasedAt: TimeInterval?, time: TimeInterval
    ) -> CGFloat {
        guard let startedAt else { return 0 }
        let closing = MigiOrganicMath.smoothstep(
            edge0: 0, edge1: 0.09, value: CGFloat(time - startedAt)
        )
        guard let releasedAt, time >= releasedAt else { return closing }
        let closureAtRelease = MigiOrganicMath.smoothstep(
            edge0: 0, edge1: 0.09, value: CGFloat(releasedAt - startedAt)
        )
        let opening = MigiOrganicMath.smoothstep(
            edge0: 0, edge1: 0.15, value: CGFloat(time - releasedAt)
        )
        return closureAtRelease * (1 - opening)
    }
}
