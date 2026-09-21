package com.beamio.app

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView

/**
 * Native incoming-call surface. Telecom self-managed accounts do not promise
 * that Android will render the dialer's incoming-call screen, so Beamio owns
 * this full-screen, lock-screen-safe surface.
 */
class IncomingCallActivity : Activity() {
    private var callId = ""
    private var sessionId = ""

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON,
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)

        callId = intent.getStringExtra(BeamioTelecomService.EXTRA_CALL_ID).orEmpty()
        sessionId = intent.getStringExtra(BeamioTelecomService.EXTRA_SESSION_ID).orEmpty()
        val displayName = intent.getStringExtra(BeamioTelecomService.EXTRA_DISPLAY_NAME)
            .orEmpty()
            .ifBlank { "Beamio contact" }
        val peerAddress = intent.getStringExtra(BeamioTelecomService.EXTRA_PEER_ADDRESS).orEmpty()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setPadding(32, 48, 32, 48)
            setBackgroundColor(Color.rgb(5, 11, 29))
        }

        val eyebrow = TextView(this).apply {
            text = "BEAMIO VOICE CALL"
            setTextColor(Color.rgb(157, 173, 203))
            textSize = 13f
            gravity = Gravity.CENTER
        }
        root.addView(eyebrow, centeredParams())

        val title = TextView(this).apply {
            text = "Incoming call"
            setTextColor(Color.WHITE)
            textSize = 30f
            gravity = Gravity.CENTER
            setPadding(0, 18, 0, 20)
        }
        root.addView(title, centeredParams())

        root.addView(capsule(displayName, "#243B6B", "#FFFFFF"), centeredParams())
        if (peerAddress.isNotBlank()) {
            root.addView(
                capsule(shortAddress(peerAddress), "#17243D", "#BFD0F2"),
                centeredParams(),
            )
        }

        val spacer = TextView(this)
        root.addView(spacer, LinearLayout.LayoutParams(1, 0, 1f))

        val actions = LinearLayout(this).apply {
            orientation = LinearLayout.HORIZONTAL
            gravity = Gravity.CENTER
        }
        val decline = Button(this).apply {
            text = "Decline"
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.rgb(190, 55, 67))
            setOnClickListener { finishCall("callRejected") }
        }
        val accept = Button(this).apply {
            text = "Accept"
            setTextColor(Color.WHITE)
            setBackgroundColor(Color.rgb(35, 160, 98))
            setOnClickListener { finishCall("callAnswered") }
        }
        actions.addView(decline, actionParams())
        actions.addView(accept, actionParams())
        root.addView(actions)
        setContentView(root)
    }

    private fun finishCall(action: String) {
        BeamioTelecomService.finishIncomingCall(this, action, callId, sessionId)
        finish()
    }

    private fun capsule(text: String, background: String, foreground: String): TextView =
        TextView(this).apply {
            this.text = text
            setTextColor(Color.parseColor(foreground))
            textSize = 16f
            gravity = Gravity.CENTER
            setPadding(28, 14, 28, 14)
                setBackground(GradientDrawable().apply {
                cornerRadius = 80f
                setColor(Color.parseColor(background))
                })
        }

    private fun centeredParams() = LinearLayout.LayoutParams(
        LinearLayout.LayoutParams.WRAP_CONTENT,
        LinearLayout.LayoutParams.WRAP_CONTENT,
    ).apply {
        gravity = Gravity.CENTER_HORIZONTAL
        bottomMargin = 12
    }

    private fun actionParams() = LinearLayout.LayoutParams(0, 56, 1f).apply {
        marginStart = 8
        marginEnd = 8
    }

    private fun shortAddress(raw: String): String {
        val value = raw.trim()
        return if (value.length > 12) "${value.take(6)}…${value.takeLast(4)}" else value
    }
}
