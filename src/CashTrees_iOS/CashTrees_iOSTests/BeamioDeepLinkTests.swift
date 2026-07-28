import XCTest
@testable import CashTrees_iOS

final class BeamioDeepLinkTests: XCTestCase {
    func testCustomSchemePassthroughQuery() {
        let url = URL(string: "beamio://open?beamiocard=0xabc&redeemcode=XYZ")!
        let resolved = BeamioDeepLink.resolveWebAppURL(from: url)
        XCTAssertEqual(resolved?.host, "beamio.app")
        XCTAssertEqual(resolved?.path, "/app/")
        XCTAssertTrue(resolved?.absoluteString.contains("beamiocard=0xabc") == true)
    }

    func testCustomSchemeTarget() throws {
        let target = "https://beamio.app/app/?couponId=1"
        let enc = target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "beamio://open?target=\(enc)")!
        let resolved = BeamioDeepLink.resolveWebAppURL(from: url)
        XCTAssertEqual(resolved?.absoluteString, target)
    }

    func testUnwrapsAppDownloadTargetFromCustomScheme() throws {
        let inner = "https://beamio.app/app/?beamiocard=0x86398FcFbf51Ed5fccA144FFE2155DAC6724587D&couponId=coupon-1&claim=open"
        let outer = "https://beamio.app/app-download?target=\(inner.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!)"
        let enc = outer.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "beamio://open?target=\(enc)")!
        let resolved = BeamioDeepLink.resolveWebAppURL(from: url)
        XCTAssertEqual(resolved?.absoluteString, inner)
    }

    func testUnwrapsAppDownloadUniversalLink() {
        let inner = "https://beamio.app/app/?beamiocard=0xabc&couponId=1&claim=open"
        let enc = inner.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)!
        let url = URL(string: "https://beamio.app/app-download?target=\(enc)")!
        let resolved = BeamioDeepLink.resolveWebAppURL(from: url)
        XCTAssertEqual(resolved?.absoluteString, inner)
    }

    func testUniversalLinkAppPath() {
        let url = URL(string: "https://beamio.app/app/?redeemcode=abc")!
        let resolved = BeamioDeepLink.resolveWebAppURL(from: url)
        XCTAssertEqual(resolved, url)
    }

    func testRejectsDisallowedHost() {
        let url = URL(string: "beamio://open?target=https%3A%2F%2Fevil.example%2F")!
        XCTAssertNil(BeamioDeepLink.resolveWebAppURL(from: url))
    }

    func testMapResolvedWebAppURLToLocalStripsAppPrefix() {
        let remote = URL(string: "https://beamio.app/app/?beamiocard=0xabc")!
        let local = BeamioDeepLink.mapResolvedWebAppURLToLocal(remote)
        XCTAssertEqual(local.scheme, CashTreesPWAScheme.scheme)
        XCTAssertEqual(local.host, CashTreesPWAScheme.host)
        XCTAssertEqual(local.path, "/")
        XCTAssertEqual(local.query, "beamiocard=0xabc")
    }
}
