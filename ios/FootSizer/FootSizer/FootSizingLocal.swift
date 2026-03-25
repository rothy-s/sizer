import Foundation

/// Mirrors server logic for on-device preview (Mondopoint mm, approximate US).
enum FootSizingLocal {
    static func mondopoint(lengthMm: Double) -> Int {
        Int((lengthMm / 5.0).rounded() * 5)
    }

    /// Simple US approximation from Mondopoint tables (men's).
    static func approximateUsMens(lengthMm: Double) -> Double {
        let table: [(Int, Double)] = [
            (255, 8.5), (260, 9), (265, 9.5), (270, 10), (275, 10.5),
            (280, 11), (285, 11.5), (290, 12),
        ]
        let mondo = mondopoint(lengthMm: lengthMm)
        guard let first = table.first else { return 0 }
        if mondo <= first.0 { return first.1 }
        guard let last = table.last else { return 0 }
        if mondo >= last.0 { return last.1 + Double(mondo - last.0) * 0.05 }
        for i in 0..<(table.count - 1) {
            let a0 = table[i].0
            let s0 = table[i].1
            let a1 = table[i + 1].0
            let s1 = table[i + 1].1
            if mondo >= a0 && mondo <= a1 {
                let t = Double(mondo - a0) / Double(a1 - a0)
                return s0 + t * (s1 - s0)
            }
        }
        return last.1
    }
}
