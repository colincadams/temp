import Foundation

/// When to ask the server about a piece the phone's model is unsure of, and whose answer to show (plan step A4).
public enum SecondOpinion {
    public static let defaultThreshold = 0.5
    public static let defaultMinViews = 3

    public enum Source: Equatable {
        case device
        case server
    }

    /// Whether to send a crop of the piece to the server's recognition service.
    ///
    /// - Parameters:
    ///   - topProbability: the on-device model's fused probability for its best shape; nil if it has none.
    ///   - views: views fused so far.
    ///   - alreadyRequested: a piece is sent at most once.
    public static func shouldRequest(topProbability: Double?, views: Int, alreadyRequested: Bool,
                                     threshold: Double = defaultThreshold, minViews: Int = defaultMinViews) -> Bool {
        guard !alreadyRequested, views >= minViews else { return false }
        guard let topProbability else { return true }
        return topProbability < threshold
    }

    /// Whose candidates to show for a piece.
    ///
    /// The server wins when its best score is at least `threshold` and higher than the phone's best probability.
    /// With no on-device answer to show at all, any server answer is used.
    ///
    /// - Parameters:
    ///   - deviceTop: probability of the best on-device candidate; nil if there is none.
    ///   - serverTop: score of the best server candidate; nil if the server was not asked or found nothing.
    public static func choose(deviceTop: Double?, serverTop: Double?, threshold: Double = defaultThreshold) -> Source {
        guard let serverTop else { return .device }
        guard let deviceTop else { return .server }
        return serverTop >= threshold && serverTop > deviceTop ? .server : .device
    }
}
