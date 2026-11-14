import Foundation

/// One object found lying on the table, in work-image pixel coordinates.
struct DetectedBlob {
    var minX: Int
    var minY: Int
    var maxX: Int
    var maxY: Int
    var area: Int
    /// Centroid.
    var cx: Float
    var cy: Float
    /// Length of the long and short side of the best-fit rectangle, in pixels.
    var major: Float
    var minor: Float
    /// Median colour of the object's pixels.
    var r: UInt8
    var g: UInt8
    var b: UInt8
}

/// Finds separate pieces on a plain surface.
///
/// Same method as `public/segment.js` in the web app, with two changes for a moving camera:
/// the background colour is the median of the whole frame (pieces cross the frame edges during a sweep),
/// and blobs cut off by the frame edge are dropped so only fully visible pieces are reported.
enum PieceDetector {
    private static let linear: [Float] = (0..<256).map { i in
        let c = Float(i) / 255
        return c <= 0.04045 ? c / 12.92 : powf((c + 0.055) / 1.055, 2.4)
    }

    @inline(__always)
    private static func labF(_ t: Float) -> Float {
        t > 0.008856 ? cbrtf(t) : 7.787 * t + 16.0 / 116.0
    }

    @inline(__always)
    private static func lab(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> (Float, Float, Float) {
        let lr = linear[Int(r)], lg = linear[Int(g)], lb = linear[Int(b)]
        let fx = labF((0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.95047)
        let fy = labF(0.2126 * lr + 0.7152 * lg + 0.0722 * lb)
        let fz = labF((0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.08883)
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    private static func histogramMedian(_ hist: [Int], total: Int) -> UInt8 {
        var seen = 0
        for v in 0..<256 {
            seen += hist[v]
            if seen * 2 >= total { return UInt8(v) }
        }
        return 255
    }

    /// 3×3 dilation (`dilate == true`) or erosion.
    private static func morph(_ mask: [UInt8], _ w: Int, _ h: Int, dilate: Bool) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: mask.count)
        let hit: UInt8 = dilate ? 1 : 0
        for y in 0..<h {
            let y0 = max(0, y - 1), y1 = min(h - 1, y + 1)
            for x in 0..<w {
                let x0 = max(0, x - 1), x1 = min(w - 1, x + 1)
                var found = false
                var yy = y0
                while yy <= y1 && !found {
                    let row = yy * w
                    var xx = x0
                    while xx <= x1 {
                        if mask[row + xx] == hit { found = true; break }
                        xx += 1
                    }
                    yy += 1
                }
                out[y * w + x] = found ? hit : 1 - hit
            }
        }
        return out
    }

    /// - Parameters:
    ///   - rgba: `width * height * 4` bytes, rows top to bottom.
    ///   - sensitivity: 0…1; higher finds pieces closer in colour to the table.
    static func detect(rgba: [UInt8], width w: Int, height h: Int, sensitivity: Float = 0.5) -> [DetectedBlob] {
        let n = w * h
        guard n > 0, rgba.count >= n * 4 else { return [] }

        // Background colour: per-channel median of the frame.
        var hr = [Int](repeating: 0, count: 256)
        var hg = hr, hb = hr
        var sampled = 0
        var i = 0
        while i < n {
            hr[Int(rgba[i * 4])] += 1
            hg[Int(rgba[i * 4 + 1])] += 1
            hb[Int(rgba[i * 4 + 2])] += 1
            sampled += 1
            i += 5
        }
        let bg = lab(histogramMedian(hr, total: sampled), histogramMedian(hg, total: sampled), histogramMedian(hb, total: sampled))

        // Colour distance from the background. Lightness counts for less so soft shadows are not pieces.
        var dist = [Float](repeating: 0, count: n)
        var maxD: Float = 1
        for p in 0..<n {
            let c = lab(rgba[p * 4], rgba[p * 4 + 1], rgba[p * 4 + 2])
            let dl = (c.0 - bg.0) * 0.6, da = c.1 - bg.1, db = c.2 - bg.2
            let d = (dl * dl + da * da + db * db).squareRoot()
            dist[p] = d
            if d > maxD { maxD = d }
        }

        // Otsu threshold on the distance histogram, with a floor so a bare table yields nothing.
        let bins = 128
        var hist = [Double](repeating: 0, count: bins)
        for p in 0..<n { hist[min(bins - 1, Int(dist[p] / maxD * Float(bins)))] += 1 }
        var sum = 0.0
        for t in 0..<bins { sum += Double(t) * hist[t] }
        var wB = 0.0, sumB = 0.0, best = 0.0, bestT = 0
        for t in 0..<bins {
            wB += hist[t]
            if wB == 0 { continue }
            let wF = Double(n) - wB
            if wF == 0 { break }
            sumB += Double(t) * hist[t]
            let diff = sumB / wB - (sum - sumB) / wF
            let v = wB * wF * diff * diff
            if v > best { best = v; bestT = t }
        }
        let otsu = Float(bestT + 1) / Float(bins) * maxD
        let threshold = max(22 - sensitivity * 16, otsu * (1.2 - sensitivity * 0.8))

        var mask = [UInt8](repeating: 0, count: n)
        for p in 0..<n where dist[p] > threshold { mask[p] = 1 }
        mask = morph(morph(mask, w, h, dilate: true), w, h, dilate: false)   // close small gaps
        mask = morph(morph(mask, w, h, dilate: false), w, h, dilate: true)   // remove specks

        // Connected components (8-neighbour flood fill).
        var seen = [Bool](repeating: false, count: n)
        var stack = [Int]()
        stack.reserveCapacity(4096)
        var samples = [Int]()
        let minArea = max(24, n / 6000)
        let maxArea = n / 6
        var blobs = [DetectedBlob]()

        for start in 0..<n where mask[start] == 1 && !seen[start] {
            stack.removeAll(keepingCapacity: true)
            samples.removeAll(keepingCapacity: true)
            stack.append(start)
            seen[start] = true
            var area = 0
            var minX = w, minY = h, maxX = 0, maxY = 0
            var sx = 0.0, sy = 0.0, sxx = 0.0, syy = 0.0, sxy = 0.0

            while let p = stack.popLast() {
                let x = p % w, y = p / w
                area += 1
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
                let dx = Double(x), dy = Double(y)
                sx += dx; sy += dy; sxx += dx * dx; syy += dy * dy; sxy += dx * dy
                if samples.count < 1500 || area % 9 == 0 { samples.append(p) }
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) {
                        let q = ny * w + nx
                        if mask[q] == 1 && !seen[q] {
                            seen[q] = true
                            stack.append(q)
                        }
                    }
                }
            }

            if area < minArea || area > maxArea { continue }
            // Cut off by the frame edge: wait for a frame that shows the whole piece.
            if minX <= 0 || minY <= 0 || maxX >= w - 1 || maxY >= h - 1 { continue }

            let count = Double(area)
            let mx = sx / count, my = sy / count
            let vxx = max(0, sxx / count - mx * mx), vyy = max(0, syy / count - my * my)
            let vxy = sxy / count - mx * my
            let half = (vxx + vyy) / 2
            let root = max(0, half * half - (vxx * vyy - vxy * vxy)).squareRoot()
            // A filled rectangle of side L has variance L²/12 along that side.
            let major = Float((12 * (half + root)).squareRoot())
            let minor = Float((12 * max(0, half - root)).squareRoot())

            var rs = [UInt8](), gs = [UInt8](), bs = [UInt8]()
            rs.reserveCapacity(samples.count); gs.reserveCapacity(samples.count); bs.reserveCapacity(samples.count)
            for p in samples {
                rs.append(rgba[p * 4]); gs.append(rgba[p * 4 + 1]); bs.append(rgba[p * 4 + 2])
            }
            rs.sort(); gs.sort(); bs.sort()
            let mid = samples.count / 2

            blobs.append(DetectedBlob(minX: minX, minY: minY, maxX: maxX, maxY: maxY, area: area,
                                      cx: Float(mx), cy: Float(my), major: max(major, 1), minor: max(minor, 1),
                                      r: rs[mid], g: gs[mid], b: bs[mid]))
        }
        return blobs
    }
}
