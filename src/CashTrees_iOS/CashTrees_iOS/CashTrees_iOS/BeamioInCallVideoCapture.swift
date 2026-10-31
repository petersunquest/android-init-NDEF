import AVFoundation
import SwiftUI
import UIKit

/// Front-camera capture for in-call FaceTime (local party only).
///
/// Only starts when the user presses FaceTime on `BeamioInCallScreen`. Peer does
/// not auto-start; stop ends this party's uplink/preview without hanging up.
final class BeamioInCallVideoCapture: NSObject {
	static let shared = BeamioInCallVideoCapture()

	private let session = AVCaptureSession()
	private let sessionQueue = DispatchQueue(label: "beamio.incall.video.session")
	private let output = AVCaptureVideoDataOutput()
	private var lastJpegAt: CFTimeInterval = 0
	/// One Core Image context for the whole session: creating one per frame
	/// cost several milliseconds of CPU on every frame.
	private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])
	private let encodeStatsLock = NSLock()
	private var encodeCount = 0
	private var encodeSumMs = 0.0
	private var encodeMaxMs = 0.0
	private var running = false
	private var configuring = false

	/// JPEG frames for uplink (~5 fps, ~320px wide). Main/session queue may call.
	var onJpegFrame: ((Data, Int, Int) -> Void)?

	override private init() {
		super.init()
		output.alwaysDiscardsLateVideoFrames = true
		output.videoSettings = [
			kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
		]
		output.setSampleBufferDelegate(self, queue: sessionQueue)
	}

	func isRunning() -> Bool { running }

	/// Scale + JPEG time per sent frame since the last call (for `[VideoStats]`).
	func takeEncodeStats() -> (count: Int, sumMs: Double, maxMs: Double) {
		encodeStatsLock.lock()
		defer {
			encodeCount = 0
			encodeSumMs = 0
			encodeMaxMs = 0
			encodeStatsLock.unlock()
		}
		return (encodeCount, encodeSumMs, encodeMaxMs)
	}

	private func noteEncode(since start: CFTimeInterval) {
		let ms = (CACurrentMediaTime() - start) * 1000
		encodeStatsLock.lock()
		encodeCount += 1
		encodeSumMs += ms
		encodeMaxMs = max(encodeMaxMs, ms)
		encodeStatsLock.unlock()
	}

	/// The capture session, for the single local preview layer.
	var captureSession: AVCaptureSession { session }

	/// Request camera permission then start. English error on deny.
	/// Permission UI must be requested from the main queue.
	func start(completion: @escaping (Result<Void, Error>) -> Void) {
		let finish: (Result<Void, Error>) -> Void = { result in
			DispatchQueue.main.async { completion(result) }
		}
		let beginAuthorized: () -> Void = { [weak self] in
			guard let self else { return }
			self.sessionQueue.async {
				self.startAuthorized(completion: finish)
			}
		}
		DispatchQueue.main.async {
			if self.running {
				finish(.success(()))
				return
			}
			switch AVCaptureDevice.authorizationStatus(for: .video) {
			case .authorized:
				beginAuthorized()
			case .notDetermined:
				AVCaptureDevice.requestAccess(for: .video) { granted in
					if granted {
						beginAuthorized()
					} else {
						finish(.failure(CaptureError.permissionDenied))
					}
				}
			case .denied, .restricted:
				finish(.failure(CaptureError.permissionDenied))
			@unknown default:
				finish(.failure(CaptureError.permissionDenied))
			}
		}
	}

	func stop() {
		sessionQueue.async { [weak self] in
			guard let self else { return }
			guard self.running || self.session.isRunning else { return }
			self.running = false
			if self.session.isRunning {
				self.session.stopRunning()
			}
			NSLog("[BeamioInCallVideo] stop")
		}
	}

	private func startAuthorized(completion: @escaping (Result<Void, Error>) -> Void) {
		if configuring {
			DispatchQueue.main.async { completion(.failure(CaptureError.busy)) }
			return
		}
		configuring = true
		defer { configuring = false }
		do {
			try configureSessionIfNeeded()
			if !session.isRunning {
				session.startRunning()
			}
			running = session.isRunning
			NSLog("[BeamioInCallVideo] start running=%@", running ? "yes" : "no")
			DispatchQueue.main.async {
				if self.running {
					completion(.success(()))
				} else {
					completion(.failure(CaptureError.cameraUnavailable))
				}
			}
		} catch {
			running = false
			DispatchQueue.main.async { completion(.failure(error)) }
		}
	}

	private func configureSessionIfNeeded() throws {
		if session.inputs.isEmpty == false, session.outputs.contains(output) {
			return
		}
		session.beginConfiguration()
		// Video only. Never let the capture session reconfigure the app audio
		// session — CallKit owns it, and a change there drops call audio.
		session.automaticallyConfiguresApplicationAudioSession = false
		session.sessionPreset = .medium
		session.inputs.forEach { session.removeInput($0) }
		session.outputs.forEach { session.removeOutput($0) }

		guard
			let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
				?? AVCaptureDevice.default(for: .video)
		else {
			session.commitConfiguration()
			throw CaptureError.cameraUnavailable
		}
		let input = try AVCaptureDeviceInput(device: device)
		guard session.canAddInput(input) else {
			session.commitConfiguration()
			throw CaptureError.cameraUnavailable
		}
		session.addInput(input)
		guard session.canAddOutput(output) else {
			session.commitConfiguration()
			throw CaptureError.cameraUnavailable
		}
		session.addOutput(output)
		if let connection = output.connection(with: .video) {
			if connection.isVideoMirroringSupported {
				connection.isVideoMirrored = true
			}
			// iOS 17+: videoOrientation → videoRotationAngle (portrait == 90°)
			if connection.isVideoRotationAngleSupported(90) {
				connection.videoRotationAngle = 90
			}
		}
		session.commitConfiguration()
	}

	enum CaptureError: LocalizedError {
		case permissionDenied
		case cameraUnavailable
		case busy

		var errorDescription: String? {
			switch self {
			case .permissionDenied:
				return "Camera access is required for FaceTime. Enable Camera for Beamio in Settings and try again."
			case .cameraUnavailable:
				return "Camera is unavailable on this device."
			case .busy:
				return "Camera is busy. Try again in a moment."
			}
		}
	}
}

extension BeamioInCallVideoCapture: AVCaptureVideoDataOutputSampleBufferDelegate {
	func captureOutput(
		_ output: AVCaptureOutput,
		didOutput sampleBuffer: CMSampleBuffer,
		from connection: AVCaptureConnection
	) {
		guard running, onJpegFrame != nil else { return }
		let now = CACurrentMediaTime()
		// ~5 fps — keeps Soft/mailbox uplink light until §2A chunking lands.
		guard now - lastJpegAt >= 0.2 else { return }
		lastJpegAt = now
		guard let pixel = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
		let ci = CIImage(cvPixelBuffer: pixel)
		let width = CVPixelBufferGetWidth(pixel)
		let height = CVPixelBufferGetHeight(pixel)
		// Downscale long edge to ~320 for bandwidth.
		let longEdge = max(width, height)
		let scale = longEdge > 320 ? 320.0 / CGFloat(longEdge) : 1.0
		let scaled: CIImage
		if scale < 1 {
			scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
		} else {
			scaled = ci
		}
		let outW = Int(scaled.extent.width.rounded())
		let outH = Int(scaled.extent.height.rounded())
		guard outW > 0, outH > 0 else { return }
		guard let cg = ciContext.createCGImage(scaled, from: scaled.extent) else { return }
		// The SI relay rejects a frame whose base64 payload exceeds 12 000 chars
		// (≈ 8.9 KB raw incl. AES + BJPG header): step quality, then size, down
		// until the JPEG fits.
		let maxJpegBytes = 8_800
		var image = UIImage(cgImage: cg)
		for _ in 0 ..< 3 {
			for quality in [0.35, 0.28, 0.22, 0.16] as [CGFloat] {
				if let jpeg = image.jpegData(compressionQuality: quality),
				   jpeg.count > 64, jpeg.count < maxJpegBytes
				{
					let w = Int(image.size.width * image.scale)
					let h = Int(image.size.height * image.scale)
					noteEncode(since: now)
					onJpegFrame?(jpeg, w, h)
					return
				}
			}
			let next = CGSize(width: image.size.width * 0.8, height: image.size.height * 0.8)
			let format = UIGraphicsImageRendererFormat()
			format.scale = 1
			image = UIGraphicsImageRenderer(size: next, format: format).image { _ in
				image.draw(in: CGRect(origin: .zero, size: next))
			}
		}
		NSLog("[BeamioInCallVideo] frame skipped: JPEG over the relay limit")
	}
}

/// UIView hosting the local FaceTime preview layer.
final class BeamioInCallVideoPreviewView: UIView {
	override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

	var previewLayer: AVCaptureVideoPreviewLayer {
		layer as! AVCaptureVideoPreviewLayer
	}

	func attach(session: AVCaptureSession) {
		previewLayer.session = session
		previewLayer.videoGravity = .resizeAspectFill
	}
}

struct BeamioInCallLocalPreviewRepresentable: UIViewRepresentable {
	func makeUIView(context: Context) -> BeamioInCallVideoPreviewView {
		let view = BeamioInCallVideoPreviewView()
		// One preview layer only: each attach reconfigures the running session.
		view.attach(session: BeamioInCallVideoCapture.shared.captureSession)
		return view
	}

	func updateUIView(_ uiView: BeamioInCallVideoPreviewView, context: Context) {
		uiView.previewLayer.videoGravity = .resizeAspectFill
	}
}
