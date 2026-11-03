import Testing
@testable import CashTrees_iOS

/// A chat voice_end / timeout may end a call only when the other party of that call signed it.
struct CallControlSignerTests {
	typealias Rule = BeamioCallControlSigner
	let me = "0x00000000000000000000000000000000000000aa"
	let peer = "0x00000000000000000000000000000000000000bb"
	let stranger = "0x00000000000000000000000000000000000000cc"

	/// RC3b V7: we dialed, the callee's mailbox voice_end must end our call at once.
	@Test func calleeEndsACallWeDialed() {
		#expect(Rule.allowed(from: peer, callerEoa: me, calleeEoa: peer, localEoa: me))
		// Checksummed (mixed-case) signer from ecrecover.
		#expect(Rule.allowed(from: "0x00000000000000000000000000000000000000BB", callerEoa: me, calleeEoa: peer, localEoa: me))
		#expect(!Rule.allowed(from: stranger, callerEoa: me, calleeEoa: peer, localEoa: me))
	}

	@Test func callerEndsACallWeGot() {
		#expect(Rule.allowed(from: peer, callerEoa: peer, calleeEoa: me, localEoa: me))
		#expect(!Rule.allowed(from: stranger, callerEoa: peer, calleeEoa: me, localEoa: me))
	}

	@Test func ourOwnMessageNeverEndsTheCall() {
		#expect(!Rule.allowed(from: me, callerEoa: me, calleeEoa: peer, localEoa: me))
		#expect(!Rule.allowed(from: me, callerEoa: peer, calleeEoa: me, localEoa: me))
		#expect(!Rule.allowed(from: "", callerEoa: peer, calleeEoa: me, localEoa: me))
	}

	@Test func unknownPartiesFallBackToTheCallIdCheck() {
		#expect(Rule.allowed(from: stranger, callerEoa: "", calleeEoa: "", localEoa: me))
		#expect(Rule.allowed(from: peer, callerEoa: me, calleeEoa: "", localEoa: me))
		// Local wallet unknown: the caller is the only one we can check.
		#expect(Rule.allowed(from: peer, callerEoa: peer, calleeEoa: "", localEoa: ""))
		#expect(!Rule.allowed(from: stranger, callerEoa: peer, calleeEoa: "", localEoa: ""))
	}
}
