import SwiftUI

struct ContentView: View {
    @State private var gender: ShoeGender = .mens
    @State private var apiBaseURL: String = FootSizerAPI.defaultBaseURL().absoluteString
    @State private var left: FootSideMeasurement?
    @State private var right: FootSideMeasurement?
    @State private var showLeftScan = false
    @State private var showRightScan = false
    @State private var showLeftTrueDepth = false
    @State private var showRightTrueDepth = false
    @State private var manualLeftLength = ""
    @State private var manualLeftWidth = ""
    @State private var manualRightLength = ""
    @State private var manualRightWidth = ""
    @State private var isSubmitting = false
    @State private var alertMessage: String?
    @State private var measurementResult: MeasurementResponse?
    @State private var recommendations: [ShoeRecommendation] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Server") {
                    TextField("API base URL", text: $apiBaseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    Button("Save URL") {
                        UserDefaults.standard.set(apiBaseURL, forKey: "footsizer_api_base")
                    }
                }

                Section("Profile") {
                    Picker("Sizing line", selection: $gender) {
                        ForEach(ShoeGender.allCases) { g in
                            Text(g.label).tag(g)
                        }
                    }
                }

                Section("Left foot (Mondopoint length + ball width, mm)") {
                    if let l = left {
                        Text("Length \(Int(l.lengthMm)) mm · width \(Int(l.ballWidthMm)) mm")
                        Text("Preview: Mondopoint ~\(FootSizingLocal.mondopoint(lengthMm: l.lengthMm)) mm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Scan with LiDAR") { showLeftScan = true }
                    if FootScanCapabilities.supportsTrueDepthDepthDelivery {
                        Button("Scan with TrueDepth (front)") { showLeftTrueDepth = true }
                    }
                    HStack {
                        TextField("Length mm", text: $manualLeftLength)
                            .keyboardType(.numberPad)
                        TextField("Ball width mm", text: $manualLeftWidth)
                            .keyboardType(.numberPad)
                    }
                    Button("Use manual left values") {
                        applyManualLeft()
                    }
                }

                Section("Right foot") {
                    if let r = right {
                        Text("Length \(Int(r.lengthMm)) mm · width \(Int(r.ballWidthMm)) mm")
                        Text("Preview: Mondopoint ~\(FootSizingLocal.mondopoint(lengthMm: r.lengthMm)) mm")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Scan with LiDAR") { showRightScan = true }
                    if FootScanCapabilities.supportsTrueDepthDepthDelivery {
                        Button("Scan with TrueDepth (front)") { showRightTrueDepth = true }
                    }
                    HStack {
                        TextField("Length mm", text: $manualRightLength)
                            .keyboardType(.numberPad)
                        TextField("Ball width mm", text: $manualRightWidth)
                            .keyboardType(.numberPad)
                    }
                    Button("Use manual right values") {
                        applyManualRight()
                    }
                }

                if let l = left, let r = right {
                    Section {
                        NavigationLink {
                            FootResultsView(gender: gender, left: l, right: r)
                        } label: {
                            Label("See measurements & sizes", systemImage: "ruler")
                                .font(.headline)
                        }
                    }
                }

                Section {
                    Button(action: submit) {
                        if isSubmitting {
                            ProgressView()
                        } else {
                            Text("Save measurements & get shoe ideas")
                        }
                    }
                    .disabled(!canSubmit || isSubmitting)
                } footer: {
                    Text("Optional — saves to the server and returns shoe suggestions. The size breakdown above works offline.")
                }

                if let m = measurementResult {
                    Section("Saved") {
                        Text("ID \(m.id)")
                            .font(.caption)
                        LabeledContent("Left Mondopoint", value: "\(m.leftMondoMm) mm (~US \(String(format: "%.1f", m.leftUsApprox)), \(m.leftWidthCode))")
                        LabeledContent("Right Mondopoint", value: "\(m.rightMondoMm) mm (~US \(String(format: "%.1f", m.rightUsApprox)), \(m.rightWidthCode))")
                    }
                }

                if !recommendations.isEmpty {
                    Section("Suggested models (lower fit score is better)") {
                        ForEach(recommendations) { shoe in
                            NavigationLink(value: shoe) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("\(shoe.brand) — \(shoe.name)")
                                        .font(.headline)
                                    Text("\(shoe.style) · Mondopoint \(shoe.mondoMinMm)–\(shoe.mondoMaxMm) mm · \(shoe.width)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Text("Fit score \(String(format: "%.1f", shoe.fitScore))")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("FootSizer")
            .navigationDestination(for: ShoeRecommendation.self) { shoe in
                ShoeDetailView(shoe: shoe)
            }
            .sheet(isPresented: $showLeftScan) {
                ARFootScannerSheet(
                    onCaptured: { left = $0 },
                    onError: { alertMessage = $0 },
                    onDismiss: { showLeftScan = false }
                )
            }
            .sheet(isPresented: $showRightScan) {
                ARFootScannerSheet(
                    onCaptured: { right = $0 },
                    onError: { alertMessage = $0 },
                    onDismiss: { showRightScan = false }
                )
            }
            .sheet(isPresented: $showLeftTrueDepth) {
                TrueDepthFootScannerSheet(
                    onCaptured: { left = $0 },
                    onError: { alertMessage = $0 },
                    onDismiss: { showLeftTrueDepth = false }
                )
            }
            .sheet(isPresented: $showRightTrueDepth) {
                TrueDepthFootScannerSheet(
                    onCaptured: { right = $0 },
                    onError: { alertMessage = $0 },
                    onDismiss: { showRightTrueDepth = false }
                )
            }
            .alert("Notice", isPresented: Binding(
                get: { alertMessage != nil },
                set: { if !$0 { alertMessage = nil } }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
    }

    private var canSubmit: Bool {
        left != nil && right != nil
    }

    private func applyManualLeft() {
        guard let l = Double(manualLeftLength), let w = Double(manualLeftWidth), l > 0, w > 0 else {
            alertMessage = "Enter positive length and ball width for the left foot."
            return
        }
        left = FootSideMeasurement(lengthMm: l, ballWidthMm: w)
    }

    private func applyManualRight() {
        guard let l = Double(manualRightLength), let w = Double(manualRightWidth), l > 0, w > 0 else {
            alertMessage = "Enter positive length and ball width for the right foot."
            return
        }
        right = FootSideMeasurement(lengthMm: l, ballWidthMm: w)
    }

    private func submit() {
        guard let base = URL(string: apiBaseURL), let l = left, let r = right else { return }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            let api = FootSizerAPI(baseURL: base)
            let req = MeasurementCreateRequest(
                gender: gender.rawValue,
                deviceId: FootSizerAPI.deviceId(),
                left: l,
                right: r
            )
            do {
                let saved = try await api.submitMeasurement(req)
                measurementResult = saved
                let recs = try await api.recommendations(measurementId: saved.id, limit: 12)
                recommendations = recs
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }
}

struct ShoeDetailView: View {
    let shoe: ShoeRecommendation

    var body: some View {
        List {
            Section {
                LabeledContent("Brand", value: shoe.brand)
                LabeledContent("Model", value: shoe.name)
                LabeledContent("Style", value: shoe.style)
                LabeledContent("Mondopoint range", value: "\(shoe.mondoMinMm)–\(shoe.mondoMaxMm) mm")
                LabeledContent("Last width", value: shoe.width)
                LabeledContent("Fit score", value: String(format: "%.2f", shoe.fitScore))
            }
            if let notes = shoe.notes {
                Section("Notes") {
                    Text(notes)
                }
            }
        }
        .navigationTitle("Shoe")
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    ContentView()
}
