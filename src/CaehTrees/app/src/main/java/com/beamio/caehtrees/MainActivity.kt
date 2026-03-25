package com.beamio.caehtrees

import android.Manifest
import android.annotation.SuppressLint
import android.content.pm.PackageManager
import android.os.Bundle
import android.view.ViewGroup
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.viewinterop.AndroidView
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import com.beamio.caehtrees.ui.theme.CaehTreesTheme

private const val HOME_URL = "https://cashtrees.beamio.app/app/"

/**
 * Main document only: forces revalidation so WebView does not reuse a stale index.html from disk
 * (Android WebView often ignores response Cache-Control for the first load compared to Chrome).
 */
private val HOME_DOCUMENT_REQUEST_HEADERS = mapOf(
    "Cache-Control" to "no-cache",
    "Pragma" to "no-cache",
)

class MainActivity : ComponentActivity() {

    private lateinit var webView: WebView

    /** WebView getUserMedia 与 [onPermissionRequest] 同时到达时需先跑完系统 CAMERA 授权 */
    private var pendingWebPermissionRequest: PermissionRequest? = null

    private val requestCameraPermission = registerForActivityResult(
        ActivityResultContracts.RequestPermission(),
    ) { granted ->
        val req = pendingWebPermissionRequest
        pendingWebPermissionRequest = null
        if (req == null) return@registerForActivityResult
        if (granted) {
            grantWebViewMediaRequest(req)
        } else {
            req.deny()
        }
    }

    private fun grantWebViewMediaRequest(request: PermissionRequest) {
        val allow = request.resources.filter { res ->
            res == PermissionRequest.RESOURCE_VIDEO_CAPTURE ||
                res == PermissionRequest.RESOURCE_AUDIO_CAPTURE
        }.toTypedArray()
        if (allow.isEmpty()) {
            request.deny()
        } else {
            request.grant(allow)
        }
    }

    private val webChromeClient: WebChromeClient = object : WebChromeClient() {
        override fun onPermissionRequest(request: PermissionRequest) {
            runOnUiThread {
                when {
                    ContextCompat.checkSelfPermission(
                        this@MainActivity,
                        Manifest.permission.CAMERA,
                    ) == PackageManager.PERMISSION_GRANTED -> {
                        grantWebViewMediaRequest(request)
                    }
                    else -> {
                        pendingWebPermissionRequest = request
                        requestCameraPermission.launch(Manifest.permission.CAMERA)
                    }
                }
            }
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        enableEdgeToEdge()

        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    if (::webView.isInitialized && webView.canGoBack()) {
                        webView.goBack()
                    } else {
                        finish()
                    }
                }
            },
        )

        setContent {
            CaehTreesTheme {
                CashTreesWebView(
                    modifier = Modifier.fillMaxSize(),
                    webChromeClient = webChromeClient,
                    onWebViewReady = { w -> webView = w },
                )
            }
        }
        hideBottomSystemBar()
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) hideBottomSystemBar()
    }

    /** Hide navigation bar; user can swipe edge to show it briefly (transient). */
    private fun hideBottomSystemBar() {
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.hide(WindowInsetsCompat.Type.navigationBars())
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
    }
}

@SuppressLint("SetJavaScriptEnabled")
@Composable
private fun CashTreesWebView(
    modifier: Modifier = Modifier,
    webChromeClient: WebChromeClient,
    onWebViewReady: (WebView) -> Unit,
) {
    AndroidView(
        factory = { context ->
            WebView(context).apply {
                layoutParams = ViewGroup.LayoutParams(
                    ViewGroup.LayoutParams.MATCH_PARENT,
                    ViewGroup.LayoutParams.MATCH_PARENT,
                )
                webViewClient = WebViewClient()
                this.webChromeClient = webChromeClient
                settings.javaScriptEnabled = true
                settings.domStorageEnabled = true
                settings.mediaPlaybackRequiresUserGesture = false
                settings.cacheMode = WebSettings.LOAD_DEFAULT
                settings.loadWithOverviewMode = true
                settings.useWideViewPort = true
                settings.setSupportZoom(false)
                settings.builtInZoomControls = false
                isVerticalScrollBarEnabled = true
                isHorizontalScrollBarEnabled = false
                onWebViewReady(this)
                loadUrl(HOME_URL, HOME_DOCUMENT_REQUEST_HEADERS)
            }
        },
        modifier = modifier,
    )
}
