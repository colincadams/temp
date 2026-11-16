import Foundation

/// How to fix the camera's exposure once it has settled on the table, so brightness (and so measured colour) stays the
/// same across the sweep and the shutter is short enough for sharp pictures.
///
/// A camera `distance` metres above the table moving sideways at `speed` m/s shifts the picture by
/// `fx * speed / distance` full-resolution pixels a second, so an exposure of `t` seconds smears it by
/// `fx * speed * t / distance` pixels, or that over `step` working pixels. Keeping the smear under `maxSmearWorkPixels`
/// working pixels (below which `SharpnessGate` never rejects a frame, ml/README.md) gives the longest exposure:
///
///     t = maxSmearWorkPixels * step * distance / (fx * speed)
///
/// It depends only on the field of view in working pixels, not on the video format: for the iPhone's wide camera
/// (about 466 working pixels of focal length at 640 working pixels across: fx about 2,800 at 3840 x 2160 with step 6,
/// or about 1,400 at 1920 x 1440 with step 3), 2 pixels at 0.3 m/s and 30 cm is 4.3 ms, about 1/230 s.
/// Indoors the auto exposure typically picks 1/60-1/30 s, so the shutter is usually shortened and the ISO raised
/// to keep the same brightness; if that would take the ISO over `isoLimit`, the scene is too dark: auto exposure is left
/// on and the user is asked to turn the light on.
public enum ExposurePlan {
    public struct Settings {
        /// The fastest sweep the frame gate allows (ScanEngine.maxSpeed).
        public var maxSpeed: Float = 0.30
        /// Smear allowed, in working pixels.
        public var maxSmearWorkPixels: Float = 2
        /// Nearest the camera is taken to be to the table (metres), so holding it low does not lengthen the shutter.
        public var minDistance: Float = 0.20
        public var maxDistance: Float = 0.60
        /// Highest ISO worth using: above it noise makes colours and fine edges unreliable.
        public var isoLimit: Float = 1000
        public init() {}
    }

    public enum Decision: Equatable {
        /// The current exposure is already short enough: lock it as it is.
        case lock
        /// Use this exposure duration (seconds) and ISO, which keep the brightness the auto exposure chose.
        case custom(duration: Double, iso: Float)
        /// Too dark for a short shutter: keep auto exposure, suggest the light. `neededISO` is what it would take.
        case tooDark(neededISO: Float)
    }

    /// The longest exposure (seconds) that keeps motion smear under the limit.
    /// - Parameters:
    ///   - fx: focal length in full-resolution pixels (`ARCamera.intrinsics`).
    ///   - step: full-resolution pixels per working pixel.
    ///   - distance: camera height above the table, metres.
    public static func longestExposure(fx: Float, step: Int, distance: Float, settings: Settings = Settings()) -> Double {
        guard fx > 0, settings.maxSpeed > 0 else { return 0 }
        let h = min(settings.maxDistance, max(settings.minDistance, distance))
        return Double(settings.maxSmearWorkPixels * Float(step) * h / (fx * settings.maxSpeed))
    }

    /// What to do with the exposure the camera has settled on.
    /// - Parameters:
    ///   - duration, iso: the current (auto) exposure.
    ///   - longest: from `longestExposure`.
    ///   - minDuration, minISO, maxISO: the capture format's limits.
    public static func decide(duration: Double, iso: Float, longest: Double, minDuration: Double, minISO: Float, maxISO: Float,
                              settings: Settings = Settings()) -> Decision {
        guard duration > 0, iso > 0, longest > 0 else { return .lock }
        if duration <= longest { return .lock }
        let target = max(longest, minDuration)
        // Same brightness: exposure time times gain stays constant.
        let needed = iso * Float(duration / target)
        if needed > min(settings.isoLimit, maxISO) { return .tooDark(neededISO: needed) }
        return .custom(duration: target, iso: max(minISO, needed))
    }
}
