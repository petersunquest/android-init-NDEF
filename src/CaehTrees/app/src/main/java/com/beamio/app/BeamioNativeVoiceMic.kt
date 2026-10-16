package com.beamio.app

import android.media.AudioFormat
import android.media.AudioRecord
import android.media.MediaRecorder
import android.util.Base64
import android.util.Log
import kotlin.math.abs

/**
 * Records call audio outside WebView. Telecom's MODE_IN_COMMUNICATION makes
 * WebView getUserMedia return digital silence; an app AudioRecord on
 * VOICE_COMMUNICATION still receives the microphone.
 */
class BeamioNativeVoiceMic(
	private val deliver: (pcmBase64: String) -> Unit,
) {
	@Volatile private var running = false
	private var recorder: AudioRecord? = null
	private var thread: Thread? = null

	fun start(): Boolean {
		stop()
		val created = openRecorder() ?: return false
		recorder = created
		running = true
		thread = Thread({
			readLoop(created)
		}, "BeamioNativeMic").also { it.start() }
		return true
	}

	fun stop() {
		running = false
		val active = recorder
		try {
			if (active != null && active.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
				active.stop()
			}
		} catch (_: Exception) {
		}
		thread?.join(500)
		thread = null
		recorder = null
		try {
			active?.release()
		} catch (_: Exception) {
		}
	}

	private fun openRecorder(): AudioRecord? {
		val sources = intArrayOf(
			MediaRecorder.AudioSource.VOICE_COMMUNICATION,
			MediaRecorder.AudioSource.MIC,
			MediaRecorder.AudioSource.DEFAULT,
		)
		for (source in sources) {
			val record = tryCreate(source) ?: continue
			Log.i(TAG, "started source=$source rate=$SAMPLE_RATE")
			return record
		}
		Log.w(TAG, "no audio source could start")
		return null
	}

	private fun tryCreate(source: Int): AudioRecord? {
		val min = AudioRecord.getMinBufferSize(
			SAMPLE_RATE,
			AudioFormat.CHANNEL_IN_MONO,
			AudioFormat.ENCODING_PCM_16BIT,
		)
		if (min <= 0) return null
		val bufferBytes = maxOf(min, FRAME_SAMPLES * 2 * 2)
		val record = try {
			AudioRecord(
				source,
				SAMPLE_RATE,
				AudioFormat.CHANNEL_IN_MONO,
				AudioFormat.ENCODING_PCM_16BIT,
				bufferBytes,
			)
		} catch (error: Exception) {
			Log.w(TAG, "AudioRecord source=$source failed: ${error.message}")
			return null
		}
		if (record.state != AudioRecord.STATE_INITIALIZED) {
			record.release()
			return null
		}
		return try {
			record.startRecording()
			if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
				record.release()
				null
			} else {
				record
			}
		} catch (error: Exception) {
			Log.w(TAG, "startRecording source=$source failed: ${error.message}")
			record.release()
			null
		}
	}

	private fun readLoop(record: AudioRecord) {
		val samples = ShortArray(FRAME_SAMPLES)
		var frames = 0
		while (running) {
			val count = record.read(samples, 0, samples.size)
			if (count < 0) {
				Log.w(TAG, "read failed code=$count")
				break
			}
			if (count == 0) continue
			var peak = 0
			val bytes = ByteArray(count * 2)
			for (i in 0 until count) {
				val sample = samples[i].toInt()
				val magnitude = abs(sample)
				if (magnitude > peak) peak = magnitude
				bytes[i * 2] = (sample and 0xff).toByte()
				bytes[i * 2 + 1] = ((sample shr 8) and 0xff).toByte()
			}
			frames += 1
			if (frames <= 2 || frames == 20) {
				Log.i(TAG, "pcm frame=$frames samples=$count peak=$peak")
			}
			val encoded = Base64.encodeToString(bytes, Base64.NO_WRAP)
			try {
				deliver(encoded)
			} catch (error: Exception) {
				Log.w(TAG, "deliver failed: ${error.message}")
			}
		}
	}

	private companion object {
		const val TAG = "BeamioNativeMic"
		const val SAMPLE_RATE = 16_000
		const val FRAME_SAMPLES = 1280
	}
}
