import Foundation
import UIKit

enum APIError: LocalizedError {
    case invalidURL
    case badStatus(Int, String?)
    case decoding(Error)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid API base URL."
        case .badStatus(let code, let body):
            return "Server error (\(code)): \(body ?? "")"
        case .decoding(let e):
            return "Could not read response: \(e.localizedDescription)"
        }
    }
}

final class FootSizerAPI {
    private let baseURL: URL
    private let session: URLSession

    init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func submitMeasurement(_ body: MeasurementCreateRequest) async throws -> MeasurementResponse {
        let url = baseURL.appendingPathComponent("v1/measurements")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        req.httpBody = try enc.encode(body)

        let (data, res) = try await session.data(for: req)
        guard let http = res as? HTTPURLResponse else { throw APIError.badStatus(-1, nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try dec.decode(MeasurementResponse.self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    func recommendations(measurementId: String, limit: Int = 12) async throws -> [ShoeRecommendation] {
        var comp = URLComponents(
            url: baseURL.appendingPathComponent("v1/measurements/\(measurementId)/recommendations"),
            resolvingAgainstBaseURL: false
        )!
        comp.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "GET"

        let (data, res) = try await session.data(for: req)
        guard let http = res as? HTTPURLResponse else { throw APIError.badStatus(-1, nil) }
        guard (200..<300).contains(http.statusCode) else {
            throw APIError.badStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        do {
            return try dec.decode([ShoeRecommendation].self, from: data)
        } catch {
            throw APIError.decoding(error)
        }
    }

    static func defaultBaseURL() -> URL {
        if let override = UserDefaults.standard.string(forKey: "footsizer_api_base"),
           let u = URL(string: override) {
            return u
        }
        #if targetEnvironment(simulator)
        return URL(string: "http://127.0.0.1:8765")!
        #else
        return URL(string: "http://127.0.0.1:8765")!
        #endif
    }

    static func deviceId() -> String {
        UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    }
}
