import Foundation

/// ARKit's camera tracking state, without ARKit (`ARCamera.TrackingState` and its `Reason`).
public enum TrackingCondition: Equatable {
    case normal
    case initializing
    case excessiveMotion
    case insufficientFeatures
    case relocalizing
    case notAvailable
}

/// What to do after the camera's tracking has been interrupted or lost.
///
/// While tracking is limited the app skips frames, so nothing is matched. After an interruption (another app took the
/// camera, the phone was locked, the camera was covered) ARKit is asked to relocalise against the map it had, which puts
/// the world back where it was; until it reports normal tracking again no detection may be matched to the pieces
/// already found, since the world may still be shifted. If relocalising takes longer than `relocaliseTimeout`, the user
/// is told plainly and offered a fresh pass: keep the pieces found so far, start a new map and coverage, and never match
/// new detections to the old pieces (`PieceTracker.startNewPass`). If ARKit relocalises after all while the offer is
/// showing, the offer is withdrawn and scanning carries on.
///
/// A value type with no locking: use it from one queue.
public struct TrackingRecovery {
    public enum Phase: Equatable {
        /// Tracking as usual (it may still be briefly limited, e.g. by fast motion).
        case tracking
        /// The session is interrupted: no frames.
        case interrupted
        /// Waiting for ARKit to relocalise; `since` is the time of the first frame after the interruption.
        case relocalising(since: TimeInterval?)
        /// Relocalising took too long: offer a fresh pass.
        case failed
    }

    public var relocaliseTimeout: TimeInterval = 5
    public private(set) var phase = Phase.tracking

    public init(relocaliseTimeout: TimeInterval = 5) {
        self.relocaliseTimeout = relocaliseTimeout
    }

    public mutating func reset() { phase = .tracking }

    public mutating func interrupted() { phase = .interrupted }

    public mutating func interruptionEnded() { phase = .relocalising(since: nil) }

    /// The user chose to keep waiting for ARKit to relocalise.
    public mutating func keepTrying() {
        if phase == .failed { phase = .relocalising(since: nil) }
    }

    /// The user chose a fresh pass (the app re-runs the session with a new map).
    public mutating func startedFreshPass() { phase = .tracking }

    /// Feed every frame's tracking condition (processed or not), with the frame's time.
    public mutating func update(_ condition: TrackingCondition, time: TimeInterval) {
        switch phase {
        case .tracking:
            // ARKit can start relocalising by itself, e.g. after the app came back from the background.
            if condition == .relocalizing { phase = .relocalising(since: time) }
        case .interrupted:
            // A frame arrived without an "interruption ended" call: treat it as one.
            phase = condition == .normal ? .tracking : .relocalising(since: time)
        case .relocalising(let since):
            if condition == .normal {
                phase = .tracking
            } else if let since {
                if time - since > relocaliseTimeout { phase = .failed }
            } else {
                phase = .relocalising(since: time)
            }
        case .failed:
            if condition == .normal { phase = .tracking }
        }
    }

    /// Whether this frame's detections may be matched to the pieces already found.
    public func canMatch(_ condition: TrackingCondition) -> Bool {
        phase == .tracking && condition == .normal
    }

    /// Whether to offer the user a fresh pass.
    public var offerFreshPass: Bool { phase == .failed }

    /// One plain sentence for the scan screen, or nil when tracking is normal and nothing needs saying.
    public func hint(_ condition: TrackingCondition) -> String? {
        if phase == .failed {
            return "The camera has lost track of where the scan was. Keep the pieces found so far and start a fresh pass?"
        }
        if phase == .interrupted { return "Camera paused." }
        if case .relocalising = phase, condition != .normal {
            return "Finding its place again. Point the phone at the part of the table you were scanning."
        }
        return TrackingRecovery.hint(for: condition)
    }

    public static func hint(for condition: TrackingCondition) -> String? {
        switch condition {
        case .normal: return nil
        case .initializing: return "Getting started. Move the phone slowly over the table."
        case .excessiveMotion: return "Moving too fast for the camera to follow. Slow down."
        case .insufficientFeatures: return "Too little detail in view. Add light, or bring the table's edge into view."
        case .relocalizing: return "Finding its place again. Point the phone at the part of the table you were scanning."
        case .notAvailable: return "Camera tracking is not available. Hold still for a moment."
        }
    }
}
