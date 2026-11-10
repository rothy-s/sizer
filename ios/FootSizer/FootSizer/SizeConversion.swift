import Foundation

/// On-device shoe-size conversion so the results screen renders instantly (no server needed).
///
/// Anchored on **foot length (heel→toe, mm)**. US comes from the same interpolation tables the
/// server uses (kept in sync with `server/app/sizing.py`); UK/EU/CM/Mondopoint are derived with
/// standard footwear formulas (Barleycorn for UK/US, Paris-point for EU). All conversions are
/// approximate — retail should use ISO 19407 tables and brand-specific lasts — but they are
/// internally consistent (e.g. 270 mm men → ~US 10 / UK 9 / EU 43 / 27.0 cm).
enum SizeSystem: String, CaseIterable, Identifiable {
    case us, uk, eu, cm, mondo
    var id: String { rawValue }
    var label: String {
        switch self {
        case .us: return "US"
        case .uk: return "UK"
        case .eu: return "EU"
        case .cm: return "CM"
        case .mondo: return "Mondo"
        }
    }
    /// Short unit/format hint shown under the big number.
    var caption: String {
        switch self {
        case .us: return "US size"
        case .uk: return "UK size"
        case .eu: return "EU size"
        case .cm: return "cm (JP)"
        case .mondo: return "Mondopoint (mm)"
        }
    }
}

enum ArchClass: String {
    case low = "LOW"
    case medium = "MEDIUM"
    case high = "HIGH"
}

struct ConvertedSize {
    let system: SizeSystem
    /// Numeric value in the target system (e.g. 12.4). For `mondo` this is mm.
    let value: Double
    /// Preformatted display string (US/UK/EU/CM one decimal; Mondo integer mm).
    let display: String
}

enum SizeConversion {
    static let lastAllowanceMm = 16.9   // 2/3 inch last allowance over foot length (Barleycorn)

    // Foot length (mm) -> US size, mirroring server tables (interpolated/extrapolated).
    private static let mondoToUSMens: [(Int, Double)] = [
        (215, 4.5), (220, 5), (225, 5.5), (230, 6), (235, 6.5), (240, 7), (245, 7.5),
        (250, 8), (255, 8.5), (260, 9), (265, 9.5), (270, 10), (275, 10.5), (280, 11),
        (285, 11.5), (290, 12), (295, 12.5), (300, 13), (305, 13.5), (310, 14),
    ]
    private static let mondoToUSWomens: [(Int, Double)] = [
        (215, 5), (220, 5.5), (225, 6), (230, 6.5), (235, 7), (240, 7.5), (245, 8),
        (250, 8.5), (255, 9), (260, 9.5), (265, 10), (270, 10.5), (275, 11),
        (280, 11.5), (285, 12),
    ]

    static func mondopointMm(_ footLenMm: Double) -> Int {
        Int((footLenMm / 5.0).rounded() * 5)
    }

    static func usSize(footLenMm: Double, gender: ShoeGender) -> Double {
        let table = gender == .mens ? mondoToUSMens : mondoToUSWomens
        let x = footLenMm
        if x <= Double(table[0].0) { return table[0].1 }
        if x >= Double(table[table.count - 1].0) {
            let a = table[table.count - 2], b = table[table.count - 1]
            let slope = (b.1 - a.1) / Double(b.0 - a.0)
            return b.1 + slope * (x - Double(b.0))
        }
        for i in 0..<(table.count - 1) {
            let a = table[i], b = table[i + 1]
            if x >= Double(a.0) && x <= Double(b.0) {
                let t = (x - Double(a.0)) / Double(b.0 - a.0)
                return a.1 + t * (b.1 - a.1)
            }
        }
        return table[table.count - 1].1
    }

    static func value(for system: SizeSystem, footLenMm: Double, gender: ShoeGender) -> Double {
        let us = usSize(footLenMm: footLenMm, gender: gender)
        switch system {
        case .us:
            return us
        case .uk:
            // US men = UK + 1; US women ≈ UK + 2.
            return gender == .mens ? us - 1 : us - 2
        case .eu:
            // Paris point: EU = 1.5 × last length (cm).
            return 1.5 * (footLenMm + lastAllowanceMm) / 10.0
        case .cm:
            return footLenMm / 10.0
        case .mondo:
            return Double(mondopointMm(footLenMm))
        }
    }

    static func converted(for system: SizeSystem, footLenMm: Double, gender: ShoeGender) -> ConvertedSize {
        let v = value(for: system, footLenMm: footLenMm, gender: gender)
        let display: String
        switch system {
        case .mondo: display = "\(Int(v))"
        default: display = String(format: "%.1f", v)
        }
        return ConvertedSize(system: system, value: v, display: display)
    }

    // MARK: - Width letters (US 3A…3E ladder)

    /// US width ladder from very narrow to very wide.
    static let widthLadder = ["3A", "2A", "A", "B", "C", "D", "E", "2E", "3E"]

    /// Medium ("D" for men, "B" for women) reference ball width for a given length, and the
    /// per-letter step. Approximate; calibratable against a brand's width grade.
    private static func mediumWidthMm(footLenMm: Double, gender: ShoeGender) -> Double {
        // Medium reference ball-width / length ratio (D for men, B for women). Approximate,
        // calibratable against a brand's width grade.
        let ratio = gender == .mens ? 0.360 : 0.345
        return footLenMm * ratio
    }
    private static let widthStepMm = 4.2   // ~3/16 inch per width letter

    static func widthLetter(footLenMm: Double, ballWidthMm: Double, gender: ShoeGender) -> String {
        let mediumIdx = gender == .mens ? widthLadder.firstIndex(of: "D")! : widthLadder.firstIndex(of: "B")!
        let delta = ballWidthMm - mediumWidthMm(footLenMm: footLenMm, gender: gender)
        let steps = Int((delta / widthStepMm).rounded())
        let idx = min(widthLadder.count - 1, max(0, mediumIdx + steps))
        return widthLadder[idx]
    }

    /// Position (0…1) on the width ladder, for drawing the marker on the scale.
    static func widthLadderPosition(footLenMm: Double, ballWidthMm: Double, gender: ShoeGender) -> Double {
        let letter = widthLetter(footLenMm: footLenMm, ballWidthMm: ballWidthMm, gender: gender)
        let idx = widthLadder.firstIndex(of: letter) ?? widthLadder.count / 2
        return Double(idx) / Double(widthLadder.count - 1)
    }

    // MARK: - Arch class

    /// Dorsal instep height (mm) relative to foot length → low / medium / high.
    /// Typical dorsal-height / length ratios cluster ~0.22–0.28; bands chosen accordingly.
    static func archClass(instepMm: Double, footLenMm: Double) -> ArchClass {
        guard footLenMm > 0, instepMm > 0 else { return .medium }
        let r = instepMm / footLenMm
        if r < 0.225 { return .low }
        if r > 0.275 { return .high }
        return .medium
    }

    /// 0…1 position for the arch gauge (low→high), clamped.
    static func archPosition(instepMm: Double, footLenMm: Double) -> Double {
        guard footLenMm > 0 else { return 0.5 }
        let r = instepMm / footLenMm
        return min(1.0, max(0.0, (r - 0.20) / (0.30 - 0.20)))
    }
}
