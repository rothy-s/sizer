import XCTest
@testable import FootSizer

final class FootSizingLocalTests: XCTestCase {
    func testMondopointRoundsToFiveMillimeters() {
        XCTAssertEqual(FootSizingLocal.mondopoint(lengthMm: 268.0), 270)
        XCTAssertEqual(FootSizingLocal.mondopoint(lengthMm: 262.0), 260)
    }

    func testApproximateUsMensInterpolates() {
        let a = FootSizingLocal.approximateUsMens(lengthMm: 255.0)
        let b = FootSizingLocal.approximateUsMens(lengthMm: 270.0)
        XCTAssertGreaterThan(b, a)
    }
}

final class MeasurementModelsTests: XCTestCase {
    func testMeasurementCreateEncodesSnakeCaseKeys() throws {
        let req = MeasurementCreateRequest(
            gender: "mens",
            deviceId: "unit-test",
            left: FootSideMeasurement(lengthMm: 270, ballWidthMm: 100),
            right: FootSideMeasurement(lengthMm: 268, ballWidthMm: 99)
        )
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        let data = try enc.encode(req)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["gender"] as? String, "mens")
        XCTAssertEqual(obj["device_id"] as? String, "unit-test")
        let left = obj["left"] as! [String: Any]
        XCTAssertEqual(left["length_mm"] as? Double, 270)
        XCTAssertEqual(left["ball_width_mm"] as? Double, 100)
    }

    func testMeasurementResponseDecodesFromSnakeCaseJSON() throws {
        let json = """
        {"id":"abc","gender":"mens","left_mondo_mm":270,"left_us_approx":10.0,"left_width_code":"standard",
        "right_mondo_mm":270,"right_us_approx":9.8,"right_width_code":"standard"}
        """
        let dec = JSONDecoder()
        dec.keyDecodingStrategy = .convertFromSnakeCase
        let r = try dec.decode(MeasurementResponse.self, from: Data(json.utf8))
        XCTAssertEqual(r.id, "abc")
        XCTAssertEqual(r.leftMondoMm, 270)
        XCTAssertEqual(r.leftWidthCode, "standard")
    }
}
