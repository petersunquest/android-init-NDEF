import Foundation

/// Shell-owned Guardian `ip_addr` roster. Reads `GuardianNodesInfoV6.getAllNodes`
/// over CoNET RPC and persists ip + domain (`PGPKey`) + region. The PWA does not
/// supply this list. Mailbox IP is derived by matching the stored route public
/// armor to a node's base64 PGP. RPC failure or a decoded empty list keeps the
/// previous roster.
enum BeamioGuardianRoster {
	private static let contract = "0xBC6b53065b5647261396d002bDBA0d3396E0722f"
	private static let selector = "4272c81e"
	private static let rpcs = [
		"https://rpc1.conet.network",
		"https://publicrpc.conet.network",
	]
	private static let pageSize = 200
	private static let maxPages = 6
	private static let retryEmptySec: TimeInterval = 60
	private static let retryHaveSec: TimeInterval = 300

	private struct Row {
		var node: BeamioChatPgpKeychain.SiNode
		var armor: String
	}

	private static let lock = NSLock()
	private static var inFlight = false
	private static var lastSuccess = Date.distantPast
	private static var pending: DispatchWorkItem?

	/// Safe from launch, foreground, and VoIP wake. Skips when a refresh is running
	/// or a non-empty roster is younger than five minutes.
	static func kick() {
		DispatchQueue.global(qos: .utility).async {
			refresh()
		}
	}

	private static func refresh() {
		lock.lock()
		if inFlight {
			lock.unlock()
			return
		}
		let have = !BeamioChatPgpKeychain.loadSiNodes().isEmpty
		let age = Date().timeIntervalSince(lastSuccess)
		if have && age < retryHaveSec {
			let queued = pending != nil
			lock.unlock()
			if !queued { scheduleNext(after: max(5, retryHaveSec - age)) }
			return
		}
		inFlight = true
		lock.unlock()
		defer {
			lock.lock()
			inFlight = false
			lock.unlock()
			let empty = BeamioChatPgpKeychain.loadSiNodes().isEmpty
			scheduleNext(after: empty ? retryEmptySec : retryHaveSec)
		}
		guard let rows = fetchAll(), !rows.isEmpty else {
			NSLog("[BeamioGuardian] refresh untrusted — kept previous count=%ld", BeamioChatPgpKeychain.loadSiNodes().count)
			return
		}
		let mailbox = matchMailbox(rows)
		let nodes = rows.map(\.node)
		let ok = BeamioChatPgpKeychain.storeChainRoster(nodes: nodes, mailboxIp: mailbox)
		if ok {
			lock.lock()
			lastSuccess = Date()
			lock.unlock()
			NSLog("[BeamioGuardian] roster count=%ld mailbox=%@", nodes.count, mailbox == nil ? "unchanged" : "matched")
		}
	}

	private static func scheduleNext(after seconds: TimeInterval) {
		lock.lock()
		pending?.cancel()
		let work = DispatchWorkItem { refresh() }
		pending = work
		lock.unlock()
		DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds, execute: work)
	}

	private static func fetchAll() -> [Row]? {
		var all: [Row] = []
		var start = 0
		for _ in 0..<maxPages {
			guard let page = fetchPage(start: start, length: pageSize) else { return nil }
			if page.isEmpty { break }
			all.append(contentsOf: page)
			if page.count < pageSize { break }
			start += pageSize
		}
		return all
	}

	private static func fetchPage(start: Int, length: Int) -> [Row]? {
		let data = "0x" + selector + hex256(start) + hex256(length)
		for rpc in rpcs {
			if let body = ethCall(rpc: rpc, data: data), let rows = decode(body) {
				return rows
			}
		}
		return nil
	}

	private static func ethCall(rpc: String, data: String) -> Data? {
		guard let url = URL(string: rpc) else { return nil }
		var req = URLRequest(url: url, timeoutInterval: 22)
		req.httpMethod = "POST"
		req.setValue("application/json", forHTTPHeaderField: "content-type")
		let payload: [String: Any] = [
			"jsonrpc": "2.0",
			"id": 1,
			"method": "eth_call",
			"params": [
				["to": contract, "data": data],
				"latest",
			],
		]
		guard let http = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
		req.httpBody = http
		let sem = DispatchSemaphore(value: 0)
		var resultHex: String?
		let task = URLSession.shared.dataTask(with: req) { data, _, _ in
			defer { sem.signal() }
			guard let data,
			      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			      obj["error"] == nil,
			      let hex = obj["result"] as? String,
			      hex.hasPrefix("0x"), hex.count > 2
			else { return }
			resultHex = hex
		}
		task.resume()
		if sem.wait(timeout: .now() + 25) == .timedOut {
			task.cancel()
			return nil
		}
		guard let resultHex else { return nil }
		let raw = String(resultHex.dropFirst(2))
		guard raw.count % 2 == 0, let bytes = Data(hex: raw) else { return nil }
		return bytes
	}

	/// Dynamic `nodeInfo[]`. Element offsets are relative to the head table
	/// (the word after the array length). Tuple fields: id, PGP, PGPKey, ip_addr, region.
	private static func decode(_ blob: Data) -> [Row]? {
		let bytes = [UInt8](blob)
		guard let outer = u256(bytes, 0), outer + 32 <= bytes.count else { return nil }
		guard let n = u256(bytes, outer), n <= 800 else { return nil }
		if n == 0 { return [] }
		let heads = outer + 32
		var out: [Row] = []
		for i in 0..<n {
			guard let rel = u256(bytes, heads + 32 * i) else { return nil }
			let tup = heads + rel
			guard tup + 32 * 5 <= bytes.count else { return nil }
			guard let pgp = readString(bytes, tup, word: 1),
			      let pgpKey = readString(bytes, tup, word: 2),
			      let ipRaw = readString(bytes, tup, word: 3),
			      let region = readString(bytes, tup, word: 4)
			else { return nil }
			guard let ip = BeamioSiCipherPost.normalizeIp(ipRaw) else { continue }
			let armor = armorFromBase64(pgp)
			let domain = String(pgpKey.trimmingCharacters(in: .whitespacesAndNewlines).prefix(256))
			let regionTrim = String(region.trimmingCharacters(in: .whitespacesAndNewlines).prefix(64))
			out.append(Row(node: .init(ip: ip, domain: domain, region: regionTrim), armor: armor))
		}
		if out.isEmpty { return nil }
		return out
	}

	private static func matchMailbox(_ rows: [Row]) -> String? {
		let route = normalizeArmor(BeamioChatPgpKeychain.loadRoutePublicArmor())
		guard route.contains("BEGIN PGP PUBLIC KEY") else { return nil }
		for row in rows {
			if normalizeArmor(row.armor) == route { return row.node.ip }
		}
		return nil
	}

	private static func armorFromBase64(_ raw: String) -> String {
		let compact = raw.filter { !$0.isWhitespace }
		guard let data = Data(base64Encoded: compact),
		      let text = String(data: data, encoding: .utf8)
		else { return "" }
		return text
	}

	private static func normalizeArmor(_ raw: String) -> String {
		raw.replacingOccurrences(of: "\r\n", with: "\n")
			.replacingOccurrences(of: "\r", with: "\n")
			.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	private static func hex256(_ value: Int) -> String {
		String(format: "%064x", value)
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
	init?(hex: String) {
		let chars = Array(hex)
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
