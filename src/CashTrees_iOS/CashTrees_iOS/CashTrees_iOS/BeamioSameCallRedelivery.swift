import Foundation

/// The page and PushKit can each deliver the same incoming call. When the
/// second delivery arrives, the native map already holds the call but CallKit
/// may not show it yet because `reportNewIncomingCall` has not completed.
///
/// SE 2026-11-03: the app had just come to the foreground and the page had
/// reloaded 10 s earlier, so the first report took about 3 s. The PushKit
/// delivery came 2 s in, saw a report "older than 1.5 s", deleted the map entry
/// and then joined that same report. The banner rang with no native entry:
/// Answer failed ("Call failed") and the end went out as a decline.
nonisolated enum BeamioSameCallRedelivery {
	/// A duplicate delivery inside this window joins the running report
	/// instead of reporting again. The map check and the in-flight join both
	/// use it, so one never clears what the other still waits on.
	static let inflightWindow: CFAbsoluteTime = 10

	enum Decision: Equatable {
		/// The first report is still running: keep its map entry and wait for it.
		case keepPending
		/// The first report finished and CallKit no longer shows the call:
		/// clear the map entry and report the call again.
		case clearAndReport
	}

	/// - Parameters:
	///   - pendingReportAge: seconds since the map entry's `reportNewIncomingCall`
	///     started, or nil once it has completed.
	///   - inflightReportAge: seconds since the running report for this call id
	///     started, or nil when none is running.
	static func decide(
		pendingReportAge: CFAbsoluteTime?,
		inflightReportAge: CFAbsoluteTime?
	) -> Decision {
		if let age = pendingReportAge, age < inflightWindow { return .keepPending }
		if let age = inflightReportAge, age < inflightWindow { return .keepPending }
		return .clearAndReport
	}

	/// After `reportNewIncomingCall` succeeds the banner rings, so the call must
	/// have a native entry or Answer is refused. Put the entry back when another
	/// path removed it while the report was waiting, unless another entry
	/// already stands for this call or we are ending this UUID ourselves.
	static func shouldRestoreIdentity(
		stillMapped: Bool,
		otherEntryForCall: Bool,
		endingThisUUID: Bool
	) -> Bool {
		!stillMapped && !otherEntryForCall && !endingThisUUID
	}
}
