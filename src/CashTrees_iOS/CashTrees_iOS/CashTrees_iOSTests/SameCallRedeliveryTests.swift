import Testing
@testable import CashTrees_iOS

/// The page and PushKit both deliver one incoming call. The second delivery
/// must not delete the first report's entry while that report is still running
/// (SE 2026-11-03: banner rang, Answer gave "Call failed", caller saw a decline).
struct SameCallRedeliveryTests {
	typealias R = BeamioSameCallRedelivery

	@Test func earlyDuplicateKeepsTheEntry() {
		// What already worked: the second delivery 0.74 s into the report.
		#expect(R.decide(pendingReportAge: 0.74, inflightReportAge: 0.80) == .keepPending)
	}

	@Test func slowReportKeepsTheEntry() {
		// SE timeline: report started 02:42:51, PushKit came 02:42:53, the
		// report finished 02:42:54. Before the fix this was cleared at 1.5 s.
		#expect(R.decide(pendingReportAge: 2.0, inflightReportAge: 2.1) == .keepPending)
		#expect(R.decide(pendingReportAge: 9.9, inflightReportAge: 9.95) == .keepPending)
	}

	@Test func neverClearsWhatTheInflightJoinWouldStillJoin() {
		// Whenever the in-flight join below would take the duplicate, the map
		// check must keep the entry: both sides use one window.
		for age in stride(from: 0.0, through: 12.0, by: 0.25) {
			let joins = age < R.inflightWindow
			let decision = R.decide(pendingReportAge: nil, inflightReportAge: age)
			if joins {
				#expect(decision == .keepPending, "age \(age)")
			} else {
				#expect(decision == .clearAndReport, "age \(age)")
			}
		}
	}

	@Test func finishedReportWithDeadCallKitIsReportedAgain() {
		// Flash-hide / system dismiss: report completed, CallKit no longer
		// shows the call. A soft re-delivery must report it again.
		#expect(R.decide(pendingReportAge: nil, inflightReportAge: nil) == .clearAndReport)
	}

	@Test func hungReportIsReportedAgainAfterTheWindow() {
		#expect(R.decide(pendingReportAge: 10.5, inflightReportAge: 10.6) == .clearAndReport)
	}

	@Test func ringingCallGetsItsEntryBack() {
		#expect(R.shouldRestoreIdentity(stillMapped: false, otherEntryForCall: false, endingThisUUID: false))
	}

	@Test func entryIsNotRestoredWhenNotNeededOrUnwanted() {
		#expect(!R.shouldRestoreIdentity(stillMapped: true, otherEntryForCall: false, endingThisUUID: false))
		#expect(!R.shouldRestoreIdentity(stillMapped: false, otherEntryForCall: true, endingThisUUID: false))
		#expect(!R.shouldRestoreIdentity(stillMapped: false, otherEntryForCall: false, endingThisUUID: true))
	}
}
