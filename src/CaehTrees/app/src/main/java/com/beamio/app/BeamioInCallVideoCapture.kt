package com.beamio.app

import android.graphics.Bitmap
import android.graphics.Matrix
import android.os.SystemClock
import android.util.Log
import android.util.Size
import androidx.activity.ComponentActivity
import androidx.camera.core.CameraSelector
import androidx.camera.core.ImageAnalysis
import androidx.camera.core.ImageProxy
import androidx.camera.core.Preview
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.view.PreviewView
import androidx.core.content.ContextCompat
import java.io.ByteArrayOutputStream
import java.util.concurrent.Executors

/**
 * Front camera → JPEG frames for the in-call video uplink. Same output as iOS
 * `BeamioInCallVideoCapture`: about 5 fps, long edge about 320 px, JPEG quality
 * 35, frames over 48 KB skipped.
 */
object BeamioInCallVideoCapture {
    private const val TAG = "BeamioInCallVideo"
    private const val FRAME_INTERVAL_MS = 200L
    private const val LONG_EDGE = 320
    private const val JPEG_QUALITY = 35
    /**
     * The SI relay rejects a frame whose base64 payload exceeds 12 000 chars
     * (≈ 8.9 KB raw incl. AES + BJPG header), so every JPEG must stay below this.
     */
    private const val MAX_JPEG_BYTES = 8_800
    private val QUALITY_STEPS = intArrayOf(JPEG_QUALITY, 28, 22, 16)

    private val analysisExecutor = Executors.newSingleThreadExecutor()
    private var provider: ProcessCameraProvider? = null
    @Volatile private var onFrame: ((ByteArray, Int, Int) -> Unit)? = null
    @Volatile private var lastFrameAt = 0L
    /** Scale + JPEG time of the frame being handed to the sink (for `[VideoStats]`). */
    @Volatile var lastEncodeMs = -1L
        private set

    val isRunning: Boolean get() = onFrame != null

    /**
     * Bind the front camera to [activity]'s lifecycle. [preview] shows the
     * local picture. [onResult] runs on the main thread.
     */
    fun start(
        activity: ComponentActivity,
        preview: PreviewView?,
        frameSink: (ByteArray, Int, Int) -> Unit,
        onResult: (Result<Unit>) -> Unit,
    ) {
        val future = ProcessCameraProvider.getInstance(activity)
        future.addListener({
            val result = runCatching {
                val cameraProvider = future.get()
                provider = cameraProvider
                val selector = if (cameraProvider.hasCamera(CameraSelector.DEFAULT_FRONT_CAMERA)) {
                    CameraSelector.DEFAULT_FRONT_CAMERA
                } else {
                    CameraSelector.DEFAULT_BACK_CAMERA
                }
                val analysis = ImageAnalysis.Builder()
                    .setResolutionSelector(
                        ResolutionSelector.Builder()
                            .setResolutionStrategy(
                                ResolutionStrategy(
                                    Size(LONG_EDGE, 240),
                                    ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER,
                                ),
                            )
                            .build(),
                    )
                    .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
                    .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_RGBA_8888)
                    .build()
                analysis.setAnalyzer(analysisExecutor) { image -> handleFrame(image) }
                val useCases = mutableListOf<androidx.camera.core.UseCase>(analysis)
                if (preview != null) {
                    useCases += Preview.Builder().build().also {
                        it.surfaceProvider = preview.surfaceProvider
                    }
                }
                cameraProvider.unbindAll()
                onFrame = frameSink
                lastFrameAt = 0L
                cameraProvider.bindToLifecycle(activity, selector, *useCases.toTypedArray())
                Unit
            }
            if (result.isFailure) {
                onFrame = null
                Log.w(TAG, "camera start failed: ${result.exceptionOrNull()?.message}")
            } else {
                Log.i(TAG, "camera started")
            }
            onResult(result)
        }, ContextCompat.getMainExecutor(activity))
    }

    /** Stop frames and release the camera. Safe to call when not running. */
    fun stop() {
        onFrame = null
        runCatching { provider?.unbindAll() }
        provider = null
        Log.i(TAG, "camera stopped")
    }

    private fun handleFrame(image: ImageProxy) {
        try {
            val sink = onFrame ?: return
            val now = SystemClock.elapsedRealtime()
            if (now - lastFrameAt < FRAME_INTERVAL_MS) return
            lastFrameAt = now
            val jpeg = encode(image) ?: return
            lastEncodeMs = SystemClock.elapsedRealtime() - now
            sink(jpeg.first, jpeg.second.width, jpeg.second.height)
        } catch (e: Exception) {
            Log.w(TAG, "frame encode failed: ${e.message}")
        } finally {
            image.close()
        }
    }

    /** Upright, long edge ≤ [LONG_EDGE], JPEG. Returns null when the frame is too large. */
    private fun encode(image: ImageProxy): Pair<ByteArray, Size>? {
        val raw = image.toBitmap()
        val rotation = image.imageInfo.rotationDegrees
        val longEdge = maxOf(raw.width, raw.height)
        val scale = if (longEdge > LONG_EDGE) LONG_EDGE.toFloat() / longEdge else 1f
        val matrix = Matrix().apply {
            postScale(scale, scale)
            if (rotation != 0) postRotate(rotation.toFloat())
        }
        var frame = Bitmap.createBitmap(raw, 0, 0, raw.width, raw.height, matrix, true)
        if (frame !== raw) raw.recycle()
        try {
            // Step quality down, then scale down, until the frame fits the relay limit.
            repeat(3) {
                for (q in QUALITY_STEPS) {
                    val out = ByteArrayOutputStream()
                    frame.compress(Bitmap.CompressFormat.JPEG, q, out)
                    val bytes = out.toByteArray()
                    if (bytes.size in 65 until MAX_JPEG_BYTES) {
                        return bytes to Size(frame.width, frame.height)
                    }
                }
                val smaller = Bitmap.createScaledBitmap(
                    frame,
                    (frame.width * 0.8f).toInt().coerceAtLeast(16),
                    (frame.height * 0.8f).toInt().coerceAtLeast(16),
                    true,
                )
                if (smaller !== frame) frame.recycle()
                frame = smaller
            }
            return null
        } finally {
            frame.recycle()
        }
    }
}
