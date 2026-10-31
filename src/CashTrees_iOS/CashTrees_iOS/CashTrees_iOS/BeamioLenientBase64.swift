import Foundation

/// Base64 as the web clients write and read it: standard or URL-safe alphabet,
/// padding optional, whitespace ignored.
///
/// `Data(base64Encoded:)` rejects a string whose `=` padding was dropped. Some
/// accounts registered a route key on chain without padding (for example
/// `@rrr01`), which the browser and Node decode without complaint. The shell then
/// could not read that caller's route key, the native Answer could not be sent,
/// and the call stayed connected in CallKit with no call behind it.
enum BeamioLenientBase64 {
	static func decode(_ raw: String) -> Data? {
		var s = raw.filter { !$0.isWhitespace }
		guard !s.isEmpty else { return nil }
		s = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
		let remainder = s.count % 4
		if remainder == 1 { return nil }
		if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
		return Data(base64Encoded: s)
	}
}
