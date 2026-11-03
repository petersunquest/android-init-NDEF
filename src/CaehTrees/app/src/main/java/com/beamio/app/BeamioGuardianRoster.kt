package com.beamio.app

import android.content.Context
import network.conet.chat.BeamioEntryPool
import network.conet.chat.BeamioGuardianNodeWatch

/**
 * Guardian node table: owned by the chat SDK ([BeamioGuardianNodeWatch]), which
 * watches GuardianNodesInfoV6's storage root and reads the full table only when it
 * changes (same rules as CoNET-SI). The shell only nudges it at launch and push
 * wake. The PWA does not supply this list.
 */
object BeamioGuardianRoster {
    fun kick(context: Context) {
        BeamioEntryPool.attach(context)
        BeamioGuardianNodeWatch.kick(context)
    }
}
