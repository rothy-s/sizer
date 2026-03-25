import Foundation

enum ShoeGender: String, CaseIterable, Identifiable {
    case mens = "mens"
    case womens = "womens"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mens: return "Men's"
        case .womens: return "Women's"
        }
    }
}

struct FootSideMeasurement: Codable, Equatable {
    var lengthMm: Double
    var ballWidthMm: Double
}

struct MeasurementCreateRequest: Codable {
    var gender: String
    var deviceId: String?
    var left: FootSideMeasurement
    var right: FootSideMeasurement
}

struct MeasurementResponse: Codable {
    var id: String
    var gender: String
    var leftMondoMm: Int
    var leftUsApprox: Double
    var leftWidthCode: String
    var rightMondoMm: Int
    var rightUsApprox: Double
    var rightWidthCode: String
}

struct ShoeRecommendation: Codable, Identifiable, Hashable {
    var shoeId: String
    var brand: String
    var name: String
    var style: String
    var mondoMinMm: Int
    var mondoMaxMm: Int
    var width: String
    var fitScore: Double
    var notes: String?

    var id: String { shoeId }
}
