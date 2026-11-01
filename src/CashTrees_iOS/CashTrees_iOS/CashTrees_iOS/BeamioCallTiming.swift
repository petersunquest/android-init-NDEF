import Foundation

/// Outgoing call timing trail (`[CallTiming]`), matching the PWA's lines.
/// Each line carries wall-clock milliseconds so PWA and native stages line up.
/// Never logs keys, routes, addresses or message content.
/// Debug builds also append to `Documents/call-timing.log` for device QA.
enum BeamioCallTiming {
	private static let lock = NSLock()
	private static var dialId = ""
	private static var tapAt: Int64 = 0

	static func nowMs() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }

	/// The PWA sent `prepareSystemCall` with its dial id and tap time.
	static func begin(dialId: String, tapAt: Int64) {
		lock.lock()
		self.dialId = dialId
		self.tapAt = tapAt
		lock.unlock()
	}

	static func mark(_ stage: String, _ extra: String = "") {
		lock.lock()
		let id = dialId
		let tap = tapAt
		lock.unlock()
		guard !id.isEmpty else { return }
		let now = nowMs()
		let since = tap > 0 ? "+\(now - tap)" : "+?"
		record("[CallTiming] \(id) native:\(stage) t=\(now) \(since)\(extra.isEmpty ? "" : " \(extra)")")
		// The dial's last stage: later calls must not log under this dial id.
		if stage == "listen-open" || stage == "prepare-cancelled" {
			lock.lock()
			if dialId == id { dialId = "" }
			lock.unlock()
		}
	}

	/// PWA `[CallTiming]` console lines come through here as well.
	static func record(_ line: String) {
		NSLog("%@", line)
		appendDebugFile(line)
	}

	/// Debug and QA builds only: append to `Documents/call-timing.log` (no NSLog).
	static func appendDebugFile(_ line: String) {
		#if DEBUG || BEAMIO_QA
		guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
		let url = dir.appendingPathComponent("call-timing.log")
		let data = Data("\(line)\n".utf8)
		lock.lock()
		defer { lock.unlock() }
		if let handle = try? FileHandle(forWritingTo: url) {
			defer { try? handle.close() }
			_ = try? handle.seekToEnd()
			try? handle.write(contentsOf: data)
		} else {
			try? data.write(to: url, options: .atomic)
		}
		#endif
	}
}

/// Call-path QA log for device builds that cannot be attached to Xcode
/// (Ad Hoc with production push). Compiled in only with the `BEAMIO_QA` Swift
/// flag (passed on the xcodebuild command line for QA builds) or in Debug.
/// Writes `Documents/qa-call.log`. Never pass keys, mnemonics, session keys or
/// message text: ids, stages and ok/fail only.
enum BeamioQALog {
	#if DEBUG || BEAMIO_QA
	private static let lock = NSLock()
	private static let formatter: ISO8601DateFormatter = {
		let f = ISO8601DateFormatter()
		f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
		return f
	}()
	#endif

	static func write(_ message: @autoclosure () -> String) {
		#if DEBUG || BEAMIO_QA
		let line = message()
		NSLog("[BeamioQA] %@", line)
		guard let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
		let url = dir.appendingPathComponent("qa-call.log")
		lock.lock()
		defer { lock.unlock() }
		let data = Data("\(formatter.string(from: Date())) \(line)\n".utf8)
		if let handle = try? FileHandle(forWritingTo: url) {
			defer { try? handle.close() }
			_ = try? handle.seekToEnd()
			try? handle.write(contentsOf: data)
		} else {
			try? data.write(to: url, options: .atomic)
		}
		#endif
	}
}
