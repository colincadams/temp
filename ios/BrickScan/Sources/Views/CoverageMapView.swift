import BrickCore
import SwiftUI

/// What the scan screen's map draws: a copy of the engine's coverage state, safe to hand to the UI.
/// Positions are world x and z in metres (ARKit world space; x and z are horizontal, fixed for the session).
struct CoverageSnapshot {
    struct Cell {
        /// Centre of the cell.
        let x: Float
        let z: Float
        /// Views that covered it.
        let count: Int
    }

    struct Piece: Identifiable {
        let id: UUID
        let x: Float
        let z: Float
        let state: PieceState
    }

    var cellSize: Float = 0.02
    var cells: [Cell] = []
    /// Bounding rectangle of every covered cell; nil while nothing is covered.
    var bounds: CoverageRect? = nil
    /// Where the phone is above the table; nil until the table is found.
    var camera: SIMD2<Float>? = nil
    /// Unit vector on the table along which the top edge of the phone points.
    var heading: SIMD2<Float>? = nil
    var pieces: [Piece] = []
    var guess: CompletionGuess = .noPieces

    static let empty = CoverageSnapshot()
}

extension CompletionGuess {
    /// One plain sentence for the scan screen. The completion check is a guess, and the wording says so.
    var sentence: String {
        switch self {
        case .noPieces:
            return "No pieces found yet."
        case .needsAnotherPass:
            return "Sweep over the table once more to check every piece."
        case .stillLooking:
            return "Go back over the shaded area to catch any missed pieces."
        case .looksComplete:
            return "Looks complete. Review your pieces?"
        }
    }

    var symbol: String {
        switch self {
        case .noPieces: return "viewfinder"
        case .needsAnotherPass, .stillLooking: return "arrow.triangle.2.circlepath"
        case .looksComplete: return "checkmark.circle.fill"
        }
    }
}

/// Top-down map of the table: where the camera has looked, where pieces were found, and where the phone is now.
///
/// North-up on the table's world axes, so it does not turn as the phone turns; a small arrow shows which way the
/// top of the phone points. Covered ground is shaded, more solid where it has been seen more often. Pieces are
/// dots coloured as over the camera view. Decorative for VoiceOver: the status sentence carries the information.
struct CoverageMapView: View {
    let snapshot: CoverageSnapshot

    /// Ground shown around everything covered, in metres, and the smallest area shown.
    private static let margin: Float = 0.04
    private static let minExtent: Float = 0.3

    var body: some View {
        Canvas { (context: inout GraphicsContext, size: CGSize) in
            CoverageMapView.draw(snapshot, in: &context, size: size)
        }
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.35), lineWidth: 1))
        .accessibilityHidden(true)
    }

    static func color(for state: PieceState) -> Color {
        switch state {
        case .seen: return .white
        case .identifying: return .yellow
        case .identified: return .green
        case .unknown: return .red
        }
    }

    private static func including(_ rect: CoverageRect?, x: Float, z: Float) -> CoverageRect {
        guard var r = rect else { return CoverageRect(minX: x, minZ: z, maxX: x, maxZ: z) }
        r.minX = min(r.minX, x); r.maxX = max(r.maxX, x)
        r.minZ = min(r.minZ, z); r.maxZ = max(r.maxZ, z)
        return r
    }

    /// The part of the table to show: everything covered, every piece and the phone, with a margin.
    private static func region(of snapshot: CoverageSnapshot) -> CoverageRect? {
        var region: CoverageRect? = snapshot.bounds
        for piece in snapshot.pieces { region = including(region, x: piece.x, z: piece.z) }
        if let camera = snapshot.camera { region = including(region, x: camera.x, z: camera.y) }
        guard var r = region else { return nil }
        r.minX -= margin; r.maxX += margin; r.minZ -= margin; r.maxZ += margin
        if r.width < minExtent {
            let grow = (minExtent - r.width) / 2
            r.minX -= grow; r.maxX += grow
        }
        if r.depth < minExtent {
            let grow = (minExtent - r.depth) / 2
            r.minZ -= grow; r.maxZ += grow
        }
        return r
    }

    private static func draw(_ snapshot: CoverageSnapshot, in context: inout GraphicsContext, size: CGSize) {
        guard size.width > 4, size.height > 4, let shown = region(of: snapshot) else { return }
        let inner = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
        let scale = min(inner.width / CGFloat(shown.width), inner.height / CGFloat(shown.depth))
        let originX = inner.midX - CGFloat(shown.width) * scale / 2
        let originY = inner.midY - CGFloat(shown.depth) * scale / 2
        // World +x to the right, world +z down the screen.
        func point(_ x: Float, _ z: Float) -> CGPoint {
            CGPoint(x: originX + CGFloat(x - shown.minX) * scale, y: originY + CGFloat(z - shown.minZ) * scale)
        }

        // Covered ground, in four shades. Cells overlap by half a point so no seams show between them.
        let side = CGFloat(snapshot.cellSize) * scale + 0.5
        let half = snapshot.cellSize / 2
        var shades: [Path] = [Path(), Path(), Path(), Path()]
        for cell in snapshot.cells {
            let level: Int
            if cell.count >= 30 { level = 3 } else if cell.count >= 10 { level = 2 } else if cell.count >= 3 { level = 1 } else { level = 0 }
            let corner = point(cell.x - half, cell.z - half)
            shades[level].addRect(CGRect(x: corner.x, y: corner.y, width: side, height: side))
        }
        let opacities: [Double] = [0.18, 0.3, 0.45, 0.62]
        for level in 0..<shades.count {
            context.fill(shades[level], with: .color(Color.white.opacity(opacities[level])))
        }

        // Pieces.
        let radius: CGFloat = 3
        for piece in snapshot.pieces {
            let p = point(piece.x, piece.z)
            let dot = Path(ellipseIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
            context.fill(dot, with: .color(color(for: piece.state)))
            context.stroke(dot, with: .color(Color.black.opacity(0.7)), lineWidth: 1)
        }

        // The phone: a ring, and an arrow towards the top of the phone.
        if let camera = snapshot.camera {
            let c = point(camera.x, camera.y)
            let ring = Path(ellipseIn: CGRect(x: c.x - 5, y: c.y - 5, width: 10, height: 10))
            context.fill(ring, with: .color(Color.blue.opacity(0.85)))
            context.stroke(ring, with: .color(Color.white), lineWidth: 1.5)
            if let heading = snapshot.heading {
                let hx = CGFloat(heading.x), hy = CGFloat(heading.y)
                var arrow = Path()
                arrow.move(to: CGPoint(x: c.x + hx * 13, y: c.y + hy * 13))
                arrow.addLine(to: CGPoint(x: c.x + hx * 6 - hy * 4, y: c.y + hy * 6 + hx * 4))
                arrow.addLine(to: CGPoint(x: c.x + hx * 6 + hy * 4, y: c.y + hy * 6 - hx * 4))
                arrow.closeSubpath()
                context.fill(arrow, with: .color(Color.white))
            }
        }
    }
}

/// The completion guess as a sentence, with a button to open the review once the scan looks complete.
/// The state is told by the words and the symbol, not by colour.
struct CoverageStatusView: View {
    let guess: CompletionGuess
    /// Whether there is anything to review yet.
    let canReview: Bool
    let review: () -> Void

    /// What the status line says; also what VoiceOver announces when the scan starts to look complete.
    static func text(for guess: CompletionGuess, canReview: Bool) -> String {
        guess.looksComplete && !canReview ? "Looks complete. Waiting for pieces to be identified." : guess.sentence
    }

    var body: some View {
        if guess.looksComplete && canReview {
            Button(action: review) {
                Label(guess.sentence, systemImage: guess.symbol)
                    .font(.subheadline.weight(.semibold))
                    .multilineTextAlignment(.leading)
            }
            .buttonStyle(.borderedProminent)
            .accessibilityHint("Opens the list of pieces found")
        } else {
            Label(CoverageStatusView.text(for: guess, canReview: canReview), systemImage: guess.symbol)
                .font(.footnote.weight(.medium))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

#if DEBUG
extension CoverageSnapshot {
    /// Two passes along a table, with pieces in every state and the phone on its way back.
    static var sample: CoverageSnapshot {
        var cells: [Cell] = []
        for column in -15..<25 {
            for row in -10..<10 {
                let first = column < 14
                let second = column > -2 && row > -6
                let count = (first ? 20 : 0) + (second ? 25 : 0) + (column + row) % 3
                if count > 0 {
                    cells.append(Cell(x: (Float(column) + 0.5) * 0.02, z: (Float(row) + 0.5) * 0.02, count: count))
                }
            }
        }
        let states: [PieceState] = [.identified, .identified, .identifying, .unknown, .seen, .identified]
        let spots: [SIMD2<Float>] = [SIMD2(-0.2, -0.1), SIMD2(0.05, 0.08), SIMD2(0.3, -0.05),
                                     SIMD2(0.12, -0.15), SIMD2(0.4, 0.1), SIMD2(-0.1, 0.15)]
        var pieces: [Piece] = []
        for index in 0..<spots.count {
            pieces.append(Piece(id: UUID(), x: spots[index].x, z: spots[index].y, state: states[index]))
        }
        return CoverageSnapshot(cellSize: 0.02, cells: cells,
                                bounds: CoverageRect(minX: -0.3, minZ: -0.2, maxX: 0.5, maxZ: 0.2),
                                camera: SIMD2(0.22, 0.02), heading: SIMD2(-0.6, -0.8),
                                pieces: pieces, guess: .looksComplete)
    }
}

#Preview("Coverage map") {
    VStack(spacing: 16) {
        CoverageMapView(snapshot: .sample)
            .frame(width: 140, height: 140)
        CoverageMapView(snapshot: .empty)
            .frame(width: 140, height: 140)
        CoverageStatusView(guess: .looksComplete, canReview: true, review: { })
        CoverageStatusView(guess: .stillLooking(quietSeconds: 1, neededSeconds: 4), canReview: true, review: { })
        CoverageStatusView(guess: .needsAnotherPass(pieces: 2), canReview: false, review: { })
    }
    .padding()
    .background(Color.gray)
}
#endif
