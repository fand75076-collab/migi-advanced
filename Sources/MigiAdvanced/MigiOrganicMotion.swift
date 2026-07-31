import CoreGraphics
import Foundation

/// Small, renderer-only controls for Migi's continuous tissue motion.
///
/// Values are deliberately expressed in normalized sprite coordinates so the
/// same motion remains subtle at every overlay size. The presets below are the
/// single place where clip semantics alter the motion; authored props and
/// facial landmarks never receive a broad whole-image warp.
struct MigiOrganicMotionTuning: Equatable {
    let waveSpeed: CGFloat
    let counterWaveSpeed: CGFloat
    let rootToTipPhaseLag: CGFloat
    let appendagePhaseStride: CGFloat
    let lateralGain: CGFloat
    let axialGain: CGFloat
    let localBreathAmount: CGFloat
    let localBreathSpeed: CGFloat
    let volumeConservation: CGFloat
    let rootAnchorLength: CGFloat
    let amplitudeScale: CGFloat
    let transitionBand: CGFloat
    let transitionRipple: CGFloat
    let transitionFlow: CGFloat
    let organEmergenceExponent: CGFloat

    static func preset(
        for clipName: String,
        containsProp: Bool
    ) -> MigiOrganicMotionTuning {
        var tuning = MigiOrganicMotionTuning(
            waveSpeed: 1.14,
            counterWaveSpeed: 0.71,
            rootToTipPhaseLag: 4.8,
            appendagePhaseStride: 1.37,
            lateralGain: 1,
            axialGain: 0.46,
            localBreathAmount: 0.0055,
            localBreathSpeed: 0.82,
            volumeConservation: 0.82,
            rootAnchorLength: 0.26,
            amplitudeScale: 1,
            transitionBand: 0.16,
            transitionRipple: 0.035,
            transitionFlow: 0.010,
            organEmergenceExponent: 1.22
        )

        switch clipName {
        case "normal-hand":
            tuning = tuning.replacing(
                waveSpeed: 0.58,
                counterWaveSpeed: 0.36,
                rootToTipPhaseLag: 3.6,
                appendagePhaseStride: 1.29,
                lateralGain: 0.36,
                axialGain: 0.22,
                localBreathAmount: 0.0032,
                localBreathSpeed: 0.48,
                volumeConservation: 0.96,
                rootAnchorLength: 0.34,
                amplitudeScale: 0.42,
                transitionBand: 0.21,
                transitionRipple: 0.018,
                transitionFlow: 0.006,
                organEmergenceExponent: 1.42
            )
        case "palm-observer":
            tuning = tuning.replacing(
                waveSpeed: 0.94,
                counterWaveSpeed: 0.57,
                rootToTipPhaseLag: 5.8,
                appendagePhaseStride: 1.88,
                lateralGain: 0.82,
                axialGain: 0.40,
                localBreathAmount: 0.0048,
                volumeConservation: 0.94,
                rootAnchorLength: 0.32,
                amplitudeScale: 0.82,
                transitionBand: 0.15,
                transitionRipple: 0.034,
                transitionFlow: 0.008,
                organEmergenceExponent: 1.48
            )
        case "complete-sleep":
            tuning = tuning.replacing(
                waveSpeed: 0.31,
                counterWaveSpeed: 0.22,
                rootToTipPhaseLag: 2.8,
                lateralGain: 0.18,
                axialGain: 0.13,
                localBreathAmount: 0.0018,
                localBreathSpeed: 0.28,
                volumeConservation: 0.98,
                rootAnchorLength: 0.38,
                amplitudeScale: 0.24,
                transitionBand: 0.24,
                transitionRipple: 0.012,
                transitionFlow: 0.004,
                organEmergenceExponent: 1.62
            )
        case "detached-scout-return":
            tuning = tuning.replacing(
                waveSpeed: 1.38,
                counterWaveSpeed: 0.84,
                rootToTipPhaseLag: 6.0,
                appendagePhaseStride: 1.79,
                lateralGain: 1.14,
                axialGain: 0.58,
                localBreathAmount: 0.0058,
                amplitudeScale: 1.12,
                transitionBand: 0.14,
                transitionRipple: 0.038,
                transitionFlow: 0.012
            )
        case "protective-shield":
            tuning = tuning.replacing(
                waveSpeed: 1.24,
                counterWaveSpeed: 0.76,
                rootToTipPhaseLag: 6.5,
                appendagePhaseStride: 1.93,
                lateralGain: 0.76,
                axialGain: 0.64,
                localBreathAmount: 0.0054,
                volumeConservation: 0.98,
                rootAnchorLength: 0.34,
                amplitudeScale: 0.88,
                transitionBand: 0.12,
                transitionRipple: 0.024,
                transitionFlow: 0.014,
                organEmergenceExponent: 1.12
            )
        case "dormant":
            tuning = tuning.replacing(
                waveSpeed: 0.48,
                counterWaveSpeed: 0.32,
                rootToTipPhaseLag: 3.2,
                lateralGain: 0.38,
                axialGain: 0.24,
                localBreathAmount: 0.0032,
                localBreathSpeed: 0.42,
                amplitudeScale: 0.45,
                transitionBand: 0.22,
                transitionFlow: 0.006,
                organEmergenceExponent: 1.45
            )
        case "failed":
            tuning = tuning.replacing(
                waveSpeed: 0.64,
                counterWaveSpeed: 0.45,
                lateralGain: 0.52,
                axialGain: 0.30,
                localBreathAmount: 0.0038,
                amplitudeScale: 0.58,
                transitionBand: 0.20
            )
        case "sharpen-tip":
            tuning = tuning.replacing(
                waveSpeed: 1.52,
                counterWaveSpeed: 0.93,
                rootToTipPhaseLag: 6.4,
                appendagePhaseStride: 1.61,
                lateralGain: 0.72,
                axialGain: 0.62,
                localBreathAmount: 0.0062,
                volumeConservation: 0.94,
                amplitudeScale: 0.82,
                transitionBand: 0.12,
                transitionRipple: 0.022,
                transitionFlow: 0.013,
                organEmergenceExponent: 1.08
            )
        case "look-around":
            tuning = tuning.replacing(
                waveSpeed: 1.06,
                rootToTipPhaseLag: 5.7,
                appendagePhaseStride: 1.83,
                lateralGain: 1.18,
                axialGain: 0.52,
                localBreathAmount: 0.0068,
                amplitudeScale: 1.16,
                transitionRipple: 0.045
            )
        case "signal-sampling":
            tuning = tuning.replacing(
                waveSpeed: 1.12,
                counterWaveSpeed: 0.67,
                rootToTipPhaseLag: 6.1,
                appendagePhaseStride: 2.17,
                lateralGain: 1.08,
                axialGain: 0.48,
                localBreathAmount: 0.0058,
                amplitudeScale: 1.10,
                transitionBand: 0.14,
                transitionRipple: 0.048,
                transitionFlow: 0.009,
                organEmergenceExponent: 1.34
            )
        case "organ-drift":
            tuning = tuning.replacing(
                waveSpeed: 0.92,
                counterWaveSpeed: 0.58,
                rootToTipPhaseLag: 5.9,
                appendagePhaseStride: 2.09,
                lateralGain: 1.28,
                axialGain: 0.58,
                localBreathAmount: 0.0078,
                amplitudeScale: 1.28,
                transitionRipple: 0.050
            )
        case "stretch":
            tuning = tuning.replacing(
                waveSpeed: 0.88,
                rootToTipPhaseLag: 5.4,
                lateralGain: 1.12,
                axialGain: 0.70,
                localBreathAmount: 0.0070,
                volumeConservation: 0.96,
                amplitudeScale: 1.18,
                transitionFlow: 0.012
            )
        case "fine-motor", "inspect-hand":
            tuning = tuning.replacing(
                waveSpeed: 1.22,
                rootToTipPhaseLag: 5.3,
                appendagePhaseStride: 1.69,
                lateralGain: 0.92,
                axialGain: 0.42,
                localBreathAmount: 0.0052,
                amplitudeScale: 0.96
            )
        case "storage-pocket":
            tuning = tuning.replacing(
                waveSpeed: 0.96,
                counterWaveSpeed: 0.54,
                rootToTipPhaseLag: 5.0,
                appendagePhaseStride: 1.58,
                lateralGain: 0.70,
                axialGain: 0.36,
                localBreathAmount: 0.0042,
                volumeConservation: 0.92,
                amplitudeScale: 0.78,
                transitionBand: 0.18,
                transitionRipple: 0.020,
                transitionFlow: 0.006
            )
        case "recovery-care":
            tuning = tuning.replacing(
                waveSpeed: 0.82,
                counterWaveSpeed: 0.49,
                rootToTipPhaseLag: 4.7,
                appendagePhaseStride: 1.47,
                lateralGain: 0.66,
                axialGain: 0.32,
                localBreathAmount: 0.0045,
                localBreathSpeed: 0.62,
                amplitudeScale: 0.76,
                transitionBand: 0.19,
                transitionRipple: 0.018,
                transitionFlow: 0.006
            )
        case "rapid-notes", "logic-count":
            tuning = tuning.replacing(
                waveSpeed: 1.34,
                counterWaveSpeed: 0.82,
                rootToTipPhaseLag: 5.1,
                appendagePhaseStride: 1.76,
                lateralGain: 0.94,
                axialGain: 0.48,
                localBreathAmount: 0.0050,
                amplitudeScale: 1.02
            )
        case "calm-diagnosis":
            tuning = tuning.replacing(
                waveSpeed: 0.88,
                counterWaveSpeed: 0.57,
                rootToTipPhaseLag: 5.6,
                appendagePhaseStride: 1.91,
                lateralGain: 0.78,
                axialGain: 0.38,
                localBreathAmount: 0.0046,
                localBreathSpeed: 0.68,
                amplitudeScale: 0.82,
                transitionBand: 0.15,
                transitionRipple: 0.032,
                transitionFlow: 0.008,
                organEmergenceExponent: 1.30
            )
        case "patrol", "patrol-left":
            tuning = tuning.replacing(
                waveSpeed: 1.30,
                counterWaveSpeed: 0.79,
                rootToTipPhaseLag: 5.6,
                appendagePhaseStride: 1.72,
                lateralGain: 1.10,
                axialGain: 0.54,
                localBreathAmount: 0.0060,
                amplitudeScale: 1.10
            )
        case "turn-left", "turn-right":
            tuning = tuning.replacing(
                waveSpeed: 1.42,
                rootToTipPhaseLag: 6.0,
                appendagePhaseStride: 1.88,
                lateralGain: 1.14,
                axialGain: 0.56,
                localBreathAmount: 0.0052,
                amplitudeScale: 1.12,
                transitionBand: 0.13,
                transitionRipple: 0.042,
                transitionFlow: 0.012
            )
        default:
            break
        }

        if containsProp {
            // Tissue can move around a tool, but the tool itself is protected
            // by rigid zones in the deformation profile.
            tuning = tuning.replacing(
                lateralGain: tuning.lateralGain * 0.78,
                axialGain: tuning.axialGain * 0.72,
                localBreathAmount: min(tuning.localBreathAmount, 0.0042),
                amplitudeScale: tuning.amplitudeScale * 0.78,
                transitionBand: max(tuning.transitionBand, 0.18),
                transitionRipple: min(tuning.transitionRipple, 0.026),
                transitionFlow: min(tuning.transitionFlow, 0.007)
            )
        }
        return tuning
    }

    func forAuthoredFrameHandoff() -> MigiOrganicMotionTuning {
        replacing(
            transitionBand: max(transitionBand, 0.30),
            transitionRipple: min(transitionRipple, 0.018),
            transitionFlow: min(transitionFlow, 0.005),
            organEmergenceExponent: 1.08
        )
    }

    private func replacing(
        waveSpeed: CGFloat? = nil,
        counterWaveSpeed: CGFloat? = nil,
        rootToTipPhaseLag: CGFloat? = nil,
        appendagePhaseStride: CGFloat? = nil,
        lateralGain: CGFloat? = nil,
        axialGain: CGFloat? = nil,
        localBreathAmount: CGFloat? = nil,
        localBreathSpeed: CGFloat? = nil,
        volumeConservation: CGFloat? = nil,
        rootAnchorLength: CGFloat? = nil,
        amplitudeScale: CGFloat? = nil,
        transitionBand: CGFloat? = nil,
        transitionRipple: CGFloat? = nil,
        transitionFlow: CGFloat? = nil,
        organEmergenceExponent: CGFloat? = nil
    ) -> MigiOrganicMotionTuning {
        MigiOrganicMotionTuning(
            waveSpeed: waveSpeed ?? self.waveSpeed,
            counterWaveSpeed: counterWaveSpeed ?? self.counterWaveSpeed,
            rootToTipPhaseLag: rootToTipPhaseLag ?? self.rootToTipPhaseLag,
            appendagePhaseStride:
                appendagePhaseStride ?? self.appendagePhaseStride,
            lateralGain: lateralGain ?? self.lateralGain,
            axialGain: axialGain ?? self.axialGain,
            localBreathAmount: localBreathAmount ?? self.localBreathAmount,
            localBreathSpeed: localBreathSpeed ?? self.localBreathSpeed,
            volumeConservation:
                volumeConservation ?? self.volumeConservation,
            rootAnchorLength: rootAnchorLength ?? self.rootAnchorLength,
            amplitudeScale: amplitudeScale ?? self.amplitudeScale,
            transitionBand: transitionBand ?? self.transitionBand,
            transitionRipple: transitionRipple ?? self.transitionRipple,
            transitionFlow: transitionFlow ?? self.transitionFlow,
            organEmergenceExponent:
                organEmergenceExponent ?? self.organEmergenceExponent
        )
    }
}

enum MigiTissueTransitionRole {
    case outgoing
    case incoming
}

/// A spatial replacement front that starts at the anchored wrist/base and
/// travels toward the tips. Outgoing and incoming cells use complementary
/// visibility, so a handoff replaces local tissue instead of fading two whole
/// bodies through one another.
struct MigiTissueTransition {
    let progress: CGFloat
    let role: MigiTissueTransitionRole
    let tuning: MigiOrganicMotionTuning
    let rigidSwitchStart: CGFloat
    let rigidSwitchEnd: CGFloat

    init(
        progress: CGFloat,
        role: MigiTissueTransitionRole,
        tuning: MigiOrganicMotionTuning,
        rigidSwitchStart: CGFloat = 0.46,
        rigidSwitchEnd: CGFloat = 0.60
    ) {
        self.progress = MigiOrganicMath.clamp(progress)
        self.role = role
        self.tuning = tuning
        self.rigidSwitchStart = rigidSwitchStart
        self.rigidSwitchEnd = max(rigidSwitchEnd, rigidSwitchStart + 0.01)
    }

    func visibility(
        rootDistance: CGFloat,
        displayX: CGFloat,
        rigidity: CGFloat
    ) -> CGFloat {
        let incoming = incomingVisibility(
            rootDistance: rootDistance,
            displayX: displayX,
            rigidity: rigidity
        )
        switch role {
        case .incoming:
            return incoming
        case .outgoing:
            return 1 - incoming
        }
    }

    func organVisibility(
        rootDistance: CGFloat,
        displayX: CGFloat,
        rigidity: CGFloat
    ) -> CGFloat {
        let value = visibility(
            rootDistance: rootDistance,
            displayX: displayX,
            rigidity: rigidity
        )
        switch role {
        case .incoming:
            return pow(value, tuning.organEmergenceExponent)
        case .outgoing:
            return pow(value, 0.84)
        }
    }

    func flowOffset(
        rootDistance: CGFloat,
        displayX: CGFloat,
        rigidity: CGFloat
    ) -> CGPoint {
        let incoming = incomingVisibility(
            rootDistance: rootDistance,
            displayX: displayX,
            rigidity: rigidity
        )
        let edge = 4 * incoming * (1 - incoming)
        let tissue = 1 - MigiOrganicMath.clamp(rigidity)
        let anchor = MigiOrganicMath.smoothstep(
            edge0: 0.04,
            edge1: max(tuning.rootAnchorLength, 0.08),
            value: rootDistance
        )
        let strength = tuning.transitionFlow * edge * tissue * anchor
        return CGPoint(
            x: (0.5 - displayX) * strength * 0.42,
            y: -strength
        )
    }

    private func incomingVisibility(
        rootDistance: CGFloat,
        displayX: CGFloat,
        rigidity: CGFloat
    ) -> CGFloat {
        let band = max(tuning.transitionBand, 0.03)
        let easedProgress = MigiOrganicMath.smootherstep(progress)
        let front = -band + easedProgress * (1 + 2 * band)
        let root = MigiOrganicMath.clamp(rootDistance)
        let edgeEnvelope = sin(root * .pi)
        let ripple =
            sin(displayX * .pi * 3.25 + easedProgress * .pi * 1.4)
                * tuning.transitionRipple * edgeEnvelope
        let tissueVisibility =
            1 - MigiOrganicMath.smoothstep(
                edge0: front - band,
                edge1: front + band,
                value: root + ripple
            )
        let rigidVisibility = MigiOrganicMath.smoothstep(
            edge0: rigidSwitchStart,
            edge1: rigidSwitchEnd,
            value: easedProgress
        )
        let rigidMix = MigiOrganicMath.clamp(rigidity)
        return MigiOrganicMath.clamp(
            tissueVisibility * (1 - rigidMix) + rigidVisibility * rigidMix
        )
    }
}

enum MigiOrganicMath {
    static func clamp(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }

    static func smoothstep(
        edge0: CGFloat,
        edge1: CGFloat,
        value: CGFloat
    ) -> CGFloat {
        guard edge1 > edge0 else { return value >= edge1 ? 1 : 0 }
        let t = clamp((value - edge0) / (edge1 - edge0))
        return t * t * (3 - 2 * t)
    }

    static func smootherstep(_ value: CGFloat) -> CGFloat {
        let t = clamp(value)
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    static func appendagePhase(
        index: Int,
        sourceX: CGFloat,
        stride: CGFloat
    ) -> CGFloat {
        CGFloat(index) * stride + (sourceX - 0.5) * 1.73
    }
}
