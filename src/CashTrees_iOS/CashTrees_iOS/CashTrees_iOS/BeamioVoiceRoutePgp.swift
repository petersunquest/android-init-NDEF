import ConetChatSDK
import Foundation
import UIKit
import WebKit

/// Route-PGP encryption for realtime call frames (audio, video, call controls).
///
/// Uses its own hidden WKWebView, separate from `BeamioOpenPgpHost.shared`
/// (which the chat listener also uses), so call frames do not queue behind
/// chat work. Compared with the shared host it:
/// - parses each route key once instead of on every frame;
/// - passes the plaintext as a call argument instead of building a JS source
///   string around 15–20 KB of base64;
/// - zlib-compresses the literal, as the Android shell does. The mailbox's
///   OpenPGP decrypt reads compressed packets; this makes frames ~28 % smaller.
///
/// Falls back to the shared host when this one cannot start.
///
/// Recovery (same rules as the SDK's `BeamioOpenPgpHost`): iOS can end this
/// WebView's content process while the app is suspended. The object stays, so
/// without this every later frame, `channel ready` and Hang Up failed silently
/// until a relaunch (calls connected with no audio either way). Now a terminated
/// process rebuilds the host, a call that finds the page gone rebuilds and runs
/// once more, and `ensureAlive` checks the page before a call needs it.
final class BeamioVoiceRoutePgp: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
	static let shared = BeamioVoiceRoutePgp()

	private var webView: WKWebView?
	private var bootstrapped = false
	private var ready = false
	private var failed = false
	private var waiting: [() -> Void] = []
	private var fallbackLogged = false
	private var firstEncryptLogged = false
	private var binaryFailures = 0
	private var lastProbeAt = Date.distantPast
	private var foregroundObserver: NSObjectProtocol?
	/// Bumped per WebView, so a start timeout of a torn-down one is ignored.
	private var bootGen = 0
	/// Times the host was rebuilt (diagnostics only). Main queue.
	private(set) var resetCount = 0

	/// NSLog plus Documents/voice-qa.log (device QA has no console).
	private func trail(_ line: String) {
		BeamioNativeVoiceSignaling.qaTrail("voice-pgp \(line)")
	}

	private override init() {
		super.init()
		foregroundObserver = NotificationCenter.default.addObserver(
			forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
		) { _ in
			BeamioVoiceRoutePgp.shared.ensureAlive(reason: "foreground")
		}
	}

	/// Armored OpenPGP message for `plaintext`. `completion` runs on the main queue.
	func encrypt(
		plaintext: String,
		routeArmor: String,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		encrypt(plaintext: plaintext, routeArmor: routeArmor, retried: false, completion: completion)
	}

	private func encrypt(
		plaintext: String,
		routeArmor: String,
		retried: Bool,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		DispatchQueue.main.async {
			self.bootstrapIfNeeded()
			// `self` is the app-lifetime singleton, so a strong capture is fine.
			let run = {
				guard self.ready, let wv = self.webView else {
					self.fallback(plaintext: plaintext, routeArmor: routeArmor, completion: completion)
					return
				}
				self.callJs(
					wv, "return await window.beamioVoiceEncrypt(armor, text);",
					arguments: ["armor": routeArmor, "text": plaintext], timeout: Self.encryptTimeout
				) { outcome in
					switch outcome {
					case .success(let value):
						if let armor = value as? String, armor.contains("BEGIN PGP MESSAGE") {
							if !self.firstEncryptLogged {
								self.firstEncryptLogged = true
								self.trail("first encrypt in=\(plaintext.utf8.count) out=\(armor.utf8.count)")
							}
							completion(.success(armor))
						} else {
							self.trail("unexpected result type")
							self.fallback(plaintext: plaintext, routeArmor: routeArmor, completion: completion)
						}
					case .failure(let error):
						let ns = error as NSError
						if self.retryOnDeadPage(wv, ns, what: "encrypt", retried: retried) {
							self.encrypt(plaintext: plaintext, routeArmor: routeArmor, retried: true, completion: completion)
							return
						}
						self.trail(
							"encrypt failed: \((ns.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ns.localizedDescription)"
						)
						self.fallback(plaintext: plaintext, routeArmor: routeArmor, completion: completion)
					}
				}
			}
			if self.ready || self.failed {
				run()
			} else {
				self.waiting.append(run)
			}
		}
	}

	/// Armored OpenPGP message whose literal is `bytes` (binary, no compression:
	/// a v2 voice chunk is AES output). No shared-host fallback: the caller sends
	/// that frame on the v1 path instead. `completion` runs on the main queue.
	func encryptBinary(
		_ bytes: Data,
		routeArmor: String,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		encryptBinary(bytes, routeArmor: routeArmor, retried: false, completion: completion)
	}

	private func encryptBinary(
		_ bytes: Data,
		routeArmor: String,
		retried: Bool,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		DispatchQueue.main.async {
			self.bootstrapIfNeeded()
			// `self` is the app-lifetime singleton, so a strong capture is fine.
			let run = {
				guard self.ready, let wv = self.webView else {
					self.noteBinaryFailure("host not ready (failed=\(self.failed))")
					completion(.failure(NSError(domain: "BeamioVoiceRoutePgp", code: 1)))
					return
				}
				self.callJs(
					wv, "return await window.beamioVoiceEncryptBinary(armor, b64);",
					arguments: ["armor": routeArmor, "b64": bytes.base64EncodedString()], timeout: Self.encryptTimeout
				) { outcome in
					switch outcome {
					case .success(let value):
						if let armor = value as? String, armor.contains("BEGIN PGP MESSAGE") {
							completion(.success(armor))
						} else {
							self.noteBinaryFailure("unexpected result type")
							completion(.failure(NSError(domain: "BeamioVoiceRoutePgp", code: 2)))
						}
					case .failure(let error):
						let ns = error as NSError
						if self.retryOnDeadPage(wv, ns, what: "encryptBinary", retried: retried) {
							self.encryptBinary(bytes, routeArmor: routeArmor, retried: true, completion: completion)
							return
						}
						self.noteBinaryFailure(
							"domain=\(ns.domain) code=\(ns.code) \((ns.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? "")"
						)
						completion(.failure(NSError(domain: "BeamioVoiceRoutePgp", code: 2)))
					}
				}
			}
			if self.ready || self.failed {
				run()
			} else {
				self.waiting.append(run)
			}
		}
	}

	private func fallback(
		plaintext: String,
		routeArmor: String,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		if !fallbackLogged {
			fallbackLogged = true
			trail("fallback to shared OpenPGP host ready=\(ready) failed=\(failed)")
		}
		BeamioOpenPgpHost.shared.encrypt(plaintext: plaintext, publicKeyArmor: routeArmor, completion: completion)
	}

	/// Main queue only.
	private func bootstrapIfNeeded() {
		guard !bootstrapped else { return }
		bootstrapped = true
		guard let (openpgpJs, scriptUrl) = Self.loadOpenPgpScript() else {
			trail("openpgp.min.js not found")
			finishBootstrap(ok: false)
			return
		}
		let config = WKWebViewConfiguration()
		config.userContentController.add(self, name: "BeamioVoicePgp")
		let wv = WKWebView(frame: .zero, configuration: config)
		wv.isHidden = true
		wv.navigationDelegate = self
		webView = wv
		bootGen += 1
		let gen = bootGen
		let html = """
		<!DOCTYPE html><html><head><meta charset="utf-8"/></head><body>
		<script>\(openpgpJs)</script>
		<script>
		(function(){
		  const keys = new Map();
		  window.beamioVoiceEncrypt = async (armor, text) => {
		    let key = keys.get(armor);
		    if (!key) {
		      key = await openpgp.readKey({ armoredKey: armor });
		      if (keys.size >= 8) keys.clear();
		      keys.set(armor, key);
		    }
		    const message = await openpgp.createMessage({ text });
		    return await openpgp.encrypt({
		      message,
		      encryptionKeys: key,
		      format: 'armored',
		      config: { preferredCompressionAlgorithm: openpgp.enums.compression.zlib },
		    });
		  };
		  window.beamioVoiceEncryptBinary = async (armor, b64) => {
		    let key = keys.get(armor);
		    if (!key) {
		      key = await openpgp.readKey({ armoredKey: armor });
		      if (keys.size >= 8) keys.clear();
		      keys.set(armor, key);
		    }
		    const bin = atob(b64);
		    const bytes = new Uint8Array(bin.length);
		    for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
		    const message = await openpgp.createMessage({ binary: bytes });
		    return await openpgp.encrypt({ message, encryptionKeys: key, format: 'armored' });
		  };
		  const post = (m) => window.webkit.messageHandlers.BeamioVoicePgp.postMessage(m);
		  post(typeof openpgp === 'undefined' ? { action: 'error', message: 'openpgp missing' } : { action: 'ready' });
		})();
		</script>
		</body></html>
		"""
		// A file:// base keeps the page a secure context; with no base URL
		// `crypto.subtle` is missing and openpgp.js fails to load.
		wv.loadHTMLString(html, baseURL: scriptUrl.deletingLastPathComponent())
		DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
			guard let self, gen == self.bootGen, !self.ready, !self.failed else { return }
			self.trail("start timeout")
			self.finishBootstrap(ok: false)
		}
	}

	private func finishBootstrap(ok: Bool) {
		ready = ok
		failed = !ok
		let pending = waiting
		waiting.removeAll()
		pending.forEach { $0() }
	}

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
		let from = message.webView
		DispatchQueue.main.async {
			// A page torn down by a reset may still report; only the current one counts.
			guard from === self.webView, !self.ready, !self.failed else { return }
			if action == "ready" {
				self.trail("ready")
				self.finishBootstrap(ok: true)
			} else {
				self.trail("start error \((body["message"] as? String) ?? "")")
				self.finishBootstrap(ok: false)
			}
		}
	}

	// MARK: - Recovery (same rules as the SDK's BeamioOpenPgpHost)

	/// Encrypts take tens of ms (a first key import ~1 s on an old phone, backgrounded).
	static let encryptTimeout: TimeInterval = 4
	static let probeTimeout: TimeInterval = 2

	/// `callAsyncJavaScript` with a watchdog. After its content process dies the
	/// page may never answer (no error, no callback), which left `channel ready`
	/// in flight forever and every frame unsent. No answer in `timeout` counts as
	/// "page gone". `completion` runs once, on the main queue.
	private func callJs(
		_ wv: WKWebView,
		_ body: String,
		arguments: [String: Any],
		timeout: TimeInterval,
		completion: @escaping (Result<Any, Error>) -> Void
	) {
		var done = false
		wv.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { outcome in
			guard !done else { return }
			done = true
			completion(outcome)
		}
		DispatchQueue.main.asyncAfter(deadline: .now() + timeout) {
			guard !done else { return }
			done = true
			completion(.failure(NSError(
				domain: WKError.errorDomain,
				code: WKError.Code.webContentProcessTerminated.rawValue,
				userInfo: [NSLocalizedDescriptionKey: "js call timed out after \(Int(timeout)) s"]
			)))
		}
	}

	/// iOS ended this WebView's content process (usually while suspended).
	func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
		guard webView === self.webView else { return }
		resetHost(reason: "web content process terminated")
	}

	/// Main queue. The next call boots a fresh WebView.
	private func resetHost(reason: String) {
		resetCount += 1
		trail("host reset #\(resetCount): \(reason)")
		if let wv = webView {
			wv.navigationDelegate = nil
			wv.configuration.userContentController.removeScriptMessageHandler(forName: "BeamioVoicePgp")
		}
		webView = nil
		ready = false
		failed = false
		bootstrapped = false
		bootGen += 1
		firstEncryptLogged = false
	}

	/// A call failed because the page is gone (process ended, page blank or not
	/// loaded), not because the script itself failed. Only a JavaScript exception
	/// with its own message (bad armor, bad key) keeps its result. Everything else
	/// counts as a dead page and is rebuilt once: on a real iPhone a killed content
	/// process answers the call at once (5–20 ms, before the terminate callback)
	/// with "result of an unsupported type" (RC3c R14 on the SE). Our functions only
	/// return strings, so that error never comes from the script itself.
	static func isHostGone(_ error: NSError) -> Bool {
		let text = (error.userInfo["WKJavaScriptExceptionMessage"] as? String) ?? ""
		// The page reloaded blank: openpgp.js or our functions are missing in it.
		if text.contains("Can't find variable: openpgp") || text.contains("beamioVoiceEncrypt") {
			return true
		}
		if error.domain == WKError.errorDomain {
			switch WKError.Code(rawValue: error.code) {
			case .javaScriptExceptionOccurred:
				return text.isEmpty
			default:
				return true
			}
		}
		return true
	}

	/// Retry once on a fresh page: the call failed on a dead page, or its page was
	/// already replaced (the terminate callback came first). Main queue.
	private func retryOnDeadPage(_ wv: WKWebView, _ ns: NSError, what: String, retried: Bool) -> Bool {
		let replaced = wv !== webView
		guard !retried, replaced || Self.isHostGone(ns) else { return false }
		// Error domain and code only: no content, no keys.
		trail("\(what) failed on a dead page domain=\(ns.domain) code=\(ns.code) replaced=\(replaced ? "yes" : "no"); retrying once")
		if !replaced { resetHost(reason: "\(what) failed: domain=\(ns.domain) code=\(ns.code)") }
		return true
	}

	/// Check the page before a call needs it (foreground, incoming ring, dial
	/// start) and rebuild it when it is gone, so the rebuild happens before the
	/// user taps rather than on the first frame. Boots the host if it never ran.
	/// At most one probe per 2 s. Any thread.
	func ensureAlive(reason: String) {
		DispatchQueue.main.async {
			if !self.bootstrapped {
				self.bootstrapIfNeeded()
				return
			}
			if self.failed {
				self.resetHost(reason: "start had failed; retry on \(reason)")
				self.bootstrapIfNeeded()
				return
			}
			guard self.ready, let wv = self.webView else { return }
			guard Date().timeIntervalSince(self.lastProbeAt) >= 2 else { return }
			self.lastProbeAt = Date()
			self.callJs(wv, "return typeof window.beamioVoiceEncryptBinary;", arguments: [:], timeout: Self.probeTimeout) { outcome in
				guard wv === self.webView else { return }
				switch outcome {
				case .success(let value) where (value as? String) == "function":
					return
				case .success:
					self.resetHost(reason: "probe on \(reason): page blank")
				case .failure(let error):
					let ns = error as NSError
					self.resetHost(reason: "probe on \(reason): domain=\(ns.domain) code=\(ns.code)")
				}
				self.bootstrapIfNeeded()
			}
		}
	}

	/// Frame encrypt failures were silent; log the first few and then every 50th.
	private func noteBinaryFailure(_ why: String) {
		binaryFailures += 1
		if binaryFailures <= 3 || binaryFailures % 50 == 0 {
			trail("encryptBinary failed #\(binaryFailures): \(why)")
		}
	}

	/// The SDK ships `openpgp.min.js` in its SwiftPM resource bundle
	/// (`ConetChatSDK_ConetChatSDK.bundle` inside the app).
	private static func loadOpenPgpScript() -> (String, URL)? {
		var candidates: [URL] = []
		if let resources = Bundle.main.resourceURL,
		   let items = try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
		{
			for item in items where item.pathExtension == "bundle" && item.lastPathComponent.contains("ConetChatSDK") {
				candidates.append(item.appendingPathComponent("openpgp.min.js"))
				candidates.append(item.appendingPathComponent("ChatCrypto/openpgp.min.js"))
			}
		}
		if let url = Bundle.main.url(forResource: "openpgp.min", withExtension: "js", subdirectory: "ChatCrypto")
			?? Bundle.main.url(forResource: "openpgp.min", withExtension: "js")
		{
			candidates.append(url)
		}
		for url in candidates {
			if let js = try? String(contentsOf: url, encoding: .utf8), !js.isEmpty { return (js, url) }
		}
		return nil
	}
}
