import Foundation

/// The user's hand resting on the table during part of a rendered sweep, for the replay.
///
/// The hand is a disc on the table (`radius`, 4 cm: a palm), put down at `firstFrame` and left there. In every frame
/// that shows it, it hides the pieces under it (their detections are removed: a detector cannot see through a hand) and
/// a fingertip at its edge (16 x 10 mm, skin-coloured) is detected as a piece, the phantom a hand makes. Its person mask
/// is what ARKit's segmentation would give: the pixels whose ray meets the disc, at 64 x 48.
///
/// Without masking, the fingertip is counted as a piece (it is seen in every frame showing it, so negative evidence
/// keeps it), and the pieces under the hand collect misses, so negative evidence sets them aside. With masking
/// (`ReplayRunner.Settings.handMasking`, as the app does), the fingertip is dropped and the hidden pieces get no misses.
public struct HandSimulation {
    /// Middle of the palm on the table (x, z, metres); nil for the middle of the pieces' area.
    public var position: SIMD2<Float>?
    public var radius: Float = 0.04
    /// Sweep frame at which the hand is put down; nil for two thirds of the way through.
    public var firstFrameSetting: Int?
    public var maskWidth = 64, maskHeight = 48

    public private(set) var firstFrame = 0

    public init(position: SIMD2<Float>? = nil, firstFrame: Int? = nil) {
        self.position = position
        self.firstFrameSetting = firstFrame
    }

    /// With the defaults filled in from the sweep.
    public func resolved(for sweep: ReplaySweep) -> HandSimulation {
        var hand = self
        if hand.position == nil, !sweep.pieces.isEmpty {
            let xs = sweep.pieces.map { $0.x }, zs = sweep.pieces.map { $0.z }
            hand.position = SIMD2((xs.min()! + xs.max()!) / 2, (zs.min()! + zs.max()!) / 2)
        }
        hand.firstFrame = firstFrameSetting ?? sweep.frames.count * 2 / 3
        return hand
    }

    public func covers(frame index: Int) -> Bool { index >= firstFrame }

    private var centre: SIMD2<Float> { position ?? .zero }

    /// The person mask of a view, or nil if the hand is not in it.
    public func mask(projector: TableProjector, imageWidth: Float, imageHeight: Float) -> PersonMask? {
        var values = [UInt8](repeating: 0, count: maskWidth * maskHeight)
        var any = false
        for j in 0..<maskHeight {
            for i in 0..<maskWidth {
                let px = (Float(i) + 0.5) * imageWidth / Float(maskWidth), py = (Float(j) + 0.5) * imageHeight / Float(maskHeight)
                guard let p = projector.point(px, py) else { continue }
                let d = SIMD2(p.x, p.z) - centre
                if (d * d).sum() <= radius * radius {
                    values[j * maskWidth + i] = 255
                    any = true
                }
            }
        }
        return any ? PersonMask(width: maskWidth, height: maskHeight, values: values) : nil
    }

    /// The fingertip's detection in a view, if it lies wholly inside the working frame.
    public func fingertip(projector: TableProjector, work: (step: Int, width: Int, height: Int)) -> DetectedBlob? {
        let tip = SIMD3<Float>(centre.x + radius * 0.75, projector.tableY, centre.y)
        guard let seen = projector.project(tip) else { return nil }
        let step = Float(work.step)
        let x = seen.pixel.x / step, y = seen.pixel.y / step
        guard let spot = projector.locate(workX: x, workY: y, step: step), spot.mmPerPixel > 0 else { return nil }
        let major = 16 / spot.mmPerPixel, minor = 10 / spot.mmPerPixel
        let minX = Int((x - major / 2).rounded(.down)), maxX = Int((x + major / 2).rounded(.up))
        let minY = Int((y - minor / 2).rounded(.down)), maxY = Int((y + minor / 2).rounded(.up))
        guard minX > 0, minY > 0, maxX < work.width - 1, maxY < work.height - 1 else { return nil }
        return DetectedBlob(minX: minX, minY: minY, maxX: maxX, maxY: maxY, area: max(1, Int(major * minor)),
                            cx: x, cy: y, major: major, minor: minor, r: 224, g: 172, b: 140)
    }
}
