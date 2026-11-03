import Foundation

/// Dialer wake receipt rules (`voice_call_ringing_v1`). Pure: no UIKit, so they
/// can be checked on their own.
///
/// - 8 s without a receipt: "Their phone may be restricting Beamio"; the call
///   keeps ringing.
/// - Five ringback rings without one: "Unreachable", the dialer posts its
///   cancel and ends the call. A receipt after that is ignored.
enum BeamioDialerReceiptRule {
	/// Ringback cadence of `BeamioCallTonePlayer`: 1 s on / 4 s off.
	static let ringCycleMs: Double = 5_000
	/// Rings before the dial counts as unreachable.
	static let unreachableRings: Double = 5
	/// 25 s from the offer's `createdAt`; PWA `VOICE_PEER_UNREACHABLE_MS`.
	static let unreachableAfterMs: Double = ringCycleMs * unreachableRings

	/// Five rings ended: end as unreachable only while the dial still rings
	/// (no accept, decline, hang-up or timeout yet) and no receipt came.
	static func endsUnreachable(stillRinging: Bool, rang: Bool) -> Bool {
		stillRinging && !rang
	}

	/// Seconds from `nowMs` until `afterMs` past the offer's `createdAtMs`; 0 when already past.
	static func delay(createdAtMs: Int, nowMs: Int, afterMs: Double) -> TimeInterval {
		max(0, Double(createdAtMs) + afterMs - Double(nowMs)) / 1000
	}
}
