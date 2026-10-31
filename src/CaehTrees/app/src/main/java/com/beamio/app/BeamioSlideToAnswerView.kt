package com.beamio.app

import android.content.Context
import android.util.AttributeSet
import android.view.Gravity
import android.view.MotionEvent
import android.view.View
import android.view.accessibility.AccessibilityNodeInfo
import android.widget.FrameLayout
import android.widget.ImageView
import android.widget.TextView

/**
 * Lock-screen "Slide to answer" bar. Drag the white thumb to the right end to
 * answer; letting go earlier springs it back. TalkBack users answer with a
 * plain click on the bar.
 */
class BeamioSlideToAnswerView @JvmOverloads constructor(
    context: Context,
    attrs: AttributeSet? = null,
) : FrameLayout(context, attrs) {

    /** Called once when the thumb reaches the end (or on an accessibility click). */
    var onAnswer: (() -> Unit)? = null

    private val inset = dp(5f)
    private val thumb: ImageView
    private val label: TextView
    private var dragStartX = 0f
    private var thumbStartX = 0f
    private var dragging = false
    private var answered = false

    init {
        setBackgroundResource(R.drawable.bg_slide_answer_track)
        contentDescription = context.getString(R.string.incoming_call_slide_to_answer)
        isClickable = true
        isFocusable = true

        label = TextView(context).apply {
            text = context.getString(R.string.incoming_call_slide_to_answer)
            setTextColor(0xE6FFFFFF.toInt())
            textSize = 17f
            gravity = Gravity.CENTER
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        addView(label, LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT))

        thumb = ImageView(context).apply {
            setBackgroundResource(R.drawable.bg_slide_answer_thumb)
            setImageResource(R.drawable.ic_slide_chevron_right)
            imageTintList = android.content.res.ColorStateList.valueOf(
                context.getColor(R.color.incoming_call_answer),
            )
            scaleType = ImageView.ScaleType.CENTER_INSIDE
            setPadding(dp(14f), dp(14f), dp(14f), dp(14f))
            importantForAccessibility = View.IMPORTANT_FOR_ACCESSIBILITY_NO
        }
        addView(thumb, LayoutParams(0, 0, Gravity.START or Gravity.CENTER_VERTICAL))
    }

    override fun onSizeChanged(w: Int, h: Int, oldw: Int, oldh: Int) {
        super.onSizeChanged(w, h, oldw, oldh)
        val size = h - inset * 2
        // Re-layout outside the current layout pass.
        post {
            thumb.layoutParams = (thumb.layoutParams as LayoutParams).apply {
                width = size
                height = size
                marginStart = inset
            }
            // Keep the label clear of the thumb at rest.
            label.setPadding(size + inset, 0, inset, 0)
        }
    }

    private fun maxTravel(): Float =
        (width - thumb.width - inset * 2).coerceAtLeast(0).toFloat()

    override fun onTouchEvent(event: MotionEvent): Boolean {
        if (answered) return true
        when (event.actionMasked) {
            MotionEvent.ACTION_DOWN -> {
                val left = thumb.left + thumb.translationX
                if (event.x < left || event.x > left + thumb.width) return false
                dragging = true
                dragStartX = event.x
                thumbStartX = thumb.translationX
                parent?.requestDisallowInterceptTouchEvent(true)
                return true
            }
            MotionEvent.ACTION_MOVE -> {
                if (!dragging) return false
                val x = (thumbStartX + event.x - dragStartX).coerceIn(0f, maxTravel())
                thumb.translationX = x
                label.alpha = 1f - (x / maxTravel().coerceAtLeast(1f))
                return true
            }
            MotionEvent.ACTION_UP, MotionEvent.ACTION_CANCEL -> {
                if (!dragging) return false
                dragging = false
                val travel = maxTravel()
                if (event.actionMasked == MotionEvent.ACTION_UP &&
                    travel > 0f && thumb.translationX >= travel * 0.85f
                ) {
                    thumb.animate().translationX(travel).setDuration(80L).start()
                    fireAnswer()
                } else {
                    thumb.animate().translationX(0f).setDuration(180L).start()
                    label.animate().alpha(1f).setDuration(180L).start()
                }
                return true
            }
        }
        return super.onTouchEvent(event)
    }

    /** Accessibility click (TalkBack double-tap) answers directly. */
    override fun performClick(): Boolean {
        super.performClick()
        fireAnswer()
        return true
    }

    override fun onInitializeAccessibilityNodeInfo(info: AccessibilityNodeInfo) {
        super.onInitializeAccessibilityNodeInfo(info)
        info.className = android.widget.Button::class.java.name
    }

    private fun fireAnswer() {
        if (answered) return
        answered = true
        isEnabled = false
        onAnswer?.invoke()
    }

    private fun dp(value: Float): Int =
        (value * resources.displayMetrics.density + 0.5f).toInt()
}
