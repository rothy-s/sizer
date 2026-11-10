import SwiftUI

@main
struct FootSizerApp: App {
    var body: some Scene {
        WindowGroup {
            // Launch with `-previewResults 1` to open the results screen directly with
            // sample data (fast visual QA without driving the capture/manual-entry flow).
            if UserDefaults.standard.bool(forKey: "previewResults") {
                NavigationStack {
                    FootResultsView(
                        gender: .mens,
                        left: FootSideMeasurement(lengthMm: 289, ballWidthMm: 104, archHeightMm: 70),
                        right: FootSideMeasurement(lengthMm: 292, ballWidthMm: 101, archHeightMm: 78)
                    )
                }
            } else {
                ContentView()
            }
        }
    }
}
