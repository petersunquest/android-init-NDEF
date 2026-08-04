package com.beamio.app

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.graphics.Canvas
import android.graphics.Color
import android.graphics.Paint
import android.graphics.Path
import android.graphics.RectF
import android.net.Uri
import android.os.Bundle
import android.view.Gravity
import android.view.View
import android.view.ViewGroup
import android.widget.Button
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
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

class GeneralQRScannerActivity : ComponentActivity() {

    companion object {
        const val EXTRA_FILTER = "extra_filter"
        const val FILTER_ANY = "any"
        const val FILTER_RECOVERY = "recovery"
        const val RESULT_TEXT = "result_text"
        const val RESULT_ERROR = "result_error"

        fun launchIntent(context: Context, filter: String): Intent =
            Intent(context, GeneralQRScannerActivity::class.java).putExtra(EXTRA_FILTER, filter)
    }

    private lateinit var barcodeView: DecoratedBarcodeView
    private var didFinish = false
    private var pickingFromLibrary = false
    private var lastDecodedText: String? = null

    private val requestCameraPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        if (granted) {
            startCameraScan()
        } else {
            finishCancelled("camera_permission_denied")
        }
    }

    private val pickImageLauncher = registerForActivityResult(
        ActivityResultContracts.GetContent(),
    ) { uri ->
        pickingFromLibrary = false
        if (uri == null) {
            resumeCameraScan()
            return@registerForActivityResult
        }
        val decoded = decodeQrFromUri(uri)
        val resolved = decoded?.let { resolvePayload(it) }
        if (resolved != null) {
            finishSuccess(resolved)
        } else {
            resumeCameraScan()
        }
    }

    private val openDocumentLauncher = registerForActivityResult(
        ActivityResultContracts.OpenDocument(),
    ) { uri ->
        pickingFromLibrary = false
        if (uri == null) {
            resumeCameraScan()
            return@registerForActivityResult
        }
        val decoded = decodeQrFromUri(uri)
        val resolved = decoded?.let { resolvePayload(it) }
        if (resolved != null) {
            finishSuccess(resolved)
        } else {
            resumeCameraScan()
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        enableEdgeToEdge()
        super.onCreate(savedInstanceState)

        val root = FrameLayout(this).apply {
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            setBackgroundColor(Color.BLACK)
        }

        barcodeView = DecoratedBarcodeView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            )
        }
        barcodeView.statusView?.visibility = View.GONE
        barcodeView.viewFinder?.visibility = View.GONE
        barcodeView.barcodeView.decoderFactory = DefaultDecoderFactory(listOf(BarcodeFormat.QR_CODE))
        root.addView(barcodeView)

        root.addView(buildOverlay())

        setContentView(root)

        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    finishCancelled("cancelled")
                }
            },
        )

        if (ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
            startCameraScan()
        } else {
            requestCameraPermission.launch(Manifest.permission.CAMERA)
        }
    }

    private fun buildOverlay(): View {
        val overlay = FrameLayout(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT,
            )
        }

        overlay.addView(DimmedScanOverlayView(this))

        val cancelButton = Button(this).apply {
            text = "Cancel"
            setTextColor(Color.WHITE)
            setBackgroundColor(0x73000000)
            setOnClickListener { finishCancelled("cancelled") }
        }
        val cancelLp = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.WRAP_CONTENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.START
            topMargin = dp(16)
            leftMargin = dp(16)
        }
        overlay.addView(cancelButton, cancelLp)

        val title = TextView(this).apply {
            text = "Scan QR Code"
            setTextColor(Color.WHITE)
            textSize = 20f
            gravity = Gravity.CENTER
        }
        val titleLp = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
        ).apply {
            gravity = Gravity.TOP or Gravity.CENTER_HORIZONTAL
            topMargin = dp(24)
        }
        overlay.addView(title, titleLp)

        val bottomPanel = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
        }
        val bottomLp = FrameLayout.LayoutParams(
            FrameLayout.LayoutParams.MATCH_PARENT,
            FrameLayout.LayoutParams.WRAP_CONTENT,
        ).apply {
            gravity = Gravity.BOTTOM
            bottomMargin = dp(24)
            leftMargin = dp(24)
            rightMargin = dp(24)
        }

        val hint = TextView(this).apply {
            text = "Align the code within the square"
            setTextColor(0xD1FFFFFF.toInt())
            textSize = 14f
            gravity = Gravity.CENTER
        }
        bottomPanel.addView(hint)

        val chooseButton = Button(this).apply {
            text = "Choose Photo or File"
            setTextColor(Color.WHITE)
            setBackgroundColor(0xEB1562F0.toInt())
            setOnClickListener { showChooseSourceDialog() }
        }
        val chooseLp = LinearLayout.LayoutParams(
            LinearLayout.LayoutParams.MATCH_PARENT,
            LinearLayout.LayoutParams.WRAP_CONTENT,
        ).apply {
            topMargin = dp(18)
        }
        bottomPanel.addView(chooseButton, chooseLp)
        overlay.addView(bottomPanel, bottomLp)

        ViewCompat.setOnApplyWindowInsetsListener(overlay) { _, insets ->
            val bars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            (cancelButton.layoutParams as FrameLayout.LayoutParams).apply {
                topMargin = bars.top + dp(16)
                leftMargin = bars.left + dp(16)
            }
            cancelButton.requestLayout()
            (title.layoutParams as FrameLayout.LayoutParams).apply {
                topMargin = bars.top + dp(24)
            }
            title.requestLayout()
            (bottomPanel.layoutParams as FrameLayout.LayoutParams).apply {
                bottomMargin = bars.bottom + dp(24)
                leftMargin = bars.left + dp(24)
                rightMargin = bars.right + dp(24)
            }
            bottomPanel.requestLayout()
            insets
        }
        ViewCompat.requestApplyInsets(overlay)

        return overlay
    }

    private fun showChooseSourceDialog() {
        pauseCameraScan()
        pickingFromLibrary = true
        androidx.appcompat.app.AlertDialog.Builder(this)
            .setTitle("Choose source")
            .setItems(arrayOf("Photo Library", "Browse Files")) { _, which ->
                when (which) {
                    0 -> pickImageLauncher.launch("image/*")
                    1 -> openDocumentLauncher.launch(arrayOf("image/*"))
                }
            }
            .setOnCancelListener {
                pickingFromLibrary = false
                resumeCameraScan()
            }
            .show()
    }

    private fun startCameraScan() {
        barcodeView.decodeContinuous(object : BarcodeCallback {
            override fun barcodeResult(result: BarcodeResult) {
                if (didFinish || pickingFromLibrary) return
                val raw = result.text ?: return
                if (raw == lastDecodedText) return
                val resolved = resolvePayload(raw) ?: return
                lastDecodedText = raw
                finishSuccess(resolved)
            }

            override fun possibleResultPoints(resultPoints: MutableList<com.google.zxing.ResultPoint>?) {}
        })
        barcodeView.resume()
    }

    private fun pauseCameraScan() {
        barcodeView.pause()
    }

    private fun resumeCameraScan() {
        if (didFinish) return
        lastDecodedText = null
        barcodeView.resume()
    }

    override fun onResume() {
        super.onResume()
        if (!didFinish && !pickingFromLibrary &&
            ContextCompat.checkSelfPermission(this, Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED
        ) {
            barcodeView.resume()
        }
    }

    override fun onPause() {
        barcodeView.pause()
        super.onPause()
    }

    private fun finishSuccess(text: String) {
        if (didFinish) return
        didFinish = true
        barcodeView.pause()
        setResult(RESULT_OK, Intent().putExtra(RESULT_TEXT, text))
        finish()
    }

    private fun finishCancelled(error: String) {
        if (didFinish) return
        didFinish = true
        barcodeView.pause()
        setResult(RESULT_CANCELED, Intent().putExtra(RESULT_ERROR, error))
        finish()
    }

    private fun resolvePayload(raw: String): String? {
        val trimmed = raw.trim()
        if (trimmed.isEmpty()) return null
        return trimmed
    }

    private fun decodeQrFromUri(uri: Uri): String? {
        return try {
            contentResolver.openInputStream(uri)?.use { input ->
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

    private class DimmedScanOverlayView(context: Context) : View(context) {
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
            val top = (height - side) / 2f - dp(context, 28)
            scanRect.set(
                left,
                maxOf(top, dp(context, 120).toFloat()),
                left + side,
                maxOf(top, dp(context, 120).toFloat()) + side,
            )

            val radius = dp(context, 14).toFloat()
            val path = Path().apply {
                fillType = Path.FillType.EVEN_ODD
                addRect(0f, 0f, width.toFloat(), height.toFloat(), Path.Direction.CW)
                addRoundRect(scanRect, radius, radius, Path.Direction.CW)
            }
            canvas.drawPath(path, dimPaint)
            canvas.drawRoundRect(scanRect, radius, radius, borderPaint)
        }

        private fun dp(context: Context, value: Int): Int =
            (value * context.resources.displayMetrics.density).toInt()
    }
}
