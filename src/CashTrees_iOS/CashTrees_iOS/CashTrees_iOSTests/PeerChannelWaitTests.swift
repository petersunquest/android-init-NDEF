import XCTest
@testable import CashTrees_iOS

/// The caller now sends `channel ready` before its own listen is up. These check
/// that the callee's first frames are not lost while the caller's channel opens:
/// the relay keeps nothing, so the callee posts them again.
final class PeerChannelWaitTests: XCTestCase {
	typealias Outcome = BeamioNativeVoiceChannel.PostOutcome
	private let notFound: Outcome = (false, 200, 40, "target_voice_session_not_found")
	private let accepted: Outcome = (true, 200, 40, "")

	/// Virtual clock: `sleep` advances it, `now` reads it.
	private final class Clock {
		var t: TimeInterval = 0
		var date: Date { Date(timeIntervalSince1970: t) }
	}

	func testNotFoundIsRetriedUntilTheChannelExists() {
		let clock = Clock()
		var calls = 0
		let r = BeamioNativeVoiceChannel.postRetryingUntilPeerChannel(
			seenBefore: false,
			post: { calls += 1; return calls < 6 ? self.notFound : self.accepted },
			sleep: { clock.t += $0 },
			now: { clock.date }
		)
		XCTAssertTrue(r.outcome.ok)
		XCTAssertEqual(r.tries, 6)
		XCTAssertEqual(clock.t, 5 * BeamioNativeVoiceChannel.peerChannelRetryGap, accuracy: 0.001)
	}

	func testNoRetryOnceAFrameWasAccepted() {
		var calls = 0
		let r = BeamioNativeVoiceChannel.postRetryingUntilPeerChannel(
			seenBefore: true,
			post: { calls += 1; return self.notFound },
			sleep: { _ in XCTFail("must not wait") },
			now: { Date() }
		)
		XCTAssertFalse(r.outcome.ok)
		XCTAssertEqual(calls, 1)
	}

	func testOtherErrorsAreNotRetried() {
		var calls = 0
		let r = BeamioNativeVoiceChannel.postRetryingUntilPeerChannel(
			seenBefore: false,
			post: { calls += 1; return (false, 200, 40, "voice_chunk_auth") },
			sleep: { _ in XCTFail("must not wait") },
			now: { Date() }
		)
		XCTAssertFalse(r.outcome.ok)
		XCTAssertEqual(calls, 1)
	}

	func testGivesUpAfterTheWindow() {
		let clock = Clock()
		let r = BeamioNativeVoiceChannel.postRetryingUntilPeerChannel(
			seenBefore: false,
			post: { self.notFound },
			sleep: { clock.t += $0 },
			now: { clock.date }
		)
		XCTAssertFalse(r.outcome.ok)
		XCTAssertLessThanOrEqual(clock.t, BeamioNativeVoiceChannel.peerChannelWaitSeconds + BeamioNativeVoiceChannel.peerChannelRetryGap)
		XCTAssertGreaterThanOrEqual(clock.t, BeamioNativeVoiceChannel.peerChannelWaitSeconds - 0.01)
	}

	/// Frames every 160 ms from t = 0, the caller's listen opens at `open`, at most
	/// 10 posts in flight (the shell's cap). Every frame must arrive, in order of
	/// capture, the first one within one retry gap of the channel opening.
	func testNoFrameLostWhileTheCallerListenOpens() {
		for open in [0.0, 0.5, 1.0, 1.4] {
			var finishes: [TimeInterval] = []
			var dropped = 0
			for i in 0 ..< 30 {
				let start = Double(i) * 0.16
				if finishes.filter({ $0 > start }).count >= 10 {
					dropped += 1
					continue
				}
				let clock = Clock()
				clock.t = start
				let r = BeamioNativeVoiceChannel.postRetryingUntilPeerChannel(
					seenBefore: false,
					post: { clock.t >= open ? self.accepted : self.notFound },
					sleep: { clock.t += $0 },
					now: { clock.date }
				)
				XCTAssertTrue(r.outcome.ok, "frame \(i) open=\(open)")
				finishes.append(clock.t)
			}
			XCTAssertEqual(dropped, 0, "open=\(open)")
			XCTAssertLessThanOrEqual(finishes[0], max(open, 0) + BeamioNativeVoiceChannel.peerChannelRetryGap + 0.001)
		}
	}
}
