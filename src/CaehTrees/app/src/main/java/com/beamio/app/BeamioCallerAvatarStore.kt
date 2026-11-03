package com.beamio.app

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Paint
import android.graphics.PorterDuff
import android.graphics.PorterDuffXfermode
import android.graphics.Rect
import android.graphics.RectF
import android.graphics.Typeface
import android.util.Base64
import android.util.Log
import org.json.JSONArray
import java.io.File

/**
 * Caller tag and avatar for the call windows, kept on this phone.
 *
 * The BeamioTag avatar is not stored anywhere: it is DiceBear fun-emoji drawn
 * from the tag. Fetching it (or the tag) when a call comes in would tell the
 * server this IP is being called by that wallet. So the page draws the avatars
 * of its contacts ahead of time and hands them here with the tag of each
 * wallet ([put]); a call reads only this store. A caller not in it gets a
 * locally drawn initial (a tag looked up during the call still works, by rule
 * 15, but its avatar is never downloaded).
 */
object BeamioCallerAvatarStore {
    private const val TAG = "BeamioVoiceCall"
    private const val MIRROR_PREFS = "beamio_caller_mirror_v1"
    private const val DIR = "caller_avatars"
    private const val MAX_PNG_BYTES = 64 * 1024
    private const val MAX_ENTRIES = 500

    /** `{address, tag, png}` rows from the page (png = base64, optional). */
    fun put(context: Context, rows: JSONArray): Int {
        val app = context.applicationContext
        val prefs = app.getSharedPreferences(MIRROR_PREFS, Context.MODE_PRIVATE)
        val edit = prefs.edit()
        val dir = File(app.filesDir, DIR).apply { mkdirs() }
        var stored = 0
        for (i in 0 until minOf(rows.length(), 200)) {
            val row = rows.optJSONObject(i) ?: continue
            val address = row.optString("address").trim().lowercase()
            val seed = seedOf(row.optString("tag"))
            if (!address.matches(Regex("^0x[0-9a-f]{40}$")) || seed.isEmpty()) continue
            edit.putString(address, seed)
            val png = row.optString("png").trim()
            if (png.isNotEmpty()) {
                val bytes = runCatching { Base64.decode(png, Base64.DEFAULT) }.getOrNull()
                if (bytes != null && bytes.size in 1..MAX_PNG_BYTES &&
                    BitmapFactory.decodeByteArray(bytes, 0, bytes.size) != null
                ) {
                    runCatching { File(dir, fileName(seed)).writeBytes(bytes) }
                }
            }
            stored++
        }
        if (prefs.all.size + stored > MAX_ENTRIES) edit.clear() // rare; the page sends them again
        edit.apply()
        Log.i(TAG, "caller avatar store put=$stored")
        return stored
    }

    /** The tag the page knows for this wallet ("@tag"), or null. */
    fun tagFor(context: Context, address: String): String? {
        val seed = context.applicationContext.getSharedPreferences(MIRROR_PREFS, Context.MODE_PRIVATE)
            .getString(address.trim().lowercase(), null)
        return seed?.takeIf { it.isNotEmpty() }?.let { "@$it" }
    }

    /** The stored avatar for this tag, circle-cropped; else a drawn initial. Null without a tag. */
    fun avatar(context: Context, tag: String, sizePx: Int = 192): Bitmap? {
        val seed = seedOf(tag)
        if (seed.isEmpty()) return null
        val file = File(File(context.applicationContext.filesDir, DIR), fileName(seed))
        val stored = if (file.isFile) runCatching { BitmapFactory.decodeFile(file.path) }.getOrNull() else null
        return stored?.let { circle(it, sizePx) } ?: initial(seed, sizePx)
    }

    /** Tag without "@" (the DiceBear seed the page uses); empty for placeholders. */
    fun seedOf(tag: String): String {
        val plain = tag.trim().trimStart('@')
        val lower = plain.lowercase()
        if (plain.isEmpty() || lower == "beamio" || lower == "unknown" || lower == "unknow") return ""
        if (plain.matches(Regex("^0x[0-9a-fA-F]{40}$"))) return ""
        return plain
    }

    private fun fileName(seed: String): String =
        seed.lowercase().map { if (it.isLetterOrDigit() || it == '_') it else '_' }.joinToString("") + ".png"

    private fun circle(source: Bitmap, size: Int): Bitmap {
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val paint = Paint(Paint.ANTI_ALIAS_FLAG or Paint.FILTER_BITMAP_FLAG)
        canvas.drawOval(RectF(0f, 0f, size.toFloat(), size.toFloat()), paint)
        paint.xfermode = PorterDuffXfermode(PorterDuff.Mode.SRC_IN)
        val side = minOf(source.width, source.height)
        val left = (source.width - side) / 2
        val top = (source.height - side) / 2
        canvas.drawBitmap(source, Rect(left, top, left + side, top + side), Rect(0, 0, size, size), paint)
        return out
    }

    private val INITIAL_COLORS = intArrayOf(
        0xFF1562F0.toInt(), 0xFF7C3AED.toInt(), 0xFF0E9F6E.toInt(),
        0xFFE8590C.toInt(), 0xFFD6336C.toInt(), 0xFF1098AD.toInt(),
    )

    /** First letter of the tag on a colored circle (color from the tag). */
    fun initial(seed: String, size: Int): Bitmap {
        val out = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888)
        val canvas = Canvas(out)
        val bg = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = INITIAL_COLORS[Math.floorMod(seed.lowercase().hashCode(), INITIAL_COLORS.size)]
        }
        canvas.drawOval(RectF(0f, 0f, size.toFloat(), size.toFloat()), bg)
        val text = Paint(Paint.ANTI_ALIAS_FLAG).apply {
            color = 0xFFFFFFFF.toInt()
            textSize = size * 0.46f
            typeface = Typeface.create(Typeface.DEFAULT, Typeface.BOLD)
            textAlign = Paint.Align.CENTER
        }
        val letter = seed.first().uppercaseChar().toString()
        val y = size / 2f - (text.descent() + text.ascent()) / 2f
        canvas.drawText(letter, size / 2f, y, text)
        return out
    }
}
