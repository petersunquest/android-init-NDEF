package com.beamio.beamiondefinit

import android.content.Context
import android.util.Base64
import androidx.core.content.edit

object KeyStorageManager {
    private const val PREFS_NAME = "beamio_init_keys"
    private const val KEY_GLOBAL_KEY0 = "globalKey0"
    private const val KEY_GLOBAL_KEY2 = "globalKey2"

    fun loadGlobalKey0(context: Context): ByteArray? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val b64 = prefs.getString(KEY_GLOBAL_KEY0, null) ?: return null
        return try {
            Base64.decode(b64, Base64.NO_WRAP)
        } catch (_: Exception) {
            null
        }
    }

    fun loadGlobalKey2(context: Context): ByteArray? {
        val prefs = context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val b64 = prefs.getString(KEY_GLOBAL_KEY2, null) ?: return null
        return try {
            Base64.decode(b64, Base64.NO_WRAP)
        } catch (_: Exception) {
            null
        }
    }

    fun loadGlobalKey0Base64(context: Context): String? =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getString(KEY_GLOBAL_KEY0, null)

    fun loadGlobalKey2Base64(context: Context): String? =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).getString(KEY_GLOBAL_KEY2, null)

    fun hasKeys(context: Context): Boolean {
        val k0 = loadGlobalKey0(context)
        val k2 = loadGlobalKey2(context)
        return k0 != null && k0.size == 16 && k2 != null && k2.size == 16
    }

    fun saveKeys(context: Context, key0: ByteArray, key2: ByteArray) {
        require(key0.size == 16) { "globalKey0 must be 16 bytes" }
        require(key2.size == 16) { "globalKey2 must be 16 bytes" }
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit {
            putString(KEY_GLOBAL_KEY0, Base64.encodeToString(key0, Base64.NO_WRAP))
            putString(KEY_GLOBAL_KEY2, Base64.encodeToString(key2, Base64.NO_WRAP))
        }
    }

    /**
     * Parse input to 16-byte array. Supports:
     * 1) Base64: e.g. "AGv8eV..."
     * 2) JSON array: [0, 91, 232, 126, 85, 130, 234, 90, 59, 250, 168, 73, 39, 156, 96, 192]
     */
    fun parseKeyInput(input: String): ByteArray? {
        val trimmed = input.trim()
        if (trimmed.isEmpty()) return null

        return try {
            // Try base64 first
            val decoded = Base64.decode(trimmed, Base64.NO_WRAP)
            if (decoded.size == 16) return decoded

            // Try JSON array format: [0, 91, 232, ...]
            if (trimmed.startsWith("[")) {
                val inner = trimmed.removeSurrounding("[", "]").trim()
                val nums = inner.split(",").map { it.trim().toInt().coerceIn(0, 255) }
                if (nums.size == 16) {
                    ByteArray(16) { nums[it].toByte() }
                } else null
            } else null
        } catch (_: Exception) {
            null
        }
    }
}
