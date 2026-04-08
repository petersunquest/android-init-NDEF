package com.beamio.caehtrees

import android.Manifest
import android.annotation.SuppressLint
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.nfc.NfcAdapter
import android.nfc.Tag
import android.nfc.tech.Ndef
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.widget.FrameLayout
import android.webkit.PermissionRequest
import android.webkit.WebChromeClient
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import androidx.lifecycle.Lifecycle
import org.json.JSONObject

private const val HOME_URL = "https://verra.network/app/"

/**
 * Main document only: forces revalidation so WebView does not reuse a stale index.html from disk
 * (Android WebView often ignores response Cache-Control for the first load compared to Chrome).
 */
private val HOME_DOCUMENT_REQUEST_HEADERS = mapOf(
    "Cache-Control" to "no-cache",
    "Pragma" to "no-cache",
)

/**
 * SUN params from NDEF URL（与 android-NDEF MainActivity.readSunParamsFromNdef 一致）.
 * Template（e/c/m 全 0）返回 null。
 */
private data class SunParams(val uid: String, val e: String, val c: String, val m: String)

/** Return values for [CashTreesJsBridge.getNfcStatus] — consumed by PWA */
private object NfcStatusStrings {
    const val READY = "ready"
    const val NO_HARDWARE = "no_hardware"
    const val DISABLED = "disabled"
    /** Manifest 未声明 [android.Manifest.permission.NFC] 或安装包过旧时；需重装应用。 */
    const val PERMISSION_DENIED = "nfc_permission_denied"
}

class MainActivity : ComponentActivity() {

    private lateinit var webView: WebView

    /** WebView getUserMedia 与 [onPermissionRequest] 同时到达时需先跑完系统 CAMERA 授权 */
    private var pendingWebPermissionRequest: PermissionRequest? = null

    private var nfcAdapter: NfcAdapter? = null

    /** 前台优先接收 NFC，阻断系统 Tag Dispatcher（避免后台打开浏览器等）；未在 PWA 发起的读卡会话中时仅消费、不冒泡。 */
    private var nfcForegroundPendingIntent: PendingIntent? = null

    @Volatile
    private var nfcBindSessionActive: Boolean = false

    private val mainHandler = Handler(Looper.getMainLooper())

    private val enableNfcForegroundDispatchRunnable = Runnable { maybeEnableNfcForegroundDispatch() }

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

    private fun hasNfcPermission(): Boolean =
        ContextCompat.checkSelfPermission(this, Manifest.permission.NFC) ==
            PackageManager.PERMISSION_GRANTED

    private fun queryNfcStatus(): String {
        if (!hasNfcPermission()) return NfcStatusStrings.PERMISSION_DENIED
        val adapter = NfcAdapter.getDefaultAdapter(this) ?: return NfcStatusStrings.NO_HARDWARE
        return if (adapter.isEnabled) NfcStatusStrings.READY else NfcStatusStrings.DISABLED
    }

    /** @return `PendingIntent.FLAG_ALLOW_BACKGROUND_ACTIVITY_START` if present on device, else 0 */
    private fun pendingIntentAllowBackgroundActivityStartFlag(): Int {
        if (Build.VERSION.SDK_INT < 34) return 0
        return try {
            PendingIntent::class.java.getField("FLAG_ALLOW_BACKGROUND_ACTIVITY_START").getInt(null)
        } catch (_: Throwable) {
            0
        }
    }

    private fun createNfcForegroundPendingIntent(): PendingIntent {
        nfcForegroundPendingIntent?.let { return it }
        val launch = Intent(this, javaClass).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP)
        var flags = PendingIntent.FLAG_UPDATE_CURRENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            flags = flags or PendingIntent.FLAG_MUTABLE
        }
        // Android 14+ OEM：NFC 服务用本 PI 投递 NDEF 时可能出现 BAL_BLOCK（logcat「Background activity launch blocked」）。
        // 该 flag 在部分 SDK 的公开 android.jar 中不可见，故用反射读取运行时 framework 字段。
        flags = flags or pendingIntentAllowBackgroundActivityStartFlag()
        val pi = PendingIntent.getActivity(this, 0, launch, flags)
        nfcForegroundPendingIntent = pi
        return pi
    }

    /** 与 Reader Mode 互斥：同时注册会导致部分机型上标签仍被系统 Tag Dispatcher 处理。 */
    private fun disableNfcForegroundDispatchQuiet() {
        try {
            NfcAdapter.getDefaultAdapter(this)?.disableForegroundDispatch(this)
        } catch (_: Exception) {
        }
    }

    /**
     * App 在前台且非读卡会话时注册 Foreground Dispatch，优先于系统默认识别/浏览器打开 NDEF URI。
     * 纯 PWA 流程外的贴卡仅在 [onNewIntent] 内消费，不向下游冒泡。
     */
    private fun maybeEnableNfcForegroundDispatch() {
        if (!hasNfcPermission()) return
        if (nfcBindSessionActive) return
        if (!lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) return
        val adapter = nfcAdapter ?: NfcAdapter.getDefaultAdapter(this) ?: return
        if (!adapter.isEnabled) return
        try {
            adapter.enableForegroundDispatch(
                this,
                createNfcForegroundPendingIntent(),
                null,
                null,
            )
        } catch (_: Exception) {
        }
    }

    /**
     * Reader 结束后立刻重新注册前台分发（下一消息循环即执行），避免出现「Reader 已关、FD 尚未开」的空窗：
     * 该窗口内系统 Tag Dispatcher 会处理 NDEF https URI，常表现为**外部浏览器**打开 beamio.app。
     * 再在稍晚补一次 enable，减轻部分机型 HAL 释放 RF 与 enableForegroundDispatch 的竞态。
     */
    private fun reclaimNfcForegroundDispatchAfterReader() {
        mainHandler.removeCallbacks(enableNfcForegroundDispatchRunnable)
        mainHandler.post {
            maybeEnableNfcForegroundDispatch()
            mainHandler.postDelayed(enableNfcForegroundDispatchRunnable, 450L)
        }
    }

    /** Called from JS on UI thread */
    private fun armNfcPhysicalCardRead() {
        val adapter = NfcAdapter.getDefaultAdapter(this)
        if (adapter == null) {
            dispatchNfcJsonToWeb(JSONObject().put("ok", false).put("error", "no_hardware"))
            return
        }
        if (!adapter.isEnabled) {
            dispatchNfcJsonToWeb(JSONObject().put("ok", false).put("error", "nfc_disabled"))
            return
        }
        if (!hasNfcPermission()) {
            dispatchNfcJsonToWeb(
                JSONObject().put("ok", false).put("error", "nfc_permission_denied"),
            )
            return
        }
        nfcBindSessionActive = true
        disableNfcForegroundDispatchQuiet()
        // 不得使用 FLAG_READER_SKIP_NDEF_CHECK：该标志会使标签像无 NDEF 一样交付，
        // Ndef.get(tag) 读不到 SUN（e,c,m），仅余硬件 UID；getUIDAssets 对 NTAG 类 UID 需 SUN，会与 android-NDEF 前台分发行为不一致。
        var readerFlags =
            NfcAdapter.FLAG_READER_NFC_A or
                NfcAdapter.FLAG_READER_NFC_B or
                NfcAdapter.FLAG_READER_NFC_F or
                NfcAdapter.FLAG_READER_NFC_V
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            readerFlags = readerFlags or NfcAdapter.FLAG_READER_NO_PLATFORM_SOUNDS
        }
        adapter.enableReaderMode(
            this,
            { tag -> onNfcTagForBind(tag) },
            readerFlags,
            null,
        )
    }

    private fun onNfcTagForBind(tag: Tag) {
        if (!nfcBindSessionActive) return
        // 在 Reader 回调线程立刻读 NDEF；若推迟到主线程，部分机型上标签已 deactivate，SUN 丢失并触发 logcat「tag already deactivated」。
        val tagUidHex = tag.id?.joinToString("") { b -> "%02X".format(b) }.orEmpty()
        val (ndefUri, sun) =
            if (tagUidHex.isNotEmpty()) {
                readNdefUriAndSun(tag)
            } else {
                null to null
            }
        nfcBindSessionActive = false
        runOnUiThread {
            nfcAdapter?.disableReaderMode(this@MainActivity)
            try {
                if (tagUidHex.isEmpty()) {
                    dispatchNfcJsonToWeb(JSONObject().put("ok", false).put("error", "empty_tag_uid"))
                    return@runOnUiThread
                }
                val queryUid = sun?.uid ?: tagUidHex
                val json = JSONObject()
                    .put("ok", true)
                    .put("tagUidHex", tagUidHex)
                    .put("queryUid", queryUid)
                if (ndefUri != null) {
                    json.put("ndefUri", ndefUri)
                }
                if (sun != null) {
                    json.put(
                        "sun",
                        JSONObject()
                            .put("uid", sun.uid)
                            .put("e", sun.e)
                            .put("c", sun.c)
                            .put("m", sun.m),
                    )
                }
                dispatchNfcJsonToWeb(json)
            } finally {
                reclaimNfcForegroundDispatchAfterReader()
            }
        }
    }

    /** 从 NDEF URI 记录解析 SUN；模板（e/c/m 全 0）返回 null。 */
    private fun parseSunParamsFromNdefUrl(url: String): SunParams? {
        val uri = Uri.parse(url)
        val uid = uri.getQueryParameter("uid")?.trim() ?: return null
        val e = uri.getQueryParameter("e")?.trim() ?: return null
        val c = uri.getQueryParameter("c")?.trim() ?: return null
        val m = uri.getQueryParameter("m")?.trim() ?: return null
        if (e.length != 64 || c.length != 6 || m.length != 16) return null
        if (!e.matches(Regex("^[0-9a-fA-F]+$")) ||
            !c.matches(Regex("^[0-9a-fA-F]+$")) ||
            !m.matches(Regex("^[0-9a-fA-F]+$"))
        ) {
            return null
        }
        if (e.all { it == '0' } && c.all { it == '0' } && m.all { it == '0' }) {
            return null
        }
        return SunParams(uid, e, c, m)
    }

    /** 单次连接读取 URI 与 SUN，避免双次 Ndef.connect 在部分机型上的问题。 */
    private fun readNdefUriAndSun(tag: Tag): Pair<String?, SunParams?> {
        val ndef = Ndef.get(tag) ?: return null to null
        return try {
            ndef.connect()
            val msg = ndef.cachedNdefMessage ?: ndef.ndefMessage
            val url = msg?.records?.firstNotNullOfOrNull { it.toUri()?.toString() } ?: return null to null
            url to parseSunParamsFromNdefUrl(url)
        } catch (_: Exception) {
            null to null
        } finally {
            try {
                ndef.close()
            } catch (_: Exception) {
            }
        }
    }

    private fun disarmNfcReader(notifyWeb: Boolean, error: String?) {
        nfcBindSessionActive = false
        runOnUiThread {
            try {
                NfcAdapter.getDefaultAdapter(this@MainActivity)?.disableReaderMode(this@MainActivity)
                if (notifyWeb && error != null) {
                    dispatchNfcJsonToWeb(JSONObject().put("ok", false).put("error", error))
                }
            } finally {
                reclaimNfcForegroundDispatchAfterReader()
            }
        }
    }

    private fun dispatchNfcJsonToWeb(json: JSONObject) {
        if (!::webView.isInitialized) return
        val payload = json.toString()
        val js =
            "(function(){try{var d=" + payload + ";" +
                "window.dispatchEvent(new CustomEvent('cashtreesnfc',{detail:d}));" +
                "}catch(e){}})();"
        webView.evaluateJavascript(js, null)
    }

    private inner class CashTreesJsBridge {
        @JavascriptInterface
        fun getNfcStatus(): String = queryNfcStatus()

        @JavascriptInterface
        fun startPhysicalCardBind() {
            runOnUiThread { armNfcPhysicalCardRead() }
        }

        @JavascriptInterface
        fun cancelPhysicalCardBind() {
            disarmNfcReader(true, "cancelled")
        }
    }

    @SuppressLint("SetJavaScriptEnabled")
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        requestedOrientation = android.content.pm.ActivityInfo.SCREEN_ORIENTATION_PORTRAIT
        enableEdgeToEdge()
        nfcAdapter = NfcAdapter.getDefaultAdapter(this)

        onBackPressedDispatcher.addCallback(
            this,
            object : OnBackPressedCallback(true) {
                override fun handleOnBackPressed() {
                    if (nfcBindSessionActive) {
                        disarmNfcReader(true, "cancelled")
                        return
                    }
                    if (::webView.isInitialized && webView.canGoBack()) {
                        webView.goBack()
                    } else {
                        finish()
                    }
                }
            },
        )

        val jsBridge = CashTreesJsBridge()
        val wv = createMainWebView(jsBridge)
        webView = wv
        val root = FrameLayout(this)
        root.addView(wv)
        setContentView(root)
        hideBottomSystemBar()
    }

    /**
     * 主框架导航：拦截会被 NDEF 写入的 beamio SUN URL，防止 WebView 或外链拾取后跳出到系统浏览器。
     * [cashtrees.beamio.app] 为 PWA 宿主，必须放行。
     */
    private fun shouldBlockBeamioNdefTopLevelNavigation(u: Uri, isMainFrame: Boolean): Boolean {
        if (!isMainFrame) return false
        val host = u.host?.lowercase().orEmpty()
        if (!host.contains("beamio.app")) return false
        if (host.contains("cashtrees.beamio.app")) return false
        val path = u.path?.lowercase().orEmpty()
        if (path.contains("/api/sun") || path.contains("/sun")) return true
        val hasSunQueries =
            u.getQueryParameter("uid") != null &&
                u.getQueryParameter("e") != null &&
                u.getQueryParameter("c") != null &&
                u.getQueryParameter("m") != null
        return hasSunQueries
    }

    @SuppressLint("SetJavaScriptEnabled")
    private fun createMainWebView(jsBridge: CashTreesJsBridge): WebView {
        return WebView(this).apply {
            layoutParams = FrameLayout.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT,
            )
            webViewClient = object : WebViewClient() {
                /** 避免标签 NDEF URI（SUN）进入 WebView / 系统浏览器；余额仅走 cashtreesnfc + API。 */
                override fun shouldOverrideUrlLoading(view: WebView, request: WebResourceRequest): Boolean {
                    val u = request.url ?: return false
                    return shouldBlockBeamioNdefTopLevelNavigation(u, request.isForMainFrame)
                }

                @Deprecated("Deprecated in Java")
                override fun shouldOverrideUrlLoading(view: WebView?, url: String?): Boolean {
                    if (url.isNullOrEmpty()) return false
                    return shouldBlockBeamioNdefTopLevelNavigation(Uri.parse(url), true)
                }
            }
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
            addJavascriptInterface(jsBridge, "CashTreesAndroid")
            loadUrl(HOME_URL, HOME_DOCUMENT_REQUEST_HEADERS)
        }
    }

    override fun onResume() {
        super.onResume()
        maybeEnableNfcForegroundDispatch()
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val action = intent.action ?: return
        if (
            action != NfcAdapter.ACTION_TAG_DISCOVERED &&
            action != NfcAdapter.ACTION_TECH_DISCOVERED &&
            action != NfcAdapter.ACTION_NDEF_DISCOVERED
        ) {
            return
        }
        // Reader Mode 已开启时由回调处理；此处仅在前台拦截系统默认分发。
        if (nfcBindSessionActive) return
        // 未由 PWA 调用 startPhysicalCardBind：消费 Intent，不向系统/other app 冒泡。
    }

    override fun onPause() {
        try {
            NfcAdapter.getDefaultAdapter(this)?.disableForegroundDispatch(this)
        } catch (_: Exception) {
        }
        if (nfcBindSessionActive) {
            disarmNfcReader(true, "paused")
        }
        super.onPause()
    }

    override fun onDestroy() {
        mainHandler.removeCallbacks(enableNfcForegroundDispatchRunnable)
        super.onDestroy()
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
