import Foundation
import WebKit

/// Ephemeral WKWebView that runs bundled `openpgp.min.js` + `ethers.umd.min.js`
/// for killed-app voice offer fetch / decrypt / EIP-191 verify.
final class BeamioOpenPgpHost: NSObject, WKScriptMessageHandler {
	static let shared = BeamioOpenPgpHost()

	private var webView: WKWebView?
	private var ready = false
	private var pending: [(Result<String, Error>) -> Void] = []
	private var bootstrapped = false

	private override init() {
		super.init()
	}

	func ensureReady(completion: @escaping (Bool) -> Void) {
		if ready {
			completion(true)
			return
		}
		DispatchQueue.main.async {
			self.bootstrapIfNeeded()
			self.pending.append { result in
				completion((try? result.get()) != nil || self.ready)
			}
			// Fallback if scripts never signal ready.
			DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
				guard let self, !self.ready else { return }
				self.flushPending(.failure(NSError(domain: "BeamioOpenPgp", code: -1, userInfo: [
					NSLocalizedDescriptionKey: "openpgp host timeout",
				])))
			}
		}
	}

	/// Encrypt plaintext UTF-8 JSON to an armored OpenPGP message for `publicKeyArmor`.
	func encrypt(plaintext: String, publicKeyArmor: String, completion: @escaping (Result<String, Error>) -> Void) {
		runJs(
			"""
			(async () => {
			  const pk = await openpgp.readKey({ armoredKey: \(jsString(publicKeyArmor)) });
			  const message = await openpgp.createMessage({ text: \(jsString(plaintext)) });
			  return await openpgp.encrypt({ message, encryptionKeys: pk, format: 'armored' });
			})()
			""",
			completion: completion
		)
	}

	/// Decrypt armored ciphertext with recipient user PGP private key.
	func decrypt(armor: String, privateKeyArmor: String, completion: @escaping (Result<String, Error>) -> Void) {
		runJs(
			"""
			(async () => {
			  const sk = await openpgp.readPrivateKey({ armoredKey: \(jsString(privateKeyArmor)) });
			  const message = await openpgp.readMessage({ armoredMessage: \(jsString(armor)) });
			  const { data } = await openpgp.decrypt({ message, decryptionKeys: sk, format: 'utf8' });
			  return typeof data === 'string' ? data : String(data);
			})()
			""",
			completion: completion
		)
	}

	/// EIP-191 `verifyMessage(text, signature)` → recovered address (checksummed).
	func verifyMessage(text: String, signature: String, completion: @escaping (Result<String, Error>) -> Void) {
		runJs(
			"""
			(async () => {
			  const addr = ethers.verifyMessage(\(jsString(text)), \(jsString(signature)));
			  return addr;
			})()
			""",
			completion: completion
		)
	}

	// MARK: - WKScriptMessageHandler

	func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
		guard message.name == "BeamioOpenPgp",
		      let body = message.body as? [String: Any],
		      let action = body["action"] as? String
		else { return }
		if action == "ready" {
			ready = true
			flushPending(.success("ready"))
			NSLog("[BeamioOpenPgp] host ready")
		}
	}

	// MARK: - Private

	private func bootstrapIfNeeded() {
		guard !bootstrapped else { return }
		bootstrapped = true
		let config = WKWebViewConfiguration()
		config.preferences.javaScriptEnabled = true
		config.userContentController.add(self, name: "BeamioOpenPgp")
		let wv = WKWebView(frame: .zero, configuration: config)
		wv.isHidden = true
		webView = wv

		guard let openpgpUrl = Bundle.main.url(forResource: "openpgp.min", withExtension: "js", subdirectory: "ChatCrypto")
			?? Bundle.main.url(forResource: "openpgp.min", withExtension: "js"),
		      let ethersUrl = Bundle.main.url(forResource: "ethers.umd.min", withExtension: "js", subdirectory: "ChatCrypto")
			?? Bundle.main.url(forResource: "ethers.umd.min", withExtension: "js"),
		      let openpgpJs = try? String(contentsOf: openpgpUrl, encoding: .utf8),
		      let ethersJs = try? String(contentsOf: ethersUrl, encoding: .utf8)
		else {
			NSLog("[BeamioOpenPgp] missing bundled openpgp/ethers scripts")
			flushPending(.failure(NSError(domain: "BeamioOpenPgp", code: -2, userInfo: [
				NSLocalizedDescriptionKey: "bundled crypto scripts missing",
			])))
			return
		}

		let html = """
		<!DOCTYPE html><html><head><meta charset="utf-8"/></head><body>
		<script>\(ethersJs)</script>
		<script>\(openpgpJs)</script>
		<script>
		(function(){
		  try {
			if (typeof openpgp === 'undefined' || typeof ethers === 'undefined') {
			  window.webkit.messageHandlers.BeamioOpenPgp.postMessage({action:'error', message:'libs missing'});
			  return;
			}
			window.webkit.messageHandlers.BeamioOpenPgp.postMessage({action:'ready'});
		  } catch (e) {
			window.webkit.messageHandlers.BeamioOpenPgp.postMessage({action:'error', message:String(e)});
		  }
		})();
		</script>
		</body></html>
		"""
		wv.loadHTMLString(html, baseURL: Bundle.main.bundleURL)
	}

	private func runJs(_ expression: String, completion: @escaping (Result<String, Error>) -> Void) {
		ensureReady { [weak self] ok in
			guard let self, ok, let wv = self.webView else {
				completion(.failure(NSError(domain: "BeamioOpenPgp", code: -3, userInfo: [
					NSLocalizedDescriptionKey: "openpgp host not ready",
				])))
				return
			}
			wv.evaluateJavaScript(expression) { result, error in
				if let error {
					completion(.failure(error))
					return
				}
				if let s = result as? String {
					completion(.success(s))
					return
				}
				completion(.failure(NSError(domain: "BeamioOpenPgp", code: -4, userInfo: [
					NSLocalizedDescriptionKey: "unexpected js result",
				])))
			}
		}
	}

	private func flushPending(_ result: Result<String, Error>) {
		let callbacks = pending
		pending.removeAll()
		for cb in callbacks {
			cb(result)
		}
	}

	private func jsString(_ raw: String) -> String {
		let escaped = raw
			.replacingOccurrences(of: "\\", with: "\\\\")
			.replacingOccurrences(of: "'", with: "\\'")
			.replacingOccurrences(of: "\n", with: "\\n")
			.replacingOccurrences(of: "\r", with: "\\r")
		return "'\(escaped)'"
	}
}
