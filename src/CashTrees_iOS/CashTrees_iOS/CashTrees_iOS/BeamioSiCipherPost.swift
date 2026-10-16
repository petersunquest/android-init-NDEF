import Foundation

/// One-shot OpenPGP ciphertext POST for the native shell.
/// Target is `http://{Guardian ip}/post` with body `{ "data": armor }` only.
/// The shell picks the entry IP from its roster and never lets the PWA name a URL.
enum BeamioSiCipherPost {
	struct Result {
		var ok: Bool
		var status: Int
		var body: String
		var error: String
	}

	static func normalizeIp(_ raw: String) -> String? {
		var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty, !trimmed.contains("/"), !trimmed.contains(" ") else { return nil }
		if trimmed.hasPrefix("[") && trimmed.hasSuffix("]") {
			trimmed = String(trimmed.dropFirst().dropLast())
		}
		if trimmed.contains(":") {
			guard trimmed.filter({ $0 == ":" }).count >= 2, !trimmed.contains(".") else { return nil }
			return trimmed
		}
		let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
		guard parts.count == 4 else { return nil }
		for part in parts {
			guard !part.isEmpty, part.count <= 3, part.allSatisfy({ $0.isNumber }) else { return nil }
			if part.count > 1 && part.hasPrefix("0") { return nil }
			guard let n = Int(part), (0 ... 255).contains(n) else { return nil }
		}
		return trimmed
	}

	static func postUrl(for ip: String) -> URL? {
		guard let ip = normalizeIp(ip) else { return nil }
		if ip.contains(":") {
			return URL(string: "http://[\(ip)]/post")
		}
		return URL(string: "http://\(ip)/post")
	}

	/// Shuffle roster IPs, drop mailbox B and caller excludes, POST until one 2xx.
	static func post(
		armor: String,
		nodes: [BeamioChatPgpKeychain.SiNode],
		excludeIps: Set<String>,
		maxAttempts: Int = 4,
		timeout: TimeInterval = 12
	) -> Result {
		let trimmed = armor.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.contains("BEGIN PGP MESSAGE") else {
			return Result(ok: false, status: 0, body: "", error: "not_pgp")
		}
		let blocked = Set(excludeIps.compactMap { normalizeIp($0) })
		var ips = nodes.compactMap { normalizeIp($0.ip) }.filter { !blocked.contains($0) }
		ips = Array(Set(ips)).shuffled()
		guard !ips.isEmpty else {
			return Result(ok: false, status: 0, body: "", error: "no_si_roster")
		}
		guard let body = try? JSONSerialization.data(withJSONObject: ["data": trimmed]) else {
			return Result(ok: false, status: 0, body: "", error: "encode")
		}
		let attempts = ips.prefix(max(1, maxAttempts))
		var lastStatus = 0
		for ip in attempts {
			guard let url = postUrl(for: ip) else { continue }
			var request = URLRequest(url: url, timeoutInterval: timeout)
			request.httpMethod = "POST"
			request.setValue("application/json", forHTTPHeaderField: "Content-Type")
			request.httpBody = body
			let sem = DispatchSemaphore(value: 0)
			var status = 0
			var text = ""
			let task = URLSession.shared.dataTask(with: request) { data, response, _ in
				status = (response as? HTTPURLResponse)?.statusCode ?? 0
				if let data, let s = String(data: data, encoding: .utf8) {
					text = s
				}
				sem.signal()
			}
			task.resume()
			_ = sem.wait(timeout: .now() + timeout + 1)
			lastStatus = status
			if (200 ..< 300).contains(status) {
				NSLog("[BeamioSiPost] http ip ok status=%d", status)
				let capped = text.count > 48_000 ? String(text.prefix(48_000)) : text
				return Result(ok: true, status: status, body: capped, error: "")
			}
		}
		NSLog("[BeamioSiPost] http ip failed status=%d tried=%d", lastStatus, attempts.count)
		return Result(ok: false, status: lastStatus, body: "", error: "post_failed")
	}
}
