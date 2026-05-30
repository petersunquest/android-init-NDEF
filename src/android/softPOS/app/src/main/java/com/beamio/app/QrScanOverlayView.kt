package com.beamio.app

import android.Manifest
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.net.Uri
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.core.content.ContextCompat
import com.google.zxing.BarcodeFormat
import com.google.zxing.BinaryBitmap
import com.google.zxing.DecodeHintType
import com.google.zxing.MultiFormatReader
import com.google.zxing.NotFoundException
import com.google.zxing.RGBLuminanceSource
import com.google.zxing.common.HybridBinarizer
import com.journeyapps.barcodescanner.BarcodeCallback
import com.journeyapps.barcodescanner.BarcodeResult
import com.journeyapps.barcodescanner.DecoratedBarcodeView
import com.journeyapps.barcodescanner.DefaultDecoderFactory

/**
 * In-app QR scanner overlay — shown when PWA calls `CashTreesAndroid.scanQr` after NFC cancel
 * (Check Balance / Top-up). Keeps WebView loaded under native UI, matching iOS modal handoff.
 */
class QrScanOverlayView(
    private val host: MainActivity,
    private val onSuccess: (String) -> Unit,
    private val onCancel: (String) -> Unit,
) : FrameLayout(host) {

    private val barcodeView: DecoratedBarcodeView
    private var didFinish = false
    private var pickingFromLibrary = false
    private var lastDecodedText: String? = null

    init {
        layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        setBackgroundColor(Color.BLACK)

        barcodeView = DecoratedBarcodeView(context).apply {
            layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
            statusView?.visibility = GONE
            viewFinder?.visibility = GONE
            barcodeView.decoderFactory = DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE))
        }
        addView(barcodeView)
        addView(buildChromeOverlay())
    }

    fun startScanning() {
        if (didFinish) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            onCancel("camera_permission_denied")
            return
        }
        startCameraScan()
    }

    fun pauseScan() {
        if (!didFinish) barcodeView.pause()
    }

    fun resumeScan() {
        if (didFinish || pickingFromLibrary) return
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA) != PackageManager.PERMISSION_GRANTED) {
            return
        }
        lastDecodedText = null
        barcodeView.resume()
    }

    fun release() {
        didFinish = true
        barcodeView.pause()
    }

    /** Called by [MainActivity] after user picks an image/file. */
    fun onExternalImageUri(uri: Uri?) {
        pickingFromLibrary = false
        if (uri == null) {
            resumeScan()
            return
        }
        val decoded = decodeQrFromUri(uri)
        if (!decoded.isNullOrBlank()) {
            finishSuccess(decoded.trim())
        } else {
            resumeScan()
        }
    }

    fun beginLibraryPick() {
        pauseScan()
        pickingFromLibrary = true
    }

    fun cancelLibraryPick() {
        pickingFromLibrary = false
        resumeScan()
    }

    private fun buildChromeOverlay(): View {
        val overlay = FrameLayout(context).apply {
            layoutParams = LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.MATCH_PARENT)
        }
        overlay.addView(QrDimmedScanOverlayView(context))

        overlay.addView(
            Button(context).apply {
                text = "Cancel"
                setTextColor(Color.WHITE)
                setBackgroundColor(0x73000000)
                setOnClickListener { finishCancelled("cancelled") }
            },
            LayoutParams(LayoutParams.WRAP_CONTENT, LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.TOP or Gravity.START
                topMargin = dp(56)
                leftMargin = dp(16)
            },
        )

        overlay.addView(
            TextView(context).apply {
                text = "Scan QR Code"
                setTextColor(Color.WHITE)
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 20f)
                gravity = Gravity.CENTER
            },
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
                topMargin = dp(64)
            },
        )

        val bottomPanel = LinearLayout(context).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        bottomPanel.addView(
            TextView(context).apply {
                text = "Align the code within the square"
                setTextColor(0xD1FFFFFF.toInt())
                setTextSize(TypedValue.COMPLEX_UNIT_SP, 14f)
                gravity = Gravity.CENTER
            },
        )
        bottomPanel.addView(
            Button(context).apply {
                text = "Choose Photo or File"
                setTextColor(Color.WHITE)
                setBackgroundColor(0xEB1562F0.toInt())
                setOnClickListener { host.showQrChooseSourceDialog(this@QrScanOverlayView) }
            },
            LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                LinearLayout.LayoutParams.WRAP_CONTENT,
            ).apply { topMargin = dp(18) },
        )
        overlay.addView(
            bottomPanel,
            LayoutParams(LayoutParams.MATCH_PARENT, LayoutParams.WRAP_CONTENT).apply {
                gravity = Gravity.BOTTOM
                bottomMargin = dp(24)
                leftMargin = dp(24)
                rightMargin = dp(24)
            },
        )
        return overlay
    }

    private fun startCameraScan() {
        barcodeView.decodeContinuous(object : BarcodeCallback {
            override fun barcodeResult(result: BarcodeResult) {
                if (didFinish || pickingFromLibrary) return
                val raw = result.text ?: return
                if (raw == lastDecodedText) return
                lastDecodedText = raw
                finishSuccess(raw.trim())
            }

            override fun possibleResultPoints(resultPoints: MutableList<com.google.zxing.ResultPoint>?) {}
        })
        barcodeView.resume()
    }

    private fun finishSuccess(text: String) {
        if (didFinish) return
        didFinish = true
        barcodeView.pause()
        onSuccess(text)
    }

    private fun finishCancelled(error: String) {
        if (didFinish) return
        didFinish = true
        barcodeView.pause()
        onCancel(error)
    }

    private fun decodeQrFromUri(uri: Uri): String? {
        return try {
            host.contentResolver.openInputStream(uri)?.use { input ->
                val bitmap = BitmapFactory.decodeStream(input) ?: return null
                val width = bitmap.width
                val height = bitmap.height
                val pixels = IntArray(width * height)
                bitmap.getPixels(pixels, 0, width, 0, 0, width, height)
                val source = RGBLuminanceSource(width, height, pixels)
                val binaryBitmap = BinaryBitmap(HybridBinarizer(source))
                MultiFormatReader().apply {
                    setHints(
                        mapOf(
                            DecodeHintType.POSSIBLE_FORMATS to listOf(BarcodeFormat.QR_CODE),
                            DecodeHintType.TRY_HARDER to true,
                        ),
                    )
                }.decode(binaryBitmap).text
            }
        } catch (_: NotFoundException) {
            null
        } catch (_: Exception) {
            null
        }
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()
}

private class QrDimmedScanOverlayView(context: android.content.Context) : View(context) {
    private val dimPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x85000000.toInt()
        style = Paint.Style.FILL
    }
    private val borderPaint = Paint(Paint.ANTI_ALIAS_FLAG).apply {
        color = 0x99FFFFFF.toInt()
        style = Paint.Style.STROKE
        strokeWidth = 4f * resources.displayMetrics.density
    }
    private val scanRect = RectF()

    override fun onDraw(canvas: Canvas) {
        super.onDraw(canvas)
        val side = minOf(width, height) * 0.68f
        val left = (width - side) / 2f
        val top = (height - side) / 2f - dp(28)
        scanRect.set(
            left,
            maxOf(top, dp(120).toFloat()),
            left + side,
            maxOf(top, dp(120).toFloat()) + side,
        )
        val radius = dp(14).toFloat()
        val path = Path().apply {
            fillType = Path.FillType.EVEN_ODD
            addRect(0f, 0f, width.toFloat(), height.toFloat(), Path.Direction.CW)
            addRoundRect(scanRect, radius, radius, Path.Direction.CW)
        }
        canvas.drawPath(path, dimPaint)
        canvas.drawRoundRect(scanRect, radius, radius, borderPaint)
    }

    private fun dp(value: Int): Int =
        (value * resources.displayMetrics.density).toInt()
}
