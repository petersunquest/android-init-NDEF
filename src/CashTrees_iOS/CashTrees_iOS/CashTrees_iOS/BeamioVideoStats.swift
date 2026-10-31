import Foundation

/// Call media counters, logged every 2 s as one `[VideoStats]` line while
/// video is active (QA: before/after comparisons). Thread-safe.
final class BeamioVideoStats {
	struct Window {
		// Sender
		var txCap = 0
		var txSent = 0
		var txDropBusy = 0
		var txDropAudio = 0
		var txDropRoute = 0
		var txOk = 0
		var txFail = 0
		var txJpegBytes = 0
		var txWireBytes = 0
		var txEncMsSum = 0
		var txPostMsSum = 0
		var txPostMsMax = 0
		var capEncodeMsSum = 0.0
		var capEncodeMsMax = 0.0
		var capEncodeN = 0
		// Receiver
		var rxIn = 0
		var rxShown = 0
		var rxSuperseded = 0
		var rxBytes = 0
		var rxLatSum = 0
		var rxLatN = 0
		var rxLatMin = Int.max
		var rxLatMax = 0
		var rxJitterSum = 0
		var rxJitterN = 0
		// Audio
		var audioTx = 0
		var audioTxWireBytes = 0
		var audioRx = 0
		var audioUnderrun = 0
		var audioGapSkip = 0
	}

	private let lock = NSLock()
	private var w = Window()
	private var lastArrivalMs: Int64 = 0
	private var lastCaptureMs: Int64 = 0

	func update(_ change: (inout Window) -> Void) {
		lock.lock()
		change(&w)
		lock.unlock()
	}

	func reset() {
		lock.lock()
		w = Window()
		lastArrivalMs = 0
		lastCaptureMs = 0
		lock.unlock()
	}

	/// One received video frame with a sender capture time (BJP2). Latency
	/// includes the clock offset between the two phones; jitter does not.
	func noteRxTiming(captureMs: Int64, arrivalMs: Int64) {
		lock.lock()
		let lat = Int(arrivalMs - captureMs)
		w.rxLatSum += lat
		w.rxLatN += 1
		w.rxLatMin = min(w.rxLatMin, lat)
		w.rxLatMax = max(w.rxLatMax, lat)
		if lastArrivalMs > 0, captureMs > lastCaptureMs {
			let spread = (arrivalMs - lastArrivalMs) - (captureMs - lastCaptureMs)
			w.rxJitterSum += Int(abs(spread))
			w.rxJitterN += 1
		}
		if captureMs > lastCaptureMs {
			lastArrivalMs = arrivalMs
			lastCaptureMs = captureMs
		}
		lock.unlock()
	}

	/// Returns the log line and clears the window, or nil when no video moved.
	func flush(mode: String, peerCaps: Int, seconds: Double) -> String? {
		lock.lock()
		let s = w
		w = Window()
		lock.unlock()
		guard s.txCap > 0 || s.rxIn > 0 else { return nil }
		func avg(_ sum: Int, _ n: Int) -> Int { n > 0 ? sum / n : 0 }
		func fps(_ n: Int) -> String { String(format: "%.1f", Double(n) / max(seconds, 0.1)) }
		let posts = s.txOk + s.txFail
		return [
			"[VideoStats] mode=\(mode) peerCaps=\(peerCaps)",
			"tx cap=\(s.txCap) sent=\(s.txSent) ok=\(s.txOk) fail=\(s.txFail) fps=\(fps(s.txOk))",
			"drop busy=\(s.txDropBusy) audio=\(s.txDropAudio) route=\(s.txDropRoute)",
			"jpegAvg=\(avg(s.txJpegBytes, s.txSent))B wireAvg=\(avg(s.txWireBytes, s.txSent))B",
			"capEncAvg=\(String(format: "%.1f", s.capEncodeN > 0 ? s.capEncodeMsSum / Double(s.capEncodeN) : 0))ms capEncMax=\(String(format: "%.1f", s.capEncodeMsMax))ms",
			"pgpAvg=\(avg(s.txEncMsSum, s.txSent))ms postAvg=\(avg(s.txPostMsSum, posts))ms postMax=\(s.txPostMsMax)ms",
			"| rx in=\(s.rxIn) shown=\(s.rxShown) superseded=\(s.rxSuperseded) fps=\(fps(s.rxShown)) bytesAvg=\(avg(s.rxBytes, s.rxIn))B",
			"latAvg=\(avg(s.rxLatSum, s.rxLatN))ms latMin=\(s.rxLatN > 0 ? s.rxLatMin : 0)ms latMax=\(s.rxLatMax)ms jitterAvg=\(avg(s.rxJitterSum, s.rxJitterN))ms",
			"| audio tx=\(s.audioTx) wireAvg=\(avg(s.audioTxWireBytes, s.audioTx))B rx=\(s.audioRx) underrun=\(s.audioUnderrun) gapSkip=\(s.audioGapSkip)",
		].joined(separator: " ")
	}
}
