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
	}

	/// CallKit `didDeactivate` (main thread).
	func callAudioDidDeactivate() {
		callAudioActive = false
		update(reason: "didDeactivate")
	}

	/// Stop now, whatever the screen state (voice engine about to start).
	func stopRingback(reason: String) {
		mediaStarted = true
		guard player != nil else { return }
		stopPlayer(reason: reason)
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
