package com.beamio.app

/**
 * Peer keys for a Hang Up sent to the peer's mailbox (when the channel frame
 * cannot go). Callee: the caller's user-PGP and route keys, signed in the offer.
 * Caller: the offer holds our own keys, so the callee's come from the chain
 * ([lookup]). Pure for the unit test.
 */
object HangupMailboxKeys {
    private const val PUBLIC_KEY = "BEGIN PGP PUBLIC KEY"

    fun pick(
        role: BeamioNativeVoiceSignaling.Role,
        offerPgp: String,
        offerRoute: String,
        lookup: () -> Pair<String, String>?,
    ): Pair<String, String>? {
        val keys = if (role == BeamioNativeVoiceSignaling.Role.CALLEE) offerPgp to offerRoute else lookup()
        return keys?.takeIf { it.first.contains(PUBLIC_KEY) && it.second.contains(PUBLIC_KEY) }
    }
}
