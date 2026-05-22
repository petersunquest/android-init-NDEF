import XCTest
@testable import CashTrees_iOS

final class GeneralQRScanPayloadTests: XCTestCase {
    func testAnyTextAcceptsUrl() {
        let url = "https://beamio.app/app/?redeemcode=abc"
        XCTAssertEqual(resolveGeneralQRScanPayload(url, filter: .anyText), url)
    }

    func testRecoveryFilterParsesBase62() {
        let code = "Ab12Cd34Ef56Gh78Ij90"
        XCTAssertEqual(resolveGeneralQRScanPayload(code, filter: .recoveryCodeOnly), code)
    }

    func testRecoveryFilterRejectsPlainUrl() {
        let url = "https://beamio.app/app/?redeemcode=abc"
        XCTAssertNil(resolveGeneralQRScanPayload(url, filter: .recoveryCodeOnly))
    }
}
