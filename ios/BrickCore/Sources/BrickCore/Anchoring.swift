import Foundation

// How ScanEngine uses this (see `ScanEngine.applyAnchorCorrections` and `anchorNewPieces`):
//
//     private var anchorSet = AnchorSet()            // the ARAnchors the engine made, and which to store a new piece against
//     private var anchoring = PieceAnchoring()       // which anchor each piece is stored against
//
//     // each processed frame, before matching: move every piece whose anchor ARKit has moved
//     anchorSet.moveCamera(to: cameraPosition)
//     let current = Dictionary(frame.anchors.filter { anchorSet.owns($0.identifier) }.map { ($0.identifier, Matrix4($0.transform)) })
//     for correction in anchoring.corrections(current: current) {
//         for id in correction.pieces { tracker.piece(id: id).map { tracker.move($0, by: correction.motion) } }
//     }
//     // after matching: store each new piece against `anchorSet.anchor(for:)`, or add an ARAnchor at it and use that
//
// Why anchors of our own rather than the table's plane anchor: ARKit corrects its map locally (a loop closure bends the
// part of the map it closes over), so one anchor for a whole table would carry a correction made at one end to pieces at
// the other, and none of the drift built up after the plane was found. The plane anchor can also be merged away into a
// neighbouring plane. ARKit keeps user anchors where they were in the scene, so each anchor's change is the map
// correction near it, as of when it was made: see `AnchorSet` for which anchor a piece is stored against.

/// Rigid-transform helpers for `Matrix4` (rotation and translation only, as ARKit's anchor and camera transforms).
extension Matrix4 {
    public static func * (a: Matrix4, b: Matrix4) -> Matrix4 {
        Matrix4(a * b.columns.0, a * b.columns.1, a * b.columns.2, a * b.columns.3)
    }

    /// A transform that only moves points by `t`.
    public static func translation(_ t: SIMD3<Float>) -> Matrix4 {
        Matrix4(SIMD4(1, 0, 0, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 1, 0), SIMD4(t.x, t.y, t.z, 1))
    }

    /// A turn of `angle` radians about the vertical (y) axis through `pivot`, then a move by `shift`.
    public static func yaw(_ angle: Float, about pivot: SIMD3<Float> = .zero, then shift: SIMD3<Float> = .zero) -> Matrix4 {
        let c = cos(angle), s = sin(angle)
        // Rotation about y: x' = c x + s z, z' = -s x + c z.
        let r = Matrix4(SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(0, 0, 0, 1))
        return translation(pivot + shift) * r * translation(-pivot)
    }

    public var translationPart: SIMD3<Float> { SIMD3(columns.3.x, columns.3.y, columns.3.z) }

    /// The inverse of a rigid transform: the rotation transposed, and the translation turned back.
    public var rigidInverse: Matrix4 {
        let c0 = SIMD3<Float>(columns.0.x, columns.0.y, columns.0.z)
        let c1 = SIMD3<Float>(columns.1.x, columns.1.y, columns.1.z)
        let c2 = SIMD3<Float>(columns.2.x, columns.2.y, columns.2.z)
        // The rows of the rotation are the columns of its inverse (its transpose); the translation becomes -R^T t,
        // whose components are the columns of R dotted with t.
        let r0 = SIMD3<Float>(c0.x, c1.x, c2.x), r1 = SIMD3<Float>(c0.y, c1.y, c2.y), r2 = SIMD3<Float>(c0.z, c1.z, c2.z)
        let t = translationPart
        let it = -SIMD3<Float>((c0 * t).sum(), (c1 * t).sum(), (c2 * t).sum())
        return Matrix4(SIMD4(r0.x, r0.y, r0.z, 0), SIMD4(r1.x, r1.y, r1.z, 0), SIMD4(r2.x, r2.y, r2.z, 0), SIMD4(it.x, it.y, it.z, 1))
    }

    public func transformPoint(_ p: SIMD3<Float>) -> SIMD3<Float> {
        let v = self * SIMD4<Float>(p.x, p.y, p.z, 1)
        return SIMD3(v.x, v.y, v.z)
    }

    public func transformVector(_ v: SIMD3<Float>) -> SIMD3<Float> {
        let w = self * SIMD4<Float>(v.x, v.y, v.z, 0)
        return SIMD3(w.x, w.y, w.z)
    }

    /// Angle of the rotation part, radians (0 for a pure translation).
    public var rotationAngle: Float {
        let trace = columns.0.x + columns.1.y + columns.2.z
        return acos(max(-1, min(1, (trace - 1) / 2)))
    }
}

/// Storing a point against an anchor, and finding it again after the anchor has moved.
public enum AnchorMath {
    /// The point in the anchor's own coordinates: what stays fixed while ARKit refines the map.
    public static func offset(of point: SIMD3<Float>, from anchor: Matrix4) -> SIMD3<Float> {
        anchor.rigidInverse.transformPoint(point)
    }

    /// Where a stored offset lies in world space with the anchor where it is now.
    public static func point(offset: SIMD3<Float>, in anchor: Matrix4) -> SIMD3<Float> {
        anchor.transformPoint(offset)
    }

    /// The motion that carries anything stored against an anchor from where it was (`from`) to where the anchor now is
    /// (`to`): `point(offset(p, from), in: to)` for every point p, as one transform, so velocities and levers can be
    /// turned with it as well.
    public static func motion(from: Matrix4, to: Matrix4) -> Matrix4 {
        to * from.rigidInverse
    }

    /// The anchor nearest to a point on the table (horizontal distance), or nil if there are none.
    public static func nearest(to point: SIMD3<Float>, among anchors: [UUID: Matrix4]) -> UUID? {
        var best: (id: UUID, d: Float)?
        for (id, transform) in anchors {
            let t = transform.translationPart
            let dx = t.x - point.x, dz = t.z - point.z
            let d = dx * dx + dz * dz
            // Ties broken by id so the choice does not depend on dictionary order.
            if best == nil || d < best!.d || (d == best!.d && id.uuidString < best!.id.uuidString) { best = (id, d) }
        }
        return best?.id
    }
}

/// The app's anchors, and which one a newly found piece is stored against.
///
/// An anchor is only as good as the part of ARKit's map it is tied to. ARKit ties an anchor to the map as it was where
/// and when the anchor was made; a later correction moves the anchor by the correction that map needed. A piece placed
/// while the map had drifted further needs the correction of *that* moment, so it must be stored against an anchor made
/// nearby in space and soon before in camera travel. The rule: use the nearest anchor within `reach` of the piece made
/// no more than `maxTravel` of camera movement ago; otherwise make a new anchor at the piece. On the replay's rendered
/// sweeps (65 cm of travel over a 30 x 22 cm table) this made 4 to 12 anchors; a long scan over a big table makes a few
/// dozen to a couple of hundred, which ARKit handles. A fixed grid of anchors (one per 20 cm square, made the first time
/// the sweep finds a piece in it) is simpler, and does as well on the replay, whose drift is the same over the whole
/// first row (`DriftSimulation`); but its anchors are made in the first frames over each square, so on a real sweep
/// they cannot carry drift that builds up while the camera keeps coming back over the same square. The travel limit is
/// what keeps an anchor's map and its pieces' map the same.
public struct AnchorSet {
    public struct Settings {
        /// Farthest a piece may be from its anchor (metres): a residual anchor turn of 0.2 degrees then moves it < 0.4 mm.
        public var reach: Float = 0.10
        /// Most camera travel (metres) since an anchor was made for a new piece to be stored against it.
        public var maxTravel: Float = 0.15
        public init() {}
    }

    public struct Anchor {
        public var id: UUID
        /// Where it was made, in the world of that moment.
        public var position: SIMD3<Float>
        /// Camera travel (`AnchorSet.travelled`) when it was made.
        public var madeAt: Float
    }

    public let settings: Settings
    public private(set) var anchors: [UUID: Anchor] = [:]
    /// Camera travel so far, metres (horizontal), from `moveCamera`.
    public private(set) var travelled: Float = 0
    private var lastCamera: SIMD3<Float>?

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public mutating func reset() {
        anchors.removeAll()
        travelled = 0
        lastCamera = nil
    }

    public func owns(_ id: UUID) -> Bool { anchors[id] != nil }

    /// Count the camera's movement (call once per processed frame).
    public mutating func moveCamera(to camera: SIMD3<Float>) {
        if let lastCamera {
            let dx = camera.x - lastCamera.x, dz = camera.z - lastCamera.z
            travelled += (dx * dx + dz * dz).squareRoot()
        }
        lastCamera = camera
    }

    /// The anchor to store a new piece at `point` against, or nil: make one (`anchorTransform`, then `register`).
    public func anchor(for point: SIMD3<Float>) -> UUID? {
        var best: (id: UUID, d: Float)?
        for (id, anchor) in anchors where travelled - anchor.madeAt <= settings.maxTravel {
            let dx = anchor.position.x - point.x, dz = anchor.position.z - point.z
            let d = (dx * dx + dz * dz).squareRoot()
            guard d <= settings.reach else { continue }
            if best == nil || d < best!.d || (d == best!.d && id.uuidString < best!.id.uuidString) { best = (id, d) }
        }
        return best?.id
    }

    /// Where a new anchor for a piece at `point` goes: at the piece, on the table, upright.
    public func anchorTransform(for point: SIMD3<Float>, tableY: Float) -> Matrix4 {
        .translation(SIMD3(point.x, tableY, point.z))
    }

    public mutating func register(_ id: UUID, at transform: Matrix4) {
        anchors[id] = Anchor(id: id, position: transform.translationPart, madeAt: travelled)
    }
}

/// Which anchor each piece is stored against, and the corrections ARKit has made to those anchors since.
///
/// The tracker keeps world positions (and, for tall pieces, the views that place them). Storing each as an offset from
/// its anchor and re-expressing it every frame is the same as applying, to everything the tracker holds about the piece,
/// the anchor's motion since it was last applied (`AnchorMath.motion`). That is what `corrections` hands back, so the
/// tracker does not need to know about anchors.
public struct PieceAnchoring {
    public struct Settings {
        /// Anchor changes smaller than this (metres, at the anchor) and this (radians) are let build up rather than
        /// applied: ARKit nudges anchors by fractions of a millimetre all the time.
        public var minShift: Float = 0.0005
        public var minTurn: Float = 0.001
        public init() {}
    }

    public struct Correction {
        public var anchor: UUID
        public var pieces: [UUID]
        public var motion: Matrix4
    }

    public let settings: Settings
    /// The piece's anchor.
    public private(set) var anchorOf: [UUID: UUID] = [:]
    /// Each anchor's transform as the bound pieces' positions last saw it.
    public private(set) var applied: [UUID: Matrix4] = [:]
    private var piecesOf: [UUID: [UUID]] = [:]

    public init(settings: Settings = Settings()) {
        self.settings = settings
    }

    public mutating func reset() {
        anchorOf.removeAll()
        applied.removeAll()
        piecesOf.removeAll()
    }

    /// Store a piece against an anchor whose transform is `transform` now (its position is already in today's world).
    public mutating func bind(piece: UUID, to anchor: UUID, transform: Matrix4) {
        if let old = anchorOf[piece] { piecesOf[old]?.removeAll { $0 == piece } }
        anchorOf[piece] = anchor
        piecesOf[anchor, default: []].append(piece)
        if applied[anchor] == nil { applied[anchor] = transform }
    }

    public mutating func forget(piece: UUID) {
        guard let anchor = anchorOf.removeValue(forKey: piece) else { return }
        piecesOf[anchor]?.removeAll { $0 == piece }
    }

    /// The corrections to apply this frame, given every anchor's current transform. Anchors missing from `current`
    /// (not reported this frame) are left as they are.
    public mutating func corrections(current: [UUID: Matrix4]) -> [Correction] {
        var out: [Correction] = []
        for (anchor, last) in applied {
            guard let now = current[anchor] else { continue }
            let motion = AnchorMath.motion(from: last, to: now)
            // Shift of the anchor itself, and the turn.
            let shift = TableMath.distance(now.translationPart, last.translationPart)
            guard shift >= settings.minShift || motion.rotationAngle >= settings.minTurn else { continue }
            applied[anchor] = now
            let pieces = piecesOf[anchor] ?? []
            if !pieces.isEmpty { out.append(Correction(anchor: anchor, pieces: pieces, motion: motion)) }
        }
        return out.sorted { $0.anchor.uuidString < $1.anchor.uuidString }
    }
}
