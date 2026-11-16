import Foundation

// How ScanEngine uses this (in `process(frame:...)`, when ARKit's person segmentation is on):
//
//     let mask = ScanEngine.personMask(of: frame)                       // copies `frame.segmentationBuffer`, or nil
//     blobs = HandMasking.filter(blobs, mask: mask, step: work.step, imageWidth: w, imageHeight: h).kept
//     ...
//     let occluded = HandMasking.occluded(pieces: tracker.currentPieces, projector: projector, mask: mask, ...)
//     visibility.record(..., occluded: occluded)                        // a hand over a piece is not a miss
//
// The mask is far coarser than the camera image (ARKit's is 256 x 192 for a 1920 x 1440 or 3840 x 2160 frame, in the
// same orientation and field of view), so every box is mapped from full-resolution image pixels to mask pixels by the
// ratio of the widths and of the heights.

/// ARKit's person segmentation for one frame: which pixels show a person (in practice the user's hand and arm).
public struct PersonMask {
    public let width: Int
    public let height: Int
    /// `width * height` values, rows top to bottom; ARKit writes 255 for a person and 0 for anything else.
    public let values: [UInt8]
    /// Values at or above this are a person.
    public var threshold: UInt8 = 128

    public init?(width: Int, height: Int, values: [UInt8]) {
        guard width > 0, height > 0, values.count >= width * height else { return nil }
        self.width = width
        self.height = height
        self.values = values
    }

    /// Share (0...1) of the rectangle, given in pixels of the full `imageWidth` x `imageHeight` camera image (edges
    /// exclusive at the max side), that shows a person. The rectangle is clipped to the image; 0 if nothing is left.
    /// A rectangle smaller than a mask pixel reads the one mask pixel under its middle.
    public func share(minX: Float, minY: Float, maxX: Float, maxY: Float, imageWidth: Float, imageHeight: Float) -> Float {
        guard imageWidth > 0, imageHeight > 0 else { return 0 }
        let sx = Float(width) / imageWidth, sy = Float(height) / imageHeight
        let x0 = max(0, minX) * sx, x1 = min(imageWidth, maxX) * sx
        let y0 = max(0, minY) * sy, y1 = min(imageHeight, maxY) * sy
        guard x1 > x0, y1 > y0 else { return 0 }
        // Mask pixels whose centres lie inside the rectangle.
        var i0 = Int((x0 - 0.5).rounded(.up)), i1 = Int((x1 - 0.5).rounded(.down))
        var j0 = Int((y0 - 0.5).rounded(.up)), j1 = Int((y1 - 0.5).rounded(.down))
        if i1 < i0 { i0 = Int((x0 + x1) / 2); i1 = i0 }
        if j1 < j0 { j0 = Int((y0 + y1) / 2); j1 = j0 }
        i0 = max(0, i0); j0 = max(0, j0); i1 = min(width - 1, i1); j1 = min(height - 1, j1)
        guard i1 >= i0, j1 >= j0 else { return 0 }
        var person = 0, total = 0
        for j in j0...j1 {
            let row = j * width
            for i in i0...i1 {
                total += 1
                if values[row + i] >= threshold { person += 1 }
            }
        }
        return total > 0 ? Float(person) / Float(total) : 0
    }

    /// Share of a detection's bounding box (work-image pixels, `step` full-resolution pixels each) that shows a person.
    public func share(of blob: DetectedBlob, step: Int, imageWidth: Float, imageHeight: Float) -> Float {
        let s = Float(step)
        return share(minX: Float(blob.minX) * s, minY: Float(blob.minY) * s,
                     maxX: Float(blob.maxX + 1) * s, maxY: Float(blob.maxY + 1) * s,
                     imageWidth: imageWidth, imageHeight: imageHeight)
    }
}

/// Keeping the user's hands out of the scan.
public enum HandMasking {
    public struct Settings {
        /// A detection is dropped when at least this share of its box shows a person: a fingertip or a knuckle, or a
        /// piece half hidden under one (measured wrongly, so better seen again later).
        public var dropAbove: Float = 0.25
        /// A tracked piece counts as hidden, so the frame is no evidence that it is gone, when at least this share of the
        /// box around where it should appear shows a person. Small, because a hand's edge in the mask is soft and a
        /// detector misses a piece whose outline a finger merely touches.
        public var hiddenAbove: Float = 0.05
        /// Added on every side of a piece's box, metres on the table, for the same reason.
        public var margin: Float = 0.005
        public init() {}
    }

    /// The detections to keep, and how many were dropped for lying under a hand. Without a mask every one is kept.
    public static func filter(_ blobs: [DetectedBlob], mask: PersonMask?, step: Int, imageWidth: Float, imageHeight: Float,
                              settings: Settings = Settings()) -> (kept: [DetectedBlob], dropped: Int) {
        guard let mask else { return (blobs, 0) }
        let kept = blobs.filter { mask.share(of: $0, step: step, imageWidth: imageWidth, imageHeight: imageHeight) < settings.dropAbove }
        return (kept, blobs.count - kept.count)
    }

    /// Box, in full-resolution image pixels, around where a tracked piece should appear: its middle (half-way up a tall
    /// piece) projected into the view, half its length plus the margin on each side.
    public static func imageBox(of piece: TrackedPiece, projector: TableProjector,
                                margin: Float) -> (minX: Float, minY: Float, maxX: Float, maxY: Float)? {
        let middle = piece.position + SIMD3<Float>(0, piece.heightMm / 2000, 0)
        guard let seen = projector.project(middle) else { return nil }
        let half = (piece.longMm / 2000 + margin) * projector.fx / seen.depth
        return (seen.pixel.x - half, seen.pixel.y - half, seen.pixel.x + half, seen.pixel.y + half)
    }

    /// Pieces that the person in view hides in this frame.
    public static func occluded(pieces: [TrackedPiece], projector: TableProjector, mask: PersonMask?,
                                imageWidth: Float, imageHeight: Float, settings: Settings = Settings()) -> Set<UUID> {
        guard let mask else { return [] }
        var hidden = Set<UUID>()
        for piece in pieces {
            guard let box = imageBox(of: piece, projector: projector, margin: settings.margin) else { continue }
            let share = mask.share(minX: box.minX, minY: box.minY, maxX: box.maxX, maxY: box.maxY,
                                   imageWidth: imageWidth, imageHeight: imageHeight)
            if share >= settings.hiddenAbove { hidden.insert(piece.id) }
        }
        return hidden
    }
}
