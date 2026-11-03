package com.beamio.app

import com.beamio.app.BeamioOverlayPresence.Banner
import com.beamio.app.BeamioOverlayPresence.State
import com.beamio.app.BeamioOverlayPresence.Step
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Overlay glass hidden by the system (RC3c R3, 2026-11-02: Samsung in Settings,
 * overlay added but mPolicyVisibility=false): the system banner must show,
 * and only one incoming window may be visible at a time.
 */
class BeamioOverlayPresenceTest {
    @Test
    fun startsPendingOnlyWhenItCanBeVerified() {
        assertEquals(State.PENDING, BeamioOverlayPresence.initial(canVerify = true))
        // Below Android 15 there is no presentation report: old behavior.
        assertEquals(State.ON_SCREEN, BeamioOverlayPresence.initial(canVerify = false))
    }

    @Test
    fun pendingCountsAsVisibleHiddenDoesNot() {
        assertTrue(BeamioOverlayPresence.countsAsVisible(State.PENDING))
        assertTrue(BeamioOverlayPresence.countsAsVisible(State.ON_SCREEN))
        assertFalse(BeamioOverlayPresence.countsAsVisible(State.HIDDEN))
    }

    @Test
    fun confirmedOnScreenKeepsTheOverlayOnly() {
        assertEquals(Step(State.ON_SCREEN, Banner.NONE), BeamioOverlayPresence.onPresentation(State.PENDING, true))
        // The deadline after confirmation changes nothing.
        assertEquals(Step(State.ON_SCREEN, Banner.NONE), BeamioOverlayPresence.onDeadline(State.ON_SCREEN))
    }

    @Test
    fun overSettingsTheBannerIsPosted() {
        // Never presented: the confirm deadline posts the banner.
        assertEquals(Step(State.HIDDEN, Banner.POST), BeamioOverlayPresence.onDeadline(State.PENDING))
        // Reported not presented before the deadline: same.
        assertEquals(Step(State.HIDDEN, Banner.POST), BeamioOverlayPresence.onPresentation(State.PENDING, false))
    }

    @Test
    fun hiddenLaterPostsTheBannerOnce() {
        // User opens Settings while the overlay was showing.
        assertEquals(Step(State.HIDDEN, Banner.POST), BeamioOverlayPresence.onPresentation(State.ON_SCREEN, false))
        // A repeat "not presented" or the old deadline does not post a second banner.
        assertEquals(Step(State.HIDDEN, Banner.NONE), BeamioOverlayPresence.onPresentation(State.HIDDEN, false))
        assertEquals(Step(State.HIDDEN, Banner.NONE), BeamioOverlayPresence.onDeadline(State.HIDDEN))
    }

    @Test
    fun backOnScreenWithdrawsTheBanner() {
        assertEquals(Step(State.ON_SCREEN, Banner.WITHDRAW), BeamioOverlayPresence.onPresentation(State.HIDDEN, true))
    }

    @Test
    fun neverBothVisible() {
        // Walk a session: pending → hidden (banner) → back (no banner) → hidden again (banner).
        var state = BeamioOverlayPresence.initial(true)
        var bannerUp = false
        fun apply(step: Step) {
            state = step.state
            when (step.banner) {
                Banner.POST -> bannerUp = true
                Banner.WITHDRAW -> bannerUp = false
                Banner.NONE -> Unit
            }
            val overlaySeen = state == State.ON_SCREEN
            assertFalse("overlay and banner both visible", overlaySeen && bannerUp)
            // Someone always sees the call once the state is settled.
            if (state != State.PENDING) assertTrue(overlaySeen || bannerUp)
        }
        apply(BeamioOverlayPresence.onDeadline(state))
        apply(BeamioOverlayPresence.onPresentation(state, true))
        apply(BeamioOverlayPresence.onPresentation(state, false))
        apply(BeamioOverlayPresence.onPresentation(state, true))
    }
}
