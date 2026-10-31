import CryptoKit
import Foundation
import Security

/// Voice channel v2 (CoNET Chat rules 22/23).
///
/// Setup, once per direction: the listener sends `voice_listen` with `v: 2` and a
/// random 32-byte write key `wk` on its 32-hex session (the channel locator). The
/// node answers `voice_ready` with `v: 2`. The listener then tells the peer the
/// write key inside the AES control frame `voice_media_caps_v1` (`chan: 2`, `wk`).
///
/// Every chunk after that is a binary OpenPGP literal to the peer's route key:
/// `CVC2 ‖ locator(16) ‖ HMAC-SHA256(wk, locator ‖ blob)[0..<16] ‖ blob`.
/// The node sees nothing else. `blob` is AES-GCM (session key, AAD = `CVC2 ‖ locator`)
/// over a 28-byte header + data + zero padding:
/// `ver u8=2 | kind u8 | flags u8 | rsv u8 | seq u32 | captureMs u64 | frameId u32 |
///  fragIdx u16 | fragCnt u16 | dataLen u32` (little-endian). `blob` is padded to a
/// multiple of 256 bytes (capped at 9 000) so size says less about audio vs video.
enum BeamioVoiceChannelV2 {
	static let magic = Data("CVC2".utf8)
	static let headerSize = 28
	static let padBucket = 256
	static let maxBlob = 9_000

	enum Kind: UInt8 {
		case audio = 0
		case video = 1
		case control = 2
	}

	struct Peer {
		var locator: Data
		var writeKey: Data
	}

	struct Opened {
		var kind: UInt8
		var seq: Int
		var captureMs: Int64
		var frameId: UInt32
		var data: Data
	}

	enum Error: Swift.Error {
		case badLocator
		case tooLarge
		case malformed
	}

	static func randomWriteKey() -> Data {
		var bytes = [UInt8](repeating: 0, count: 32)
		_ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
		return Data(bytes)
	}

	/// 32 lowercase hex chars → 16 bytes; nil for any other session id.
	static func locator(fromSessionId id: String) -> Data? {
		let hex = id.trimmingCharacters(in: .whitespacesAndNewlines)
		guard hex.count == 32, hex == hex.lowercased() else { return nil }
		var out = Data(capacity: 16)
		var idx = hex.startIndex
		while idx < hex.endIndex {
			let next = hex.index(idx, offsetBy: 2)
			guard let byte = UInt8(hex[idx ..< next], radix: 16) else { return nil }
			out.append(byte)
			idx = next
		}
		return out
	}

	private static func aad(_ locator: Data) -> Data { magic + locator }

	/// Route literal for one chunk (encrypt it as a binary OpenPGP message).
	static func sealChunk(
		sessionKey: SymmetricKey,
		peer: Peer,
		kind: Kind,
		seq: Int,
		captureMs: Int64,
		frameId: UInt32 = 0,
		data: Data
	) throws -> Data {
		var plain = Data(capacity: headerSize + data.count)
		plain.append(2)
		plain.append(kind.rawValue)
		plain.append(0)
		plain.append(0)
		appendLE(&plain, UInt32(truncatingIfNeeded: max(0, seq)))
		appendLE(&plain, UInt64(max(0, captureMs)))
		appendLE(&plain, frameId)
		appendLE(&plain, UInt16(0))
		appendLE(&plain, UInt16(1))
		appendLE(&plain, UInt32(data.count))
		plain.append(data)
		// blob = nonce(12) + plain + tag(16); pad plain so blob hits a bucket.
		let bare = 12 + plain.count + 16
		guard bare <= maxBlob else { throw Error.tooLarge }
		let padded = min(maxBlob, (bare + padBucket - 1) / padBucket * padBucket)
		if padded > bare { plain.append(Data(count: padded - bare)) }
		let sealed = try AES.GCM.seal(plain, using: sessionKey, nonce: AES.GCM.Nonce(), authenticating: aad(peer.locator))
		guard let blob = sealed.combined else { throw Error.malformed }
		var mac = HMAC<SHA256>(key: SymmetricKey(data: peer.writeKey))
		mac.update(data: peer.locator)
		mac.update(data: blob)
		let tag = Data(mac.finalize()).prefix(16)
		return magic + peer.locator + tag + blob
	}

	/// Decrypt a chunk blob written to our own channel.
	static func openChunk(sessionKey: SymmetricKey, ownLocator: Data, blob: Data) throws -> Opened {
		let box = try AES.GCM.SealedBox(combined: blob)
		let plain = try AES.GCM.open(box, using: sessionKey, authenticating: aad(ownLocator))
		guard plain.count >= headerSize, plain[plain.startIndex] == 2 else { throw Error.malformed }
		let base = plain.startIndex
		let dataLen = Int(readLE(plain, base + 24, UInt32.self))
		guard headerSize + dataLen <= plain.count else { throw Error.malformed }
		return Opened(
			kind: plain[base + 1],
			seq: Int(readLE(plain, base + 4, UInt32.self)),
			captureMs: Int64(bitPattern: readLE(plain, base + 8, UInt64.self)),
			frameId: readLE(plain, base + 16, UInt32.self),
			data: plain.subdata(in: (base + headerSize) ..< (base + headerSize + dataLen))
		)
	}

	private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
		var v = value.littleEndian
		withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
	}

	private static func readLE<T: FixedWidthInteger>(_ data: Data, _ offset: Int, _: T.Type) -> T {
		var v: T = 0
		for i in 0 ..< MemoryLayout<T>.size {
			v |= T(data[offset + i]) << (8 * i)
		}
		return v
	}
}
