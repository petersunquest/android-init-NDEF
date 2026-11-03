import Foundation
import Testing
@testable import CashTrees_iOS

/// Callee: the accept sealed while ringing is used at Answer only while fresh.
struct PreparedAcceptRuleTests {
	private let sealed = Date(timeIntervalSince1970: 1_000_000)

	@Test func freshAcceptIsPostedAsIs() {
		#expect(PreparedAcceptRule.usable(sealedAt: sealed, now: sealed))
		// Answered at the end of the 60 s ring.
		#expect(PreparedAcceptRule.usable(sealedAt: sealed, now: sealed.addingTimeInterval(60)))
	}

	@Test func oldAcceptIsSealedAgain() {
		#expect(!PreparedAcceptRule.usable(sealedAt: sealed, now: sealed.addingTimeInterval(PreparedAcceptRule.maxAgeSeconds)))
		#expect(!PreparedAcceptRule.usable(sealedAt: sealed, now: sealed.addingTimeInterval(600)))
	}

	@Test func clockStepBackIsNotTrusted() {
		#expect(!PreparedAcceptRule.usable(sealedAt: sealed, now: sealed.addingTimeInterval(-1)))
	}

	@Test func ringWindowFitsInsideTheLimit() {
		#expect(PreparedAcceptRule.maxAgeSeconds > 60)
		#expect(PreparedAcceptRule.maxAgeSeconds < 600)  // well inside the relay's ±10 min
	}
}
