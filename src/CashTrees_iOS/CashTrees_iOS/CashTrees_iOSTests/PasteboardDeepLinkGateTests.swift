import Testing
@testable import CashTrees_iOS

/// The deferred install link reads the pasteboard (iOS paste prompt) once per
/// fresh install only, after a prompt-free URL check.
struct PasteboardDeepLinkGateTests {
	typealias Gate = BeamioPasteboardDeepLinkGate

	@Test func freshInstallChecksOnceAndMarks() {
		let d = Gate.decide(attemptedBefore: false, existingUser: false, suppressed: false, hasPendingLink: false)
		#expect(d.step == .checkForURL)
		#expect(d.markAttempted)
	}

	@Test func laterColdStartsNeverTouchThePasteboard() {
		let d = Gate.decide(attemptedBefore: true, existingUser: false, suppressed: false, hasPendingLink: false)
		#expect(d.step == .skip("done"))
		#expect(!d.markAttempted)
	}

	/// An update over an installed app (wallet bound or push token saved): never asks.
	@Test func existingUserSkipsForGood() {
		let d = Gate.decide(attemptedBefore: false, existingUser: true, suppressed: false, hasPendingLink: false)
		#expect(d.step == .skip("existing-user"))
		#expect(d.markAttempted)
	}

	@Test func aLinkThatOpenedTheAppWins() {
		let d = Gate.decide(attemptedBefore: false, existingUser: false, suppressed: false, hasPendingLink: true)
		#expect(d.step == .skip("link-arrived"))
		#expect(d.markAttempted)
	}

	/// A call is on screen: skip now without using up the one attempt.
	@Test func suppressedKeepsTheAttemptForLater() {
		let d = Gate.decide(attemptedBefore: false, existingUser: false, suppressed: true, hasPendingLink: false)
		#expect(d.step == .skip("suppressed"))
		#expect(!d.markAttempted)
	}
}
