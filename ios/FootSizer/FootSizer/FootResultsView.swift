import SwiftUI

/// Polished, on-device results screen: stylized feet + labeled gauges (heel-to-toe ruler,
/// ball-width letter scale, arch-height indicator) and a per-foot size with a country/size-system
/// toggle. Renders entirely from local measurements — no server round-trip required.
struct FootResultsView: View {
    let gender: ShoeGender
    let left: FootSideMeasurement
    let right: FootSideMeasurement

    @State private var system: SizeSystem = .us

    private var accent: Color { Color(red: 0.20, green: 0.45, blue: 0.95) }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                systemToggle
                HStack(spacing: 14) {
                    sizeCard(title: "LEFT FOOT", foot: left)
                    sizeCard(title: "RIGHT FOOT", foot: right)
                }
                feetDiagram
                gaugeSection("HEEL TO TOE LENGTH") { lengthRuler }
                gaugeSection("BALL WIDTH") { widthScale }
                gaugeSection("ARCH HEIGHT") { archGauge }
                Text("Sizes are approximate (ISO 19407 / brand lasts vary). Arch height is a dorsal-instep proxy relative to typical \(gender.label.lowercased()) feet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            .padding(18)
        }
        .navigationTitle("Your measurements")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Size system toggle

    private var systemToggle: some View {
        Picker("Size system", selection: $system) {
            ForEach(SizeSystem.allCases) { s in Text(s.label).tag(s) }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Per-foot size card

    private func sizeCard(title: String, foot: FootSideMeasurement) -> some View {
        let size = SizeConversion.converted(for: system, footLenMm: foot.lengthMm, gender: gender)
        let letter = SizeConversion.widthLetter(footLenMm: foot.lengthMm, ballWidthMm: foot.ballWidthMm, gender: gender)
        return VStack(spacing: 6) {
            Text(title).font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(size.display)
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .foregroundStyle(accent)
                if system == .us || system == .uk {
                    Text(letter).font(.title3).fontWeight(.semibold).foregroundStyle(.primary)
                }
            }
            Text(size.system.caption).font(.caption2).foregroundStyle(.secondary)
            Text("\(Int(foot.lengthMm.rounded())) × \(Int(foot.ballWidthMm.rounded())) mm")
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    // MARK: - Feet diagram (stylized, true relative sizes)

    private var feetDiagram: some View {
        let maxLen = max(left.lengthMm, right.lengthMm, 1)
        return HStack(alignment: .bottom, spacing: 28) {
            footView(left, label: "L", maxLen: maxLen, mirrored: true)
            footView(right, label: "R", maxLen: maxLen, mirrored: false)
        }
        .frame(height: 240)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func footView(_ foot: FootSideMeasurement, label: String, maxLen: Double, mirrored: Bool) -> some View {
        let hRatio = foot.lengthMm / maxLen
        let aspect = foot.ballWidthMm / foot.lengthMm    // width/length
        return VStack(spacing: 6) {
            GeometryReader { geo in
                let h = geo.size.height * hRatio
                let w = h * aspect * 1.7                  // slight width exaggeration for legibility
                StylizedFootShape()
                    .fill(accent.opacity(0.18))
                    .overlay(StylizedFootShape().stroke(accent, lineWidth: 2))
                    .frame(width: w, height: h)
                    .scaleEffect(x: mirrored ? -1 : 1, y: 1)   // mirror left vs right foot
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            Text(label).font(.caption).fontWeight(.bold).foregroundStyle(.secondary)
        }
    }

    // MARK: - Gauges

    private func gaugeSection<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline).fontWeight(.semibold).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private var lengthRuler: some View {
        // Range in mm around both feet.
        let lo = 180.0, hi = 340.0
        return VStack(spacing: 14) {
            RulerGauge(lo: lo, hi: hi, ticks: [200, 240, 280, 320],
                       markers: [ (left.lengthMm, "L", accent), (right.lengthMm, "R", .orange) ],
                       unit: "mm")
            HStack {
                markerLegend("L", "\(Int(left.lengthMm.rounded())) mm", accent)
                Spacer()
                markerLegend("R", "\(Int(right.lengthMm.rounded())) mm", .orange)
            }
        }
    }

    private var widthScale: some View {
        VStack(spacing: 12) {
            LadderGauge(labels: SizeConversion.widthLadder,
                        markers: [
                            (SizeConversion.widthLadderPosition(footLenMm: left.lengthMm, ballWidthMm: left.ballWidthMm, gender: gender), "L", accent),
                            (SizeConversion.widthLadderPosition(footLenMm: right.lengthMm, ballWidthMm: right.ballWidthMm, gender: gender), "R", .orange),
                        ])
            HStack {
                Text("NARROW").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Text("WIDE").font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var archGauge: some View {
        let lPos = SizeConversion.archPosition(instepMm: left.archHeightMm, footLenMm: left.lengthMm)
        let rPos = SizeConversion.archPosition(instepMm: right.archHeightMm, footLenMm: right.lengthMm)
        let lClass = SizeConversion.archClass(instepMm: left.archHeightMm, footLenMm: left.lengthMm)
        let rClass = SizeConversion.archClass(instepMm: right.archHeightMm, footLenMm: right.lengthMm)
        return VStack(spacing: 12) {
            LadderGauge(labels: ["LOW", "MEDIUM", "HIGH"],
                        markers: [(lPos, "L", accent), (rPos, "R", .orange)])
            HStack {
                markerLegend("L", lClass.rawValue, accent)
                Spacer()
                markerLegend("R", rClass.rawValue, .orange)
            }
        }
    }

    private func markerLegend(_ tag: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(tag).font(.caption2).fontWeight(.bold).foregroundStyle(.white)
                .frame(width: 18, height: 18).background(Circle().fill(color))
            Text(value).font(.caption).foregroundStyle(.primary)
        }
    }
}

// MARK: - Reusable gauges & shapes

/// A stylized top-down foot silhouette (heel at bottom, toes at top) in its frame.
struct StylizedFootShape: Shape {
    // (lengthFraction from heel, halfWidthFraction of ball width)
    private let outline: [(CGFloat, CGFloat)] = [
        (0.00, 0.36), (0.06, 0.46), (0.14, 0.50), (0.30, 0.42), (0.50, 0.46),
        (0.68, 0.55), (0.78, 0.52), (0.88, 0.44), (0.96, 0.30), (1.00, 0.16),
    ]
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let W = rect.width, H = rect.height
        func pt(_ t: CGFloat, _ hw: CGFloat, mirror: Bool) -> CGPoint {
            let x = rect.midX + (mirror ? -hw : hw) * W
            let y = rect.maxY - t * H   // heel at bottom
            return CGPoint(x: x, y: y)
        }
        // Right edge heel→toe, then left edge toe→heel.
        var pts: [CGPoint] = outline.map { pt($0.0, $0.1, mirror: false) }
        pts += outline.reversed().map { pt($0.0, $0.1, mirror: true) }
        guard let first = pts.first else { return p }
        p.move(to: first)
        for q in pts.dropFirst() { p.addLine(to: q) }
        p.closeSubpath()
        return p
    }
}

/// Horizontal ruler with major ticks and labeled markers positioned by value.
struct RulerGauge: View {
    let lo: Double
    let hi: Double
    let ticks: [Double]
    let markers: [(value: Double, tag: String, color: Color)]
    let unit: String

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x: (Double) -> CGFloat = { v in CGFloat((v - lo) / (hi - lo)) * w }
            ZStack(alignment: .topLeading) {
                // baseline
                Rectangle().fill(Color(.systemGray4)).frame(height: 3)
                    .offset(y: 26)
                // ticks
                ForEach(ticks, id: \.self) { t in
                    VStack(spacing: 2) {
                        Rectangle().fill(Color(.systemGray2)).frame(width: 1.5, height: 10)
                        Text("\(Int(t))").font(.caption2).foregroundStyle(.secondary)
                    }
                    .offset(x: x(t) - 8, y: 20)
                }
                // markers
                ForEach(markers.indices, id: \.self) { i in
                    let m = markers[i]
                    Triangle().fill(m.color).frame(width: 14, height: 10)
                        .offset(x: x(m.value) - 7, y: 16)
                }
            }
        }
        .frame(height: 44)
    }
}

/// Evenly-spaced labeled ladder (e.g. width letters or LOW/MED/HIGH) with markers at 0…1.
struct LadderGauge: View {
    let labels: [String]
    let markers: [(pos: Double, tag: String, color: Color)]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .topLeading) {
                Rectangle().fill(Color(.systemGray4)).frame(height: 3).offset(y: 22)
                ForEach(labels.indices, id: \.self) { i in
                    let px = CGFloat(Double(i) / Double(max(1, labels.count - 1))) * w
                    VStack(spacing: 3) {
                        Rectangle().fill(Color(.systemGray2)).frame(width: 1.5, height: 8)
                        Text(labels[i]).font(.caption2).foregroundStyle(.secondary)
                    }
                    .fixedSize()
                    .offset(x: px - 14, y: 16)
                }
                ForEach(markers.indices, id: \.self) { i in
                    let m = markers[i]
                    Circle().fill(m.color)
                        .frame(width: 16, height: 16)
                        .overlay(Text(m.tag).font(.system(size: 9, weight: .bold)).foregroundStyle(.white))
                        .offset(x: CGFloat(m.pos) * w - 8, y: 14)
                }
            }
        }
        .frame(height: 40)
    }
}

struct Triangle: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

#Preview {
    NavigationStack {
        FootResultsView(
            gender: .mens,
            left: FootSideMeasurement(lengthMm: 289, ballWidthMm: 104, archHeightMm: 70),
            right: FootSideMeasurement(lengthMm: 292, ballWidthMm: 101, archHeightMm: 74)
        )
    }
}
