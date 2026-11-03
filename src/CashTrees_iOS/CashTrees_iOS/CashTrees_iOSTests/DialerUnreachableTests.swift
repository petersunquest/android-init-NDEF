import Testing
@testable import CashTrees_iOS

/// Dialer: no `voice_call_ringing_v1` after five ringback rings ends the call as Unreachable.
struct DialerUnreachableTests {
	typealias Rule = BeamioDialerReceiptRule

	@Test func fiveRingsOfTheRingbackAre25Seconds() {
		// 425 Hz, 1 s on / 4 s off: five rings = 25 s, as in the PWA.
		#expect(Rule.unreachableAfterMs == 25_000)
		#expect(BeamioNativeVoiceSignaling.peerUnreachableMs == Rule.unreachableAfterMs)
		#expect(Rule.unreachableAfterMs / 1000 > BeamioNativeVoiceSignaling.peerWakeTimeout)
		#expect(Rule.unreachableAfterMs < BeamioNativeVoiceSignaling.ringWindowMs)
	}

	@Test func endsOnlyWhileRingingWithoutReceipt() {
		#expect(Rule.endsUnreachable(stillRinging: true, rang: false))
		// A receipt before the five rings: keep ringing until accept / decline / 60 s.
		#expect(!Rule.endsUnreachable(stillRinging: true, rang: true))
		// Accepted, declined, hung up or timed out already: nothing to end.
		#expect(!Rule.endsUnreachable(stillRinging: false, rang: false))
		#expect(!Rule.endsUnreachable(stillRinging: false, rang: true))
	}

	@Test func timerCountsFromTheOffersCreation() {
		// The page attached the dialer 1.2 s after it created the offer.
		#expect(Rule.delay(createdAtMs: 100_000, nowMs: 101_200, afterMs: 25_000) == 23.8)
		// Attached late (after the five rings): fire at once.
		#expect(Rule.delay(createdAtMs: 100_000, nowMs: 130_000, afterMs: 25_000) == 0)
	}
}
