import Foundation

/// One square of the grid laid over the table. Cell (x, z) spans world x from `x * cellSize` to `(x + 1) * cellSize`,
/// and the same along world z.
public struct CoverageCell: Hashable {
    public let x: Int
    public let z: Int

    public init(x: Int, z: Int) {
        self.x = x
        self.z = z
    }
}

/// A rectangle on the table, in world x and z (metres).
public struct CoverageRect: Equatable {
    public var minX: Float
    public var minZ: Float
    public var maxX: Float
    public var maxZ: Float

    public init(minX: Float, minZ: Float, maxX: Float, maxZ: Float) {
        self.minX = minX; self.minZ = minZ; self.maxX = maxX; self.maxZ = maxZ
    }

    public var width: Float { maxX - minX }
    public var depth: Float { maxZ - minZ }
}

/// What one camera view added to a `CoverageMap`.
public struct CoverageUpdate: Equatable {
    /// Cells inside this view's footprint.
    public var cellsInView: Int
    /// Of those, cells no earlier view had covered.
    public var newCells: Int

    public init(cellsInView: Int, newCells: Int) {
        self.cellsInView = cellsInView
        self.newCells = newCells
    }

    /// Share of the footprint that was already covered (0 for an empty footprint).
    public var revisitedShare: Float {
        cellsInView > 0 ? Float(cellsInView - newCells) / Float(cellsInView) : 0
    }
}

/// Which parts of the table the camera has seen well enough to detect whole pieces, and how often.
///
/// Each processed frame adds its footprint: the camera image, inset by a margin (pieces cut by the frame edge are
/// ignored by the detectors, so a strip along the edge does not count), projected onto the table plane.
/// The parts of the image whose rays miss the table, or meet it further away than `maxDepth`, are left out.
/// A cell counts as seen by a view when its centre lies inside that view's footprint. Cells are stored sparsely.
///
/// A value type with no locking: use it from one queue.
public struct CoverageMap {
    /// Side of a grid cell in metres.
    public let cellSize: Float
    /// Views that covered each cell. Cells never covered are absent.
    public private(set) var cells: [CoverageCell: Int] = [:]
    /// Bounding rectangle of every covered cell; nil while nothing is covered.
    public private(set) var bounds: CoverageRect?

    /// A footprint wider than this many cells in either direction is not added (it cannot come from a real view
    /// within `maxDepth`; the guard keeps a bad pose from filling the map).
    private static let maxSpan = 1000

    public init(cellSize: Float = 0.02) {
        self.cellSize = max(0.001, cellSize)
    }

    /// Forget everything covered.
    public mutating func reset() {
        cells.removeAll()
        bounds = nil
    }

    /// The cell a table point lies in (world y is ignored).
    public func cell(at position: SIMD3<Float>) -> CoverageCell {
        CoverageCell(x: index(position.x), z: index(position.z))
    }

    /// Centre of a cell as world (x, z).
    public func center(of cell: CoverageCell) -> SIMD2<Float> {
        SIMD2<Float>((Float(cell.x) + 0.5) * cellSize, (Float(cell.z) + 0.5) * cellSize)
    }

    /// How many views covered the cell holding this table point (0 if none did).
    public func timesSeen(at position: SIMD3<Float>) -> Int {
        cells[cell(at: position)] ?? 0
    }

    /// Add one camera view.
    ///
    /// - Parameters:
    ///   - projector: the view's camera and table plane. Its intrinsics are in pixels of an image
    ///     `imageWidth` by `imageHeight`.
    ///   - inset: share of the image width and height left out along each edge.
    ///   - maxDepth: table points further than this along the camera's viewing axis (metres) do not count;
    ///     pieces that far away are too small to detect. `TableProjector` itself stops at 4.
    /// - Returns: how many cells the view covered and how many of them were new.
    @discardableResult
    public mutating func add(view projector: TableProjector, imageWidth: Float, imageHeight: Float,
                             inset: Float = 0.05, maxDepth: Float = 1.0) -> CoverageUpdate {
        let footprint = CoverageMap.footprint(of: projector, imageWidth: imageWidth, imageHeight: imageHeight,
                                              inset: inset, maxDepth: maxDepth)
        return add(footprint: footprint)
    }

    /// Add a convex polygon on the table, given as world (x, z) corners in order (either direction).
    @discardableResult
    public mutating func add(footprint corners: [SIMD2<Float>]) -> CoverageUpdate {
        guard corners.count >= 3, corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return CoverageUpdate(cellsInView: 0, newCells: 0)
        }
        var minX = Float.greatestFiniteMagnitude, maxX = -Float.greatestFiniteMagnitude
        var minZ = Float.greatestFiniteMagnitude, maxZ = -Float.greatestFiniteMagnitude
        for p in corners {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minZ = min(minZ, p.y); maxZ = max(maxZ, p.y)
        }
        guard (maxX - minX) / cellSize < Float(CoverageMap.maxSpan),
              (maxZ - minZ) / cellSize < Float(CoverageMap.maxSpan) else {
            return CoverageUpdate(cellsInView: 0, newCells: 0)
        }

        var inView = 0, fresh = 0
        // Rows of cell centres crossing the polygon; in each row, the span of x the polygon covers.
        let firstRow = Int((minZ / cellSize - 0.5).rounded(.up)), lastRow = Int((maxZ / cellSize - 0.5).rounded(.down))
        if firstRow > lastRow { return CoverageUpdate(cellsInView: 0, newCells: 0) }
        for row in firstRow...lastRow {
            let z = (Float(row) + 0.5) * cellSize
            var low = Float.greatestFiniteMagnitude, high = -Float.greatestFiniteMagnitude
            for i in 0..<corners.count {
                let a = corners[i], b = corners[(i + 1) % corners.count]
                if (a.y - z) * (b.y - z) > 0 { continue }   // edge entirely above or below the row
                if a.y == b.y {
                    low = min(low, a.x, b.x); high = max(high, a.x, b.x)
                } else {
                    let x = a.x + (z - a.y) / (b.y - a.y) * (b.x - a.x)
                    low = min(low, x); high = max(high, x)
                }
            }
            guard low <= high else { continue }
            let first = Int((low / cellSize - 0.5).rounded(.up)), last = Int((high / cellSize - 0.5).rounded(.down))
            if first > last { continue }
            for column in first...last {
                let cell = CoverageCell(x: column, z: row)
                let count = cells[cell] ?? 0
                if count == 0 { fresh += 1 }
                cells[cell] = count + 1
                inView += 1
                grow(to: cell)
            }
        }
        return CoverageUpdate(cellsInView: inView, newCells: fresh)
    }

    /// The part of the table a view sees well, as world (x, z) corners of a convex polygon.
    /// Empty if no part of the inset image looks down at the table within `maxDepth`.
    public static func footprint(of projector: TableProjector, imageWidth: Float, imageHeight: Float,
                                 inset: Float = 0.05, maxDepth: Float = 1.0) -> [SIMD2<Float>] {
        guard imageWidth > 0, imageHeight > 0, projector.fx != 0, projector.fy != 0 else { return [] }
        let origin = projector.camera.columns.3
        let height = origin.y - projector.tableY
        guard height > 0 else { return [] }

        let share = max(0, min(0.49, inset))
        let x0 = imageWidth * share, x1 = imageWidth * (1 - share)
        let y0 = imageHeight * share, y1 = imageHeight * (1 - share)
        var polygon: [SIMD2<Float>] = [SIMD2(x0, y0), SIMD2(x1, y0), SIMD2(x1, y1), SIMD2(x0, y1)]

        // A pixel's ray has world direction c0 * u + c1 * v - c2 with u, v its normalised image coordinates; its
        // vertical part is linear in the pixel. The ray meets the table no deeper than `depth` exactly when that
        // vertical part is at most -height / depth, so the pixels that count form a half-plane of the image:
        // clip the inset rectangle to it. A hair inside the line, so `TableProjector.point` accepts the corners.
        let c0 = projector.camera.columns.0, c1 = projector.camera.columns.1, c2 = projector.camera.columns.2
        let depth = max(0.01, min(3.99, maxDepth))
        let limit = min(-1e-3, -height / depth) * 1.0001
        func verticalExcess(_ p: SIMD2<Float>) -> Float {
            let u = (p.x - projector.cx) / projector.fx, v = -(p.y - projector.cy) / projector.fy
            return c0.y * u + c1.y * v - c2.y - limit   // <= 0: inside
        }
        polygon = clip(polygon, by: verticalExcess)
        guard polygon.count >= 3 else { return [] }

        return polygon.compactMap { (p: SIMD2<Float>) -> SIMD2<Float>? in
            guard let hit = projector.point(p.x, p.y) else { return nil }
            return SIMD2<Float>(hit.x, hit.z)
        }
    }

    /// Sutherland-Hodgman: the part of a convex polygon where `excess` is at most 0. `excess` must be linear.
    private static func clip(_ polygon: [SIMD2<Float>], by excess: (SIMD2<Float>) -> Float) -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        for i in 0..<polygon.count {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let ea = excess(a), eb = excess(b)
            guard ea.isFinite, eb.isFinite else { return [] }
            if ea <= 0 { out.append(a) }
            if (ea <= 0) != (eb <= 0) {
                let t = ea / (ea - eb)
                out.append(a + (b - a) * t)
            }
        }
        return out
    }

    private func index(_ coordinate: Float) -> Int {
        guard coordinate.isFinite else { return 0 }
        let i = (coordinate / cellSize).rounded(.down)
        return Int(max(-1e9, min(1e9, i)))
    }

    private mutating func grow(to cell: CoverageCell) {
        let minX = Float(cell.x) * cellSize, minZ = Float(cell.z) * cellSize
        let rect = CoverageRect(minX: minX, minZ: minZ, maxX: minX + cellSize, maxZ: minZ + cellSize)
        guard var b = bounds else { bounds = rect; return }
        b.minX = min(b.minX, rect.minX); b.minZ = min(b.minZ, rect.minZ)
        b.maxX = max(b.maxX, rect.maxX); b.maxZ = max(b.maxZ, rect.maxZ)
        bounds = b
    }
}
