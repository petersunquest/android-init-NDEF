import WebKit
import XCTest
@testable import CashTrees_iOS

/// Which failures rebuild the route-PGP host (a 19:55 call stayed silent because
/// the host was dead and never rebuilt). The full kill-and-recover run uses a real
/// WKWebView; see voice-v3-latency.md (19:55 无声通话 / RC3b).
final class VoiceRoutePgpRecoveryTests: XCTestCase {
	func testProcessEndAndInvalidViewCountAsGone() {
		for code in [WKError.Code.webContentProcessTerminated, .webViewInvalidated] {
			XCTAssertTrue(BeamioVoiceRoutePgp.isHostGone(NSError(domain: WKError.errorDomain, code: code.rawValue)))
		}
	}

	func testBlankPageCountsAsGone() {
		for message in ["Can't find variable: openpgp", "window.beamioVoiceEncryptBinary is not a function"] {
			let e = NSError(domain: WKError.errorDomain, code: WKError.Code.javaScriptExceptionOccurred.rawValue,
			                userInfo: ["WKJavaScriptExceptionMessage": message])
			XCTAssertTrue(BeamioVoiceRoutePgp.isHostGone(e), message)
		}
	}

	/// Only a script error keeps its result: a JS exception with its own message.
	func testScriptErrorsDoNotRebuild() {
		for message in ["Error: Misformed armored text", "Error: Could not find valid encryption key packet"] {
			let e = NSError(domain: WKError.errorDomain, code: WKError.Code.javaScriptExceptionOccurred.rawValue,
			                userInfo: ["WKJavaScriptExceptionMessage": message])
			XCTAssertFalse(BeamioVoiceRoutePgp.isHostGone(e), message)
		}
	}

	/// What a real iPhone returns for a call in flight when the content process is
	/// killed (RC3c R14 on the SE): "result of an unsupported type". Our functions
	/// only return strings, so it means the page died: rebuild once.
	func testUnsupportedResultFromKilledPageCountsAsGone() {
		let unsupported = NSError(domain: WKError.errorDomain, code: WKError.Code.javaScriptResultTypeIsUnsupported.rawValue)
		XCTAssertTrue(BeamioVoiceRoutePgp.isHostGone(unsupported))
	}

	/// A killed content process on a real iPhone answers at once with an error that
	/// is none of the above (RC3b V10: 5 ms, before the terminate callback): every
	/// other error counts as a dead page and is rebuilt once.
	func testAnyOtherErrorCountsAsGone() {
		let others: [NSError] = [
			NSError(domain: WKError.errorDomain, code: WKError.Code.unknown.rawValue),
			NSError(domain: WKError.errorDomain, code: WKError.Code.javaScriptExceptionOccurred.rawValue),  // no message
			NSError(domain: WKError.errorDomain, code: WKError.Code.javaScriptExceptionOccurred.rawValue,
			        userInfo: ["WKJavaScriptExceptionMessage": ""]),
			NSError(domain: WKError.errorDomain, code: WKError.Code.javaScriptInvalidFrameTarget.rawValue),
			NSError(domain: NSURLErrorDomain, code: -1001),
			NSError(domain: "WebKitErrorDomain", code: 102),
		]
		for e in others {
			XCTAssertTrue(BeamioVoiceRoutePgp.isHostGone(e), "\(e.domain) \(e.code)")
		}
	}

	/// The watchdog error the host raises for a call that never answers.
	func testWatchdogTimeoutCountsAsGone() {
		let e = NSError(domain: WKError.errorDomain, code: WKError.Code.webContentProcessTerminated.rawValue,
		                userInfo: [NSLocalizedDescriptionKey: "js call timed out after 4 s"])
		XCTAssertTrue(BeamioVoiceRoutePgp.isHostGone(e))
	}
}
