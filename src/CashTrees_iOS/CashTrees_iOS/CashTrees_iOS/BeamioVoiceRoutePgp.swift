import ConetChatSDK
import Foundation
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
final class BeamioVoiceRoutePgp: NSObject, WKScriptMessageHandler {
	static let shared = BeamioVoiceRoutePgp()

	private var webView: WKWebView?
	private var bootstrapped = false
	private var ready = false
	private var failed = false
	private var waiting: [() -> Void] = []
	private var fallbackLogged = false
	private var firstEncryptLogged = false

	/// NSLog plus Documents/voice-qa.log (device QA has no console).
	private func trail(_ line: String) {
		BeamioNativeVoiceSignaling.qaTrail("voice-pgp \(line)")
	}

	private override init() {
		super.init()
	}

	/// Armored OpenPGP message for `plaintext`. `completion` runs on the main queue.
	func encrypt(
		plaintext: String,
		routeArmor: String,
		completion: @escaping (Result<String, Error>) -> Void
	) {
		DispatchQueue.main.async {
			self.bootstrapIfNeeded()
			let run = { [weak self] in
				guard let self else { return }
				guard self.ready, let wv = self.webView else {
					self.fallback(plaintext: plaintext, routeArmor: routeArmor, completion: completion)
					return
				}
				wv.callAsyncJavaScript(
					"return await window.beamioVoiceEncrypt(armor, text);",
					arguments: ["armor": routeArmor, "text": plaintext],
					in: nil,
					in: .page
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
		webView = wv
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
			guard let self, !self.ready, !self.failed else { return }
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
		DispatchQueue.main.async {
			guard !self.ready, !self.failed else { return }
			if action == "ready" {
				self.trail("ready")
				self.finishBootstrap(ok: true)
			} else {
				self.trail("start error \((body["message"] as? String) ?? "")")
				self.finishBootstrap(ok: false)
			}
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
