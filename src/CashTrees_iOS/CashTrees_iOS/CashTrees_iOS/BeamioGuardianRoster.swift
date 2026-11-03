import ConetChatSDK
import Foundation

/// Guardian node table: owned by the chat SDK (`BeamioGuardianNodeWatch`), which
/// watches GuardianNodesInfoV6's storage root and reads the full table only when it
/// changes (same rules as CoNET-SI). The shell only nudges it at launch, foreground
/// and VoIP wake. The PWA does not supply this list.
enum BeamioGuardianRoster {
	static func kick() {
		BeamioGuardianNodeWatch.shared.kick()
	}
}
