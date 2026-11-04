import Foundation
import Testing
@testable import CashTrees_iOS

/// PushKit cold launch + answer: the page renders under the call screen, where
/// the splash is left out of the view. After the call the splash must not stay
/// over the ready page (SE 2026-11-03: stuck on the logo until the app was killed).
@MainActor
struct SplashAfterCallTests {
	/// Run what the load state queued on the main queue before this point.
	private func drainMain() async {
		await withCheckedContinuation { done in
			DispatchQueue.main.async { done.resume() }
		}
	}

	@Test func pageRenderedDuringCallDropsSplashWhenCallScreenCloses() async {
		let state = CashTreesWebLoadState()
		// The page reports its first render while the call screen is up.
		state.beginSplashHandoff()
		await drainMain()
		#expect(state.isSplashVisible)
		#expect(state.shouldAnimateOut)

		state.callScreenDismissed()
		await drainMain()
		#expect(!state.isSplashVisible)
		#expect(!state.shouldAnimateOut)
	}

	@Test func pageNotRenderedYetKeepsSplash() async {
		let state = CashTreesWebLoadState()
		state.callScreenDismissed()
		await drainMain()
		// Nothing to reveal yet: the normal handoff hides it once the page renders.
		#expect(state.isSplashVisible)
		#expect(!state.shouldAnimateOut)
	}

	@Test func retriesAreBlockedOnceHandoffWasAskedFor() async {
		// Why the fix is needed: a second handoff (the 10 s fallback) is a no-op
		// once one was asked for, so only callScreenDismissed can end it.
		let state = CashTreesWebLoadState()
		state.beginSplashHandoff()
		await drainMain()
		state.beginSplashHandoff()
		await drainMain()
		#expect(state.isSplashVisible)
		state.callScreenDismissed()
		await drainMain()
		#expect(!state.isSplashVisible)
	}

	@Test func splashAlreadyGoneStaysGone() async {
		let state = CashTreesWebLoadState()
		state.beginSplashHandoff()
		await drainMain()
		state.finishSplashHandoff()
		await drainMain()
		state.callScreenDismissed()
		await drainMain()
		#expect(!state.isSplashVisible)
		#expect(!state.shouldAnimateOut)
	}
}
