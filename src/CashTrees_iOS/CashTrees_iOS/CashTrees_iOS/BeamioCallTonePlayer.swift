import AVFoundation
import Combine
import Foundation

/// Ringback tone for the dialer ("calling the other side" beeps).
///
/// CallKit plays nothing for an outgoing VoIP call, so the shell plays it.
/// The tone is synthesized here (425 Hz, 1 s on / 4 s off, ITU-T E.180), no
/// audio file. It plays only while:
/// - the in-call screen shows an outgoing call that is not connected yet, and
/// - CallKit has activated the call audio session (`didActivate`).
///
/// It uses its own `AVAudioPlayer` on the CallKit session, so it follows the
/// current route (receiver, speaker, Bluetooth). The voice engine is not
/// running while the dialer waits (it starts on Accept), and
/// `BeamioNativeVoiceChannel.startAudioEngine` stops this tone first, so the
/// tone never overlaps voice processing (AEC).
final class BeamioCallTonePlayer {
	static let shared = BeamioCallTonePlayer()

	private static let sampleRate = 16_000
	private static let toneHz = 425.0
	private static let onSeconds = 1.0
	private static let cycleSeconds = 5.0
	/// About -12 dBFS: clearly audible on the receiver, not loud on speaker.
	private static let amplitude = 0.25
	/// Short ramps so the tone starts and stops without clicks.
	private static let rampSeconds = 0.01

	private var player: AVAudioPlayer?
	/// The busy tone (callee in another call); separate from the ringback.
	private var busyPlayer: AVAudioPlayer?
	private lazy var busyWav: Data = Self.makeBusyWav()
	/// Busy tone: 425 Hz, 0.5 s on / 0.5 s off, three times (ITU-T E.180).
	static let busySeconds: TimeInterval = 3
	/// CallKit's audio session is active (between didActivate and didDeactivate).
	private var callAudioActive = false
	private var screenDialing = false
	/// Voice media started for this dial: no ringback until the screen leaves dialing.
	private var mediaStarted = false
	private var bound = false
	private var cancellables: Set<AnyCancellable> = []
	private lazy var ringbackWav: Data = Self.makeRingbackWav()

	private init() {}

	/// Follow the in-call screen: dialing = live and not yet connected.
	private func bind() {
		guard !bound else { return }
		bound = true
		let model = BeamioInCallScreenModel.shared
		// @Published emits in willSet, so use the emitted values, not the model's.
		// No receive(on:) hop: a stop must take effect at once.
		model.$live.combineLatest(model.$connected)
			.sink { [weak self] live, connected in
				let dialing = live && !connected
				self?.screenDialing = dialing
				if !dialing { self?.mediaStarted = false }
				// Hang-up during the busy tone: stop it with the screen.
				if !live {
					self?.stopBusy(reason: "screen closed")
					self?.dropWaitingBusy()
				}
				self?.update(reason: live ? (connected ? "connected" : "dialing") : "ended")
			}
			.store(in: &cancellables)
	}

	/// CallKit `didActivate` (main thread). Binds on first use: the
	/// subscription replays the screen's current state at once.
	func callAudioDidActivate() {
		bind()
		callAudioActive = true
		update(reason: "didActivate")
		startWaitingBusy()
	}

	/// CallKit `didDeactivate` (main thread).
	func callAudioDidDeactivate() {
		callAudioActive = false
		stopBusy(reason: "didDeactivate")
		update(reason: "didDeactivate")
	}

	/// Stop the busy tone early (the call ended before its 3 s were up). Main thread.
	private func stopBusy(reason: String) {
		guard let busy = busyPlayer else { return }
		busy.stop()
		busyPlayer = nil
		NSLog("[BeamioCallTone] busy stop reason=%@", reason)
	}

	/// Stop now, whatever the screen state (voice engine about to start).
	func stopRingback(reason: String) {
		mediaStarted = true
		guard player != nil else { return }
		stopPlayer(reason: reason)
	}

	/// How long a busy that arrived before `didActivate` waits for the call audio.
	static let busyAudioWait: TimeInterval = 1.5
	/// A busy that arrived before CallKit activated the call audio: its
	/// `completion`, run once the tone has played (or the wait gave up).
	private var busyWaiting: (() -> Void)?
	private var busyGeneration = 0

	/// The callee is in another call: stop the ringback and play the busy tone
	/// on the call's audio session, then `completion` (end the call) about 3 s
	/// later. Main thread.
	///
	/// RC3d b3: the busy reject can arrive before CallKit's `didActivate` (a
	/// fast callee answers within about 0.5 s of the dial), and the tone was
	/// skipped. Now it waits up to `busyAudioWait` for the call audio, then
	/// plays all 3 s. If the audio never comes, the call ends after the old 3 s.
	func playBusy(completion: @escaping () -> Void) {
		mediaStarted = true
		if player != nil { stopPlayer(reason: "busy") }
		busyGeneration += 1
		let generation = busyGeneration
		guard callAudioActive else {
			NSLog("[BeamioCallTone] busy tone waits for call audio")
			BeamioNativeVoiceSignaling.qaTrail("busy-tone-wait")
			busyWaiting = completion
			DispatchQueue.main.asyncAfter(deadline: .now() + Self.busyAudioWait) { [weak self] in
				guard let self, self.busyGeneration == generation, let done = self.busyWaiting else { return }
				self.busyWaiting = nil
				NSLog("[BeamioCallTone] busy tone skipped: call audio not active")
				BeamioNativeVoiceSignaling.qaTrail("busy-tone-skipped")
				let rest = max(0, Self.busySeconds - Self.busyAudioWait)
				DispatchQueue.main.asyncAfter(deadline: .now() + rest) { done() }
			}
			return
		}
		startBusy(completion: completion)
	}

	/// The call audio came up while a busy waited: play it now.
	private func startWaitingBusy() {
		guard let done = busyWaiting else { return }
		busyWaiting = nil
		NSLog("[BeamioCallTone] busy tone starts after didActivate")
		startBusy(completion: done)
	}

	/// The screen closed (End tapped) while a busy waited: no tone, end now.
	private func dropWaitingBusy() {
		guard let done = busyWaiting else { return }
		busyWaiting = nil
		NSLog("[BeamioCallTone] busy tone dropped: screen closed")
		done()
	}

	private func startBusy(completion: @escaping () -> Void) {
		if let next = try? AVAudioPlayer(data: busyWav) {
			next.numberOfLoops = 0
			next.volume = 1
			next.prepareToPlay()
			if next.play() {
				busyPlayer = next
				NSLog("[BeamioCallTone] busy start")
				BeamioNativeVoiceSignaling.qaTrail("busy-tone-start")
			} else {
				NSLog("[BeamioCallTone] busy play refused")
			}
		} else {
			NSLog("[BeamioCallTone] busy player failed")
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + Self.busySeconds) { [weak self] in
			self?.busyPlayer?.stop()
			self?.busyPlayer = nil
			completion()
		}
	}

	private func update(reason: String) {
		if screenDialing && callAudioActive && !mediaStarted {
			startPlayer(reason: reason)
		} else if player != nil {
			stopPlayer(reason: reason)
		}
	}

	private func startPlayer(reason: String) {
		if let player, player.isPlaying { return }
		do {
			let next = try AVAudioPlayer(data: ringbackWav)
			next.numberOfLoops = -1
			next.volume = 1
			next.prepareToPlay()
			guard next.play() else {
				NSLog("[BeamioCallTone] ringback play refused reason=%@", reason)
				return
			}
			player = next
			let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
				.map { $0.portType.rawValue }.joined(separator: ",")
			NSLog("[BeamioCallTone] ringback start reason=%@ out=%@", reason, outputs)
			BeamioNativeVoiceSignaling.qaTrail("ringback-start:\(reason):out=\(outputs)")
		} catch {
			NSLog("[BeamioCallTone] ringback player failed %@", error.localizedDescription)
		}
	}

	private func stopPlayer(reason: String) {
		player?.stop()
		player = nil
		NSLog("[BeamioCallTone] ringback stop reason=%@", reason)
		BeamioNativeVoiceSignaling.qaTrail("ringback-stop:\(reason)")
	}

	/// Three 0.5 s tones with 0.5 s gaps (3 s) as 16 kHz mono 16-bit WAV.
	private static func makeBusyWav() -> Data {
		let total = Int(Double(sampleRate) * busySeconds)
		let on = Int(Double(sampleRate) * 0.5)
		let period = on * 2
		let ramp = Int(Double(sampleRate) * rampSeconds)
		var samples = [Int16](repeating: 0, count: total)
		for start in stride(from: 0, to: total, by: period) {
			for j in 0 ..< on where start + j < total {
				var gain = 1.0
				if j < ramp {
					gain = Double(j) / Double(ramp)
				} else if j >= on - ramp {
					gain = Double(on - j) / Double(ramp)
				}
				let value = sin(2 * Double.pi * toneHz * Double(j) / Double(sampleRate))
				samples[start + j] = Int16(value * amplitude * gain * Double(Int16.max))
			}
		}
		return wav(samples: samples, sampleRate: sampleRate)
	}

	/// One 5 s cycle (1 s tone, 4 s silence) as 16 kHz mono 16-bit WAV.
	private static func makeRingbackWav() -> Data {
		let total = Int(Double(sampleRate) * cycleSeconds)
		let on = Int(Double(sampleRate) * onSeconds)
		let ramp = Int(Double(sampleRate) * rampSeconds)
		var samples = [Int16](repeating: 0, count: total)
		for i in 0 ..< on {
			var gain = 1.0
			if i < ramp {
				gain = Double(i) / Double(ramp)
			} else if i >= on - ramp {
				gain = Double(on - i) / Double(ramp)
			}
			let value = sin(2 * Double.pi * toneHz * Double(i) / Double(sampleRate))
			samples[i] = Int16(value * amplitude * gain * Double(Int16.max))
		}
		return wav(samples: samples, sampleRate: sampleRate)
	}

	private static func wav(samples: [Int16], sampleRate: Int) -> Data {
		var data = Data()
		func put32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
		func put16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
		let byteCount = UInt32(samples.count * 2)
		data.append(contentsOf: Array("RIFF".utf8))
		put32(36 + byteCount)
		data.append(contentsOf: Array("WAVE".utf8))
		data.append(contentsOf: Array("fmt ".utf8))
		put32(16)
		put16(1) // PCM
		put16(1) // mono
		put32(UInt32(sampleRate))
		put32(UInt32(sampleRate * 2))
		put16(2)
		put16(16)
		data.append(contentsOf: Array("data".utf8))
		put32(byteCount)
		samples.withUnsafeBufferPointer { buffer in
			for sample in buffer { put16(UInt16(bitPattern: sample)) }
		}
		return data
	}
}
