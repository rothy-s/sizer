import Foundation
import simd

/// Foot measurement from a (roughly foot-local) gravity-aligned point set.
///
/// This is the Swift mirror of `server/tests/foot_geometry_reference.py` — keep the two
/// in sync. It replaces the old naive axis-aligned bounding box (which reported the whole
/// scene, floor included, and inflated "length" when a foot sat at an angle) with a real
/// pipeline that **locks onto the foot**:
///
///   1. Floor plane = tallest histogram bin of the vertical coordinate (lower 60% of range).
///   2. Keep points from floor+`floorBandMm` up to `legCapMm` (drops floor + attached shin).
///   3. Isolate the foot: connected component containing the tap seed (or largest component).
///   4. PCA in the horizontal plane → long axis (heel→toe) — rotation invariant.
///   5. length = principal-axis extent (robust percentiles) + `tipCorrectionMm` (taper inset);
///      ball width = max secondary extent in the forefoot region;
///      arch/instep = 95th-percentile dorsal height over the midfoot.
enum FootMeasurementGeometry {

    // Tuned + validated against a parametric foot model (see the Python reference):
    // width within 3 mm 98% of the time, length within 6 mm 85%, across sizes and rotations.
    static let floorBandMm: Double = 10.0
    static let legCapMm: Double = 95.0
    static let tipCorrectionMm: Double = 26.0
    static let defaultMinPointCount = 80

    struct Result {
        let measurement: FootSideMeasurement
        /// The isolated foot cluster (world/reference space) — used to draw the lock-on cloud.
        let isolatedPoints: [SIMD3<Float>]
    }

    /// ARKit world: **Y** up (index 1); horizontal footprint spans X and Z.
    /// `seed` is the tapped point's horizontal (x, z).
    static func mondoBallFromXZPoints(
        _ points: [SIMD3<Float>],
        seed: SIMD2<Float>? = nil,
        minPointCount: Int = defaultMinPointCount
    ) -> FootSideMeasurement? {
        measure(points: points, verticalAxis: 1, seed: seed, minPointCount: minPointCount)?.measurement
    }

    /// Gravity-aligned reference frame (CoreMotion `.xArbitraryZVertical`): **Z** vertical
    /// (index 2); horizontal plane is X × Y. `seed` is the tapped point's horizontal (x, y).
    static func mondoBallFromReferenceHorizontalXY(
        _ points: [SIMD3<Float>],
        seed: SIMD2<Float>? = nil,
        minPointCount: Int = defaultMinPointCount
    ) -> FootSideMeasurement? {
        measure(points: points, verticalAxis: 2, seed: seed, minPointCount: minPointCount)?.measurement
    }

    /// Full pipeline. Returns `nil` when no plausible foot cluster is found (the caller
    /// treats `nil` as "couldn't lock onto a foot — reject this capture").
    static func measure(
        points: [SIMD3<Float>],
        verticalAxis: Int,
        seed: SIMD2<Float>? = nil,
        minPointCount: Int = defaultMinPointCount
    ) -> Result? {
        guard points.count >= minPointCount else { return nil }
        let up = verticalAxis
        let horiz = [0, 1, 2].filter { $0 != up }
        let a0 = horiz[0], a1 = horiz[1]

        let vertSorted = points.map { $0[up] }.sorted()
        let floor = floorLevel(vertSorted)

        // Thin floor cut (keeps low tapering toe/heel tips) up to a height cap that drops a shin.
        let above = points.filter {
            let h = Double($0[up] - floor) * 1000.0
            return h > floorBandMm && h <= legCapMm
        }
        guard above.count >= minPointCount else { return nil }

        // Isolate the foot cluster the user aimed at (seed) or the dominant one.
        let band = isolate(above, a0: a0, a1: a1, cell: 0.02, seed: seed)
        let n = band.count
        guard n >= minPointCount else { return nil }

        // PCA in the horizontal plane.
        var ma: Double = 0, mb: Double = 0
        for p in band { ma += Double(p[a0]); mb += Double(p[a1]) }
        ma /= Double(n); mb /= Double(n)
        var saa: Double = 0, sab: Double = 0, sbb: Double = 0
        for p in band {
            let da = Double(p[a0]) - ma
            let db = Double(p[a1]) - mb
            saa += da * da; sab += da * db; sbb += db * db
        }
        saa /= Double(n); sab /= Double(n); sbb /= Double(n)
        let tr = saa + sbb
        let det = saa * sbb - sab * sab
        let disc = max(0.0, tr * tr / 4 - det)
        let lam1 = tr / 2 + disc.squareRoot()
        var ux: Double, uy: Double
        if abs(sab) > 1e-12 {
            ux = lam1 - sbb; uy = sab
        } else {
            ux = saa >= sbb ? 1.0 : 0.0
            uy = saa >= sbb ? 0.0 : 1.0
        }
        let ulen = (ux * ux + uy * uy).squareRoot()
        if ulen > 0 { ux /= ulen; uy /= ulen }
        let vx = -uy, vy = ux

        // Project onto (long, width, height-above-floor).
        var proj: [(t: Double, w: Double, h: Double)] = []
        proj.reserveCapacity(n)
        for p in band {
            let da = Double(p[a0]) - ma
            let db = Double(p[a1]) - mb
            proj.append((da * ux + db * uy, da * vx + db * vy, Double(p[up] - floor) * 1000.0))
        }

        let ts = proj.map { $0.t }.sorted()
        let tmin = percentile(ts, 0.005)
        let tmax = percentile(ts, 0.995)
        let span = (tmax - tmin) == 0 ? 1.0 : (tmax - tmin)
        let lengthMm = span * 1000.0 + tipCorrectionMm

        func widthIn(_ loFrac: Double, _ hiFrac: Double) -> Double {
            let lo = tmin + loFrac * span
            let hi = tmin + hiFrac * span
            let ws = proj.filter { $0.t >= lo && $0.t <= hi }.map { $0.w }
            guard ws.count > 5, let mn = ws.min(), let mx = ws.max() else { return 0 }
            return (mx - mn) * 1000.0
        }
        let ballWidthMm = max(widthIn(0.45, 0.95), widthIn(0.05, 0.55))

        let midLo = tmin + 0.35 * span
        let midHi = tmin + 0.60 * span
        let midH = proj.filter { $0.t >= midLo && $0.t <= midHi }.map { $0.h }.sorted()
        let instepMm = midH.isEmpty ? 0 : percentile(midH, 0.95)

        guard lengthMm > 120, lengthMm < 400, ballWidthMm > 40, ballWidthMm < 200 else { return nil }
        let m = FootSideMeasurement(lengthMm: lengthMm, ballWidthMm: ballWidthMm, archHeightMm: instepMm)
        return Result(measurement: m, isolatedPoints: band)
    }

    // MARK: - Helpers (mirror the Python reference)

    private static func percentile(_ sorted: [Double], _ q: Double) -> Double {
        if sorted.isEmpty { return 0 }
        let idx = q * Double(sorted.count - 1)
        let lo = Int(idx.rounded(.down))
        let hi = Int(idx.rounded(.up))
        if lo == hi { return sorted[lo] }
        let frac = idx - Double(lo)
        return sorted[lo] * (1 - frac) + sorted[hi] * frac
    }

    /// Vertical coordinate of the dominant horizontal plane = tallest histogram bin in the
    /// lower 60% of the vertical range (floors sit low and hold the most points).
    private static func floorLevel(_ sortedVert: [Float], binMm: Double = 5.0) -> Float {
        guard let lo = sortedVert.first, let hi = sortedVert.last else { return 0 }
        let span = Double(hi - lo)
        if span <= 0 { return lo }
        let nbins = max(4, Int(span * 1000.0 / binMm))
        let step = span / Double(nbins)
        var counts = [Int](repeating: 0, count: nbins)
        for v in sortedVert {
            let b = min(nbins - 1, Int((Double(v - lo)) / step))
            counts[b] += 1
        }
        let limit = max(1, Int(Double(nbins) * 0.6))
        var peak = 0
        for i in 0..<limit where counts[i] > counts[peak] { peak = i }
        return lo + Float((Double(peak) + 0.5) * step)
    }

    private struct Cell: Hashable { let x: Int; let y: Int }

    private static func cellKey(_ p: SIMD3<Float>, _ a0: Int, _ a1: Int, _ cell: Double) -> Cell {
        Cell(x: Int((Double(p[a0]) / cell).rounded(.down)),
             y: Int((Double(p[a1]) / cell).rounded(.down)))
    }

    /// Connected component containing the seed (tap), or the largest component if seed is nil.
    private static func isolate(
        _ points: [SIMD3<Float>], a0: Int, a1: Int, cell: Double, seed: SIMD2<Float>?
    ) -> [SIMD3<Float>] {
        var cells: [Cell: [Int]] = [:]
        for (i, p) in points.enumerated() {
            cells[cellKey(p, a0, a1, cell), default: []].append(i)
        }
        if cells.isEmpty { return [] }

        func component(from start: Cell) -> [Cell] {
            var seen: Set<Cell> = [start]
            var stack = [start]
            var comp: [Cell] = []
            while let c = stack.popLast() {
                comp.append(c)
                for dx in -1...1 {
                    for dy in -1...1 {
                        let nb = Cell(x: c.x + dx, y: c.y + dy)
                        if cells[nb] != nil, !seen.contains(nb) {
                            seen.insert(nb)
                            stack.append(nb)
                        }
                    }
                }
            }
            return comp
        }

        let comp: [Cell]
        if let seed = seed {
            var key = Cell(x: Int((Double(seed.x) / cell).rounded(.down)),
                           y: Int((Double(seed.y) / cell).rounded(.down)))
            if cells[key] == nil {
                // snap to nearest occupied cell
                key = cells.keys.min(by: {
                    let d0 = ($0.x - key.x) * ($0.x - key.x) + ($0.y - key.y) * ($0.y - key.y)
                    let d1 = ($1.x - key.x) * ($1.x - key.x) + ($1.y - key.y) * ($1.y - key.y)
                    return d0 < d1
                })!
            }
            comp = component(from: key)
        } else {
            var seen: Set<Cell> = []
            var best: [Cell] = []
            var bestCount = 0
            for start in cells.keys where !seen.contains(start) {
                let c = component(from: start)
                seen.formUnion(c)
                let count = c.reduce(0) { $0 + (cells[$1]?.count ?? 0) }
                if count > bestCount { bestCount = count; best = c }
            }
            comp = best
        }
        return comp.flatMap { cells[$0] ?? [] }.map { points[$0] }
    }
}
