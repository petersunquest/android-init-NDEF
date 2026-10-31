import ConetChatSDK
import Foundation

/// Read-only AddressPGP `searchKey(address)` over CoNET RPC.
/// Returns user + mailbox route public keys (armored) and routePgpKeyID (Guardian domain).
enum BeamioAddressPgp {
	static let contract = "0x684b0ac760cEE9c9b85de36d69746420648Cf9e2"
	/// `bytes4(keccak256("searchKey(address)"))`
	private static let selector = "052f2778"
	private static let rpcs = [
		"https://rpc1.conet.network",
		"https://publicrpc.conet.network",
	]

	struct Keys {
		var userPgpKeyID: String
		var userPublicKeyArmored: String
		var routePgpKeyID: String
		var routePublicKeyArmored: String
		var routeOnline: Bool
	}

	/// Keys per address. Answering a call needs the caller's route key, and the
	/// answer happens when the app may be suspended or the network is not up yet
	/// (the accept used to fail in ~90 ms and left a dead-air call). The key is
	/// therefore read while the call is still ringing and reused for the accept.
	private static let cacheLock = NSLock()
	private static var cache: [String: (at: Date, keys: Keys)] = [:]
	private static let cacheTTL: TimeInterval = 600

	/// Look the address up in the background so a later `searchKey` is a cache hit.
	static func prefetch(address: String) {
		DispatchQueue.global(qos: .userInitiated).async {
			_ = searchKey(address: address)
		}
	}

	/// Blocking RPC; call off the main queue.
	static func searchKey(address: String) -> Keys? {
		let eoa = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard eoa.hasPrefix("0x"), eoa.count == 42 else { return nil }
		cacheLock.lock()
		let cached = cache[eoa]
		cacheLock.unlock()
		if let cached, Date().timeIntervalSince(cached.at) < cacheTTL {
			return cached.keys
		}
		guard let keys = fetchKeys(eoa: eoa) else { return nil }
		cacheLock.lock()
		cache[eoa] = (Date(), keys)
		cacheLock.unlock()
		return keys
	}

	private static func fetchKeys(eoa: String) -> Keys? {
		let addrWord = String(eoa.dropFirst(2)).lowercased()
		guard addrWord.count == 40 else { return nil }
		let data = "0x\(selector)000000000000000000000000\(addrWord)"
		guard let hex = ethCall(data: data),
		      let decoded = Data(hexString: String(hex.dropFirst(2)))
		else { return nil }
		let bytes = [UInt8](decoded)
		// ABI: (string,string,string,string,bool) → head at offset 0 is dynamic tuple.
		guard bytes.count >= 32 * 5 else { return nil }
		let base = 0
		guard let userId = readString(bytes, base, word: 0),
		      let userPub = readString(bytes, base, word: 1),
		      let routeId = readString(bytes, base, word: 2),
		      let routePub = readString(bytes, base, word: 3)
		else { return nil }
		let online = (u256(bytes, base + 32 * 4) ?? 0) != 0
		let userArmor = decodeMaybeBase64Armor(userPub)
		let routeArmor = decodeMaybeBase64Armor(routePub)
		guard routeArmor.contains("BEGIN PGP PUBLIC KEY") else { return nil }
		return Keys(
			userPgpKeyID: userId,
			userPublicKeyArmored: userArmor,
			routePgpKeyID: routeId.trimmingCharacters(in: .whitespacesAndNewlines),
			routePublicKeyArmored: routeArmor,
			routeOnline: online
		)
	}

	/// Match `routePgpKeyID` to a Guardian SiNode.domain → mailbox B IP to exclude.
	static func mailboxIp(forRoutePgpKeyID routeId: String, nodes: [BeamioChatPgpKeychain.SiNode]) -> String? {
		let want = routeId.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
		guard !want.isEmpty else { return nil }
		for node in nodes {
			let domain = node.domain.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
			if !domain.isEmpty, domain == want || domain.hasPrefix(want) || want.hasPrefix(domain) {
				return BeamioSiCipherPost.normalizeIp(node.ip)
			}
		}
		return nil
	}

	// MARK: - RPC / ABI

	private static func ethCall(data: String) -> String? {
		let body: [String: Any] = [
			"jsonrpc": "2.0",
			"id": 1,
			"method": "eth_call",
			"params": [
				["to": contract, "data": data],
				"latest",
			],
		]
		guard let payload = try? JSONSerialization.data(withJSONObject: body) else { return nil }
		for rpc in rpcs {
			guard let url = URL(string: rpc) else { continue }
			var req = URLRequest(url: url, timeoutInterval: 12)
			req.httpMethod = "POST"
			req.setValue("application/json", forHTTPHeaderField: "Content-Type")
			req.httpBody = payload
			let sem = DispatchSemaphore(value: 0)
			var resultHex: String?
			let started = Date()
			URLSession.shared.dataTask(with: req) { data, response, error in
				defer { sem.signal() }
				let ms = Int(Date().timeIntervalSince(started) * 1000)
				if let error {
					NSLog("[BeamioAddressPgp] rpc=%@ failed after %dms: %@", rpc, ms, error.localizedDescription)
					return
				}
				guard let data,
				      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
				      let hex = obj["result"] as? String,
				      hex.hasPrefix("0x"), hex.count > 2
				else {
					let status = (response as? HTTPURLResponse)?.statusCode ?? -1
					NSLog("[BeamioAddressPgp] rpc=%@ bad response status=%d after %dms", rpc, status, ms)
					return
				}
				resultHex = hex
			}.resume()
			_ = sem.wait(timeout: .now() + 14)
			if let resultHex { return resultHex }
		}
		return nil
	}

	private static func decodeMaybeBase64Armor(_ raw: String) -> String {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		if trimmed.contains("BEGIN PGP PUBLIC KEY") { return trimmed }
		if let data = BeamioLenientBase64.decode(trimmed),
		   let text = String(data: data, encoding: .utf8),
		   text.contains("BEGIN PGP PUBLIC KEY")
		{
			return text
		}
		return trimmed
	}

	private static func u256(_ bytes: [UInt8], _ off: Int) -> Int? {
		guard off >= 0, off + 32 <= bytes.count else { return nil }
		for i in 0..<24 where bytes[off + i] != 0 { return nil }
		var v: UInt64 = 0
		for i in 24..<32 { v = (v << 8) | UInt64(bytes[off + i]) }
		guard v <= UInt64(Int.max) else { return nil }
		return Int(v)
	}

	private static func readString(_ bytes: [UInt8], _ tup: Int, word: Int) -> String? {
		guard let rel = u256(bytes, tup + 32 * word) else { return nil }
		let abs = tup + rel
		guard let len = u256(bytes, abs), len < 200_000, abs + 32 + len <= bytes.count else { return nil }
		let data = Data(bytes[abs + 32 ..< abs + 32 + len])
		return String(data: data, encoding: .utf8)
	}
}

private extension Data {
	init?(hexString: String) {
		let chars = Array(hexString)
		guard chars.count % 2 == 0 else { return nil }
		var out = Data(capacity: chars.count / 2)
		var i = 0
		while i < chars.count {
			guard let b = UInt8(String(chars[i...i + 1]), radix: 16) else { return nil }
			out.append(b)
			i += 2
		}
		self = out
	}
}
