package com.beamio.app

/**
 * Is the incoming overlay glass really on screen? Android hides third-party
 * TYPE_APPLICATION_OVERLAY windows over system pages (Settings, permission
 * dialogs): the window stays added, so "attached" is not "seen".
 *
 * The overlay starts PENDING and must be confirmed on screen within
 * [CONFIRM_MS]; otherwise, or when it is hidden later, the system incoming
 * banner (CallStyle) is posted. When the overlay comes back on screen the
 * banner is withdrawn, so the two are never both visible.
 * Pure state machine, unit-tested off the device.
 */
internal object BeamioOverlayPresence {
    const val CONFIRM_MS = 500L

    enum class State { PENDING, ON_SCREEN, HIDDEN }

    /** What to do with the system incoming banner after a step. */
    enum class Banner { NONE, POST, WITHDRAW }

    data class Step(val state: State, val banner: Banner)

    /** PENDING counts as visible: the banner waits at most [CONFIRM_MS]. */
    fun countsAsVisible(state: State): Boolean = state != State.HIDDEN

    /** Start state for a new overlay. Without a way to verify, keep the old behavior. */
    fun initial(canVerify: Boolean): State = if (canVerify) State.PENDING else State.ON_SCREEN

    /** The system reported the overlay on screen ([visible]) or not. */
    fun onPresentation(state: State, visible: Boolean): Step = when {
        visible && state == State.HIDDEN -> Step(State.ON_SCREEN, Banner.WITHDRAW)
        visible -> Step(State.ON_SCREEN, Banner.NONE)
        state == State.HIDDEN -> Step(State.HIDDEN, Banner.NONE)
        else -> Step(State.HIDDEN, Banner.POST)
    }

    /** [CONFIRM_MS] passed: still unconfirmed means hidden. */
    fun onDeadline(state: State): Step =
        if (state == State.PENDING) Step(State.HIDDEN, Banner.POST) else Step(state, Banner.NONE)
}
