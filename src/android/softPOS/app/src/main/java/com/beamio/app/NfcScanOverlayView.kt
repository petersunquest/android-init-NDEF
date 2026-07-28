package com.beamio.app

import android.animation.ValueAnimator
import android.content.Context
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.RectF
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.animation.LinearInterpolator
import android.widget.Button
import android.widget.FrameLayout
import android.widget.TextView

/**
 * Full-screen NFC read prompt — Android has no Core NFC sheet; mirrors iOS
 * `NFCTagReaderSession.alertMessage` UX for PWA Check Balance / Top-up flows.
 */
class NfcScanOverlayView(
    context: Context,
    private val onCancel: () -> Unit,
) : FrameLayout(context) {

    private val scanLineView = NfcScanLineView(context)
    private var scanAnimator: ValueAnimator? = null

    init {
        setBackgroundColor(0xCC000414.toInt())
        isClickable = true
        isFocusable = true

        addView(
            Button(context).apply {
                text = "Cancel"
                setTextColor(Color.WHITE)
                setBackgroundColor(0x73000000)
                setOnClickListener { onCancel() }
            },
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.TOP or Gravity.START
                topMargin = dp(56)
                leftMargin = dp(16)
            },
        )

        addView(
            TextView(context).apply {
                text = "Read NFC Card"
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
                gravity = Gravity.CENTER
            },
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                topMargin = dp(64)
            },
        )

        val cardFrame = FrameLayout(context)
        cardFrame.addView(
            View(context).apply { setBackgroundColor(Color.WHITE) },
            LayoutParams(dp(280), dp(280)).apply { gravity = Gravity.CENTER },
        )
        cardFrame.addView(
            scanLineView,
            LayoutParams(dp(276), dp(276)).apply { gravity = Gravity.CENTER },
        )
        cardFrame.addView(
            TextView(context).apply {
                text = "Hold your NFC card near the back of this device."
                setTextColor(0xFF86868B.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 12f)
                gravity = Gravity.CENTER
            },
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.BOTTOM or Gravity.CENTER_HORIZONTAL
                bottomMargin = dp(32)
                leftMargin = dp(24)
                rightMargin = dp(24)
            },
        )
        addView(cardFrame, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))
    }

    override fun onAttachedToWindow() {
        super.onAttachedToWindow()
        scanAnimator?.cancel()
        scanAnimator = ValueAnimator.ofFloat(0f, 1f).apply {
            duration = 1800L
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.RESTART
            interpolator = LinearInterpolator()
            addUpdateListener { anim ->
                scanLineView.scanProgress = anim.animatedValue as Float
            }
            start()
        }
    }

    override fun onDetachedFromWindow() {
        scanAnimator?.cancel()
        scanAnimator = null
        super.onDetachedFromWindow()
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()
}

private class NfcScanLineView(context: Context) : View(context) {
    var scanProgress: Float = 0f
        set(value) {
            field = value
            invalidate()
        }

    private val linePaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0xFF1562F0.toInt()
        strokeWidth = 4f
    }
    private val cardPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x1A86868B
        style = Paint.Style.STROKE
        strokeWidth = 4f
    }

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val inset = 8f
        val rect = RectF(inset, inset, width - inset, height - inset)
        canvas.drawRoundRect(rect, 32f, 32f, cardPaint)
        val y = inset + scanProgress * (height - inset * 2f)
        canvas.drawLine(inset, y, width - inset, y, linePaint)
    }
}
