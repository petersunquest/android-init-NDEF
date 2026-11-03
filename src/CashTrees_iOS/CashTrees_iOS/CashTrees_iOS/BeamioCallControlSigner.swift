import Foundation

/// Who may end a call with a chat `voice_end_v1` / `voice_call_timeout_v1`: the
/// other party of that call, by its recovered EIP-191 signer. Pure (unit-tested).
///
/// The shell caches our own dial's offer too, with `callerEoa` = our wallet and
/// `to` = the callee. Checking only `callerEoa` dropped the callee's end on a call
/// we dialed (RC3b V7: the page ended it about 2 s later instead).
nonisolated enum BeamioCallControlSigner {
	/// `callerEoa` / `calleeEoa`: from the cached offer ("" when unknown).
	static func allowed(from: String, callerEoa: String, calleeEoa: String, localEoa: String) -> Bool {
		let signer = norm(from)
		let caller = norm(callerEoa)
		let callee = norm(calleeEoa)
		let local = norm(localEoa)
		guard !signer.isEmpty else { return false }
		// Our own message coming back is never the peer ending the call.
		if !local.isEmpty, signer == local { return false }
		// No caller known: the secret callId is the only check (as before).
		guard !caller.isEmpty else { return true }
		if !local.isEmpty, caller == local {
			// We dialed: the callee ends it. Callee unknown → callId check only.
			return callee.isEmpty || signer == callee
		}
		// We were called: the caller ends it.
		return signer == caller
	}

	private static func norm(_ s: String) -> String {
		s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
	}
}
