import Foundation

/// Deferred install deep link (the landing page copied a beamio invite or
/// merchant link before the App Store install). Reading `UIPasteboard.string`
/// shows iOS's "Beamio would like to paste from …" prompt, so the shell tries
/// once per install only, never for an existing user, and reads the text only
/// after `detectPatterns(for: [.probableWebURL])` (which shows no prompt) says
/// it looks like a link. Pure: no UIKit, so it can be unit-tested.
nonisolated enum BeamioPasteboardDeepLinkGate {
	/// UserDefaults key: set once the shell made its one attempt (or skipped it for good).
	static let attemptedKey = "beamio.deeplink.pasteboardAttempted.v1"

	enum Step: Equatable {
		/// Ask the pasteboard (without reading it) whether it holds a web URL.
		case checkForURL
		/// Do nothing now.
		case skip(String)
	}

	/// - Parameters:
	///   - attemptedBefore: the UserDefaults flag.
	///   - existingUser: this install already has app data (a bound wallet or
	///     push token): it was not just installed from the landing page.
	///   - suppressed: a call is being shown (busy chrome rescue): try another launch.
	///   - hasPendingLink: a universal link or custom URL already opened the app.
	/// - Returns: what to do, and whether to set the flag now.
	static func decide(
		attemptedBefore: Bool,
		existingUser: Bool,
		suppressed: Bool,
		hasPendingLink: Bool
	) -> (step: Step, markAttempted: Bool) {
		if attemptedBefore { return (.skip("done"), false) }
		if suppressed { return (.skip("suppressed"), false) }
		if existingUser { return (.skip("existing-user"), true) }
		if hasPendingLink { return (.skip("link-arrived"), true) }
		return (.checkForURL, true)
	}
}
