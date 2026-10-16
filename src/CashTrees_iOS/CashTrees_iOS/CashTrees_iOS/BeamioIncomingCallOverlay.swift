import SwiftUI
import UIKit

/// Verified identity for an inbound Beamio voice call (PWA / soft-seed / PushKit).
struct BeamioIncomingCallPayload: Equatable {
	var callId: String
	var sessionId: String
	var peerAddress: String
	var displayName: String
	var claimedTag: String
	var claimedAddress: String
	var identityWarning: String

	/// CallKit `CXHandle` / `localizedCallerName` — always opaque `"Beamio"`.
	/// Putting `@tag` or a short EOA here recreates dual-header chrome that
	/// crushes the InCall bottom bar (handle ≠ display name).
	var callKitHandle: String { "Beamio" }

	/// Primary identity line for glass / custom Incoming (`@beamioTag`).
	/// Prefer looked-up / `displayName` tag over mismatch-only `claimedTag`.
	/// Never treat app filler `"Beamio"` as a wallet identity.
	var titleTag: String {
		if let tag = Self.normalizedBeamioTag(displayName) { return tag }
		if let tag = Self.normalizedBeamioTag(claimedTag) { return tag }
		return ""
	}

	/// Wallet address for the EOA blue AddressCapsule (verified peer, else claimed).
	var capsuleAddress: String {
		let peer = peerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
		if !peer.isEmpty { return peer }
		return claimedAddress.trimmingCharacters(in: .whitespacesAndNewlines)
	}

	/// Valid `@BeamioTag` only — rejects empty, EOA, and product filler names.
	static func normalizedBeamioTag(_ raw: String) -> String? {
		let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
		guard !trimmed.isEmpty else { return nil }
		let stripped = trimmed.hasPrefix("@") ? String(trimmed.dropFirst()) : trimmed
		if stripped.caseInsensitiveCompare("Beamio") == .orderedSame { return nil }
		if stripped.caseInsensitiveCompare("Beamio call") == .orderedSame { return nil }
		if stripped.range(of: #"^0x[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil {
			return nil
		}
		guard stripped.range(of: #"^[A-Za-z0-9_]{1,32}$"#, options: .regularExpression) != nil else {
			return nil
		}
		// Hex-looking key ids are not BeamioTags.
		if stripped.range(of: #"^[0-9a-fA-F]{16,32}$"#, options: .regularExpression) != nil {
			return nil
		}
		return "@\(stripped)"
	}
}

enum BeamioIncomingAddressFormat {
	/// `0x1234…5678` (first 6 + … + last 4), matching AddressCapsule.
	static func short(_ address: String) -> String {
		let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.count > 10 else { return trimmed }
		let prefix = String(trimmed.prefix(6))
		let suffix = String(trimmed.suffix(4))
		return "\(prefix)…\(suffix)"
	}
}

// MARK: - Glass / custom Incoming (foreground)

/// Full-screen Incoming when the app is `.active` — shows `@beamioTag` + EOA
/// AddressCapsule. CallKit cannot render a capsule; reporting CallKit while
/// active covers this UI (soft-seed empty middle). PushKit / background still
/// use opaque CallKit `"Beamio"`.
struct BeamioIncomingCallGlassView: View {
	let payload: BeamioIncomingCallPayload
	var onAccept: () -> Void
	var onDecline: () -> Void

	private var tagLine: String {
		let t = payload.titleTag
		if !t.isEmpty { return t }
		// Do not show the app name as the caller's identity when we already
		// have a wallet capsule — wait for address→tag lookup / re-report.
		return payload.capsuleAddress.isEmpty ? "Beamio" : "…"
	}

	private var addressLine: String {
		BeamioIncomingAddressFormat.short(payload.capsuleAddress)
	}

	var body: some View {
		ZStack {
			LinearGradient(
				colors: [
					Color(red: 0.18, green: 0.22, blue: 0.24),
					Color(red: 0.12, green: 0.16, blue: 0.18),
					Color(red: 0.08, green: 0.10, blue: 0.12),
				],
				startPoint: .top,
				endPoint: .bottom
			)
			.ignoresSafeArea()

			VStack(spacing: 0) {
				// Product chrome only — caller identity is exclusively `tagLine`
				// (wallet `@beamioTag`). Do not put app name "Beamio" here; it
				// was mistaken for the caller name in acceptance screenshots.
				Text("Beamio Audio…")
					.font(.system(size: 15, weight: .regular))
					.foregroundStyle(Color.white.opacity(0.55))
					.padding(.top, 56)

				Spacer(minLength: 24)

				VStack(spacing: 14) {
					Text(tagLine)
						.font(.system(size: 34, weight: .bold))
						.foregroundStyle(.white)
						.lineLimit(1)
						.minimumScaleFactor(0.7)
						.accessibilityLabel("Caller \(tagLine)")

					if !payload.capsuleAddress.isEmpty {
						Text(addressLine)
							.font(.system(size: 13, weight: .medium, design: .monospaced))
							.foregroundStyle(Color(red: 0.26, green: 0.27, blue: 0.33))
							.padding(.horizontal, 14)
							.padding(.vertical, 8)
							.background(
								Capsule()
									.fill(Color(red: 0.91, green: 0.93, blue: 1.0))
							)
							.overlay(
								Capsule()
									.stroke(Color(red: 0.86, green: 0.89, blue: 0.97), lineWidth: 1)
							)
							.accessibilityLabel(payload.capsuleAddress)
					}

					if !payload.identityWarning.isEmpty {
						Text(payload.identityWarning)
							.font(.system(size: 12, weight: .semibold))
							.foregroundStyle(Color.red.opacity(0.9))
							.multilineTextAlignment(.center)
							.padding(.horizontal, 24)
					}
				}
				.padding(.horizontal, 24)

				Spacer(minLength: 24)

				HStack(spacing: 72) {
					VStack(spacing: 10) {
						Button(action: onDecline) {
							ZStack {
								Circle()
									.fill(Color(red: 1.0, green: 0.23, blue: 0.19))
									.frame(width: 76, height: 76)
								Image(systemName: "xmark")
									.font(.system(size: 28, weight: .bold))
									.foregroundStyle(.white)
							}
						}
						.accessibilityLabel("Decline")
						Text("Decline")
							.font(.system(size: 14, weight: .medium))
							.foregroundStyle(.white)
					}

					VStack(spacing: 10) {
						Button(action: onAccept) {
							ZStack {
								Circle()
									.fill(Color(red: 0.20, green: 0.78, blue: 0.35))
									.frame(width: 76, height: 76)
								Image(systemName: "phone.fill")
									.font(.system(size: 28, weight: .semibold))
									.foregroundStyle(.white)
							}
						}
						.accessibilityLabel("Accept")
						Text("Accept")
							.font(.system(size: 14, weight: .medium))
							.foregroundStyle(.white)
					}
				}
				.padding(.bottom, 56)
			}
		}
	}
}

/// Hosts `BeamioIncomingCallGlassView` above the WebView while foreground.
enum BeamioIncomingCallGlassHost {
	private static var window: UIWindow?
	private static var onAcceptHandler: (() -> Void)?
	private static var onDeclineHandler: (() -> Void)?
	private(set) static var currentPayload: BeamioIncomingCallPayload?

	static var isPresented: Bool { window != nil }

	static func present(
		_ payload: BeamioIncomingCallPayload,
		onAccept: @escaping () -> Void,
		onDecline: @escaping () -> Void
	) {
		dismiss(animated: false)
		currentPayload = payload
		onAcceptHandler = onAccept
		onDeclineHandler = onDecline

		let scene = UIApplication.shared.connectedScenes
			.compactMap { $0 as? UIWindowScene }
			.first(where: { $0.activationState == .foregroundActive })
			?? UIApplication.shared.connectedScenes
			.compactMap { $0 as? UIWindowScene }
			.first

		guard let scene else {
			NSLog("[BeamioIncoming] glass present skipped — no UIWindowScene")
			return
		}

		let root = UIHostingController(
			rootView: BeamioIncomingCallGlassView(
				payload: payload,
				onAccept: onAccept,
				onDecline: onDecline
			)
		)
		root.view.backgroundColor = .clear

		let win = UIWindow(windowScene: scene)
		win.windowLevel = .alert + 2
		win.rootViewController = root
		win.makeKeyAndVisible()
		window = win
		NSLog(
			"[BeamioIncoming] glass presented callId=%@ tag=%@ addr=%@",
			payload.callId,
			payload.titleTag,
			BeamioIncomingAddressFormat.short(payload.capsuleAddress)
		)
	}

	/// Refresh identity (`@tag` / capsule) without tearing down Accept/Decline.
	static func update(_ payload: BeamioIncomingCallPayload) {
		guard isPresented else { return }
		currentPayload = payload
		guard let host = window?.rootViewController as? UIHostingController<BeamioIncomingCallGlassView> else {
			return
		}
		host.rootView = BeamioIncomingCallGlassView(
			payload: payload,
			onAccept: onAcceptHandler ?? {},
			onDecline: onDeclineHandler ?? {}
		)
		NSLog(
			"[BeamioIncoming] glass updated callId=%@ tag=%@ addr=%@",
			payload.callId,
			payload.titleTag,
			BeamioIncomingAddressFormat.short(payload.capsuleAddress)
		)
	}

	static func dismiss(animated: Bool = true) {
		guard let win = window else {
			currentPayload = nil
			onAcceptHandler = nil
			onDeclineHandler = nil
			return
		}
		let finish = {
			win.isHidden = true
			win.rootViewController = nil
			window = nil
			currentPayload = nil
			onAcceptHandler = nil
			onDeclineHandler = nil
		}
		if animated {
			UIView.animate(withDuration: 0.2, animations: {
				win.alpha = 0
			}, completion: { _ in finish() })
		} else {
			finish()
		}
	}
}

// MARK: - Address → @BeamioTag (exact match)

enum BeamioTagAddressLookup {
	/// Exact-address `search-users` → `@tag`. Failure returns nil (keep prior UI).
	static func fetchExactTag(for address: String, completion: @escaping (String?) -> Void) {
		let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
		guard trimmed.range(of: #"^0x[0-9a-fA-F]{40}$"#, options: .regularExpression) != nil else {
			completion(nil)
			return
		}
		var components = URLComponents(string: "https://beamio.app/api/search-users")
		components?.queryItems = [URLQueryItem(name: "keyward", value: trimmed)]
		guard let url = components?.url else {
			completion(nil)
			return
		}
		var request = URLRequest(url: url)
		request.httpMethod = "GET"
		request.timeoutInterval = 12
		URLSession.shared.dataTask(with: request) { data, response, error in
			if error != nil {
				completion(nil)
				return
			}
			guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
			      let data else {
				completion(nil)
				return
			}
			guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
			      let results = json["results"] as? [[String: Any]] else {
				completion(nil)
				return
			}
			let lower = trimmed.lowercased()
			guard let row = results.first(where: {
				(($0["address"] as? String) ?? "").lowercased() == lower
			}) else {
				completion(nil)
				return
			}
			let username = (row["username"] as? String)
				?? (row["accountName"] as? String)
				?? ""
			completion(BeamioIncomingCallPayload.normalizedBeamioTag(username))
		}.resume()
	}
}
