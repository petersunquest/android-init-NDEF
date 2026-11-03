import Foundation

/// Callee: an accept sealed while the call rang is posted at Answer only while it
/// is fresh. The ring lasts at most 60 s; the mailbox work command inside it
/// carries the seal time, so an old one is sealed again instead.
enum PreparedAcceptRule {
	static let maxAgeSeconds: TimeInterval = 120

	static func usable(sealedAt: Date, now: Date) -> Bool {
		let age = now.timeIntervalSince(sealedAt)
		return age >= 0 && age < maxAgeSeconds
	}
}
