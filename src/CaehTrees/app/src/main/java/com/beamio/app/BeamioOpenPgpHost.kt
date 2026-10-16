package com.beamio.app

import android.content.Context
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebView
import android.webkit.WebViewClient
import org.json.JSONObject
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Ephemeral WebView host that loads bundled `ChatCrypto/openpgp.min.js` +
 * `ethers.umd.min.js` for decrypt + EIP-191 verify without a live PWA.
 */
class BeamioOpenPgpHost private constructor(private val appContext: Context) {
    companion object {
        private const val TAG = "BeamioOpenPgp"
        @Volatile private var instance: BeamioOpenPgpHost? = null

        fun shared(context: Context): BeamioOpenPgpHost {
            return instance ?: synchronized(this) {
                instance ?: BeamioOpenPgpHost(context.applicationContext).also { instance = it }
            }
        }
    }

    private val main = Handler(Looper.getMainLooper())
    private var webView: WebView? = null
    private val ready = AtomicBoolean(false)
    private val bootstrapped = AtomicBoolean(false)
    private val pendingReady = ConcurrentLinkedQueue<(Boolean) -> Unit>()

    fun decryptAndVerifyOffer(
        privateKeyArmor: String,
        offerArmor: String,
        callback: (Result<JSONObject>) -> Unit,
    ) {
        ensureReady { ok ->
            if (!ok) {
                callback(Result.failure(IllegalStateException("openpgp host not ready")))
                return@ensureReady
            }
            val wv = webView
            if (wv == null) {
                callback(Result.failure(IllegalStateException("webview missing")))
                return@ensureReady
            }
            val js = """
            (async function(){
              try {
                const message = await openpgp.readMessage({ armoredMessage: ${jsString(offerArmor)} });
                const privateKey = await openpgp.readPrivateKey({ armoredKey: ${jsString(privateKeyArmor)} });
                const { data } = await openpgp.decrypt({ message, decryptionKeys: privateKey });
                const text = typeof data === 'string' ? data : new TextDecoder().decode(data);
                let payload = null;
                try { payload = JSON.parse(text); } catch (_) {
                  try {
                    const b64 = atob(text.replace(/\s+/g,''));
                    payload = JSON.parse(b64);
                  } catch (e2) {
                    return JSON.stringify({ ok:false, error:'parse_fail' });
                  }
                }
                if (!payload || typeof payload !== 'object') {
                  return JSON.stringify({ ok:false, error:'empty_payload' });
                }
                const type = String(payload.type || '');
                if (type !== 'voice_call_offer_v1') {
                  return JSON.stringify({ ok:false, error:'not_offer' });
                }
                const from = String(payload.from || '').toLowerCase();
                const callerSignature = String(payload.callerSignature || '');
                const callId = String(payload.callId || '');
                const sessionId = String(payload.sessionId || '');
                const to = String(payload.to || '').toLowerCase();
                const createdAt = String(payload.createdAt || '');
                const expiresAt = String(payload.expiresAt || '');
                const timestamp = String(payload.timestamp || '');
                const sessionKey = String(payload.sessionKey || '');
                const tempWalletAddress = String(payload.tempWalletAddress || '').toLowerCase();
                const entryDomains = Array.isArray(payload.entryDomains)
                  ? payload.entryDomains.map(String).join(',')
                  : String(payload.entryDomains || '');
                const codec = String(payload.codec || '');
                const lines = [
                  'CoNET voice_call_offer_v1',
                  'callId:' + callId,
                  'sessionId:' + sessionId,
                  'to:' + to,
                  'createdAt:' + createdAt,
                  'expiresAt:' + expiresAt,
                  'timestamp:' + timestamp,
                  'sessionKey:' + sessionKey,
                  'tempWalletAddress:' + tempWalletAddress,
                  'entryDomains:' + entryDomains,
                  'codec:' + codec,
                ].join('\\n');
                let recovered = '';
                try {
                  recovered = String(ethers.verifyMessage(lines, callerSignature) || '').toLowerCase();
                } catch (e) {
                  return JSON.stringify({ ok:false, error:'verify_fail', detail:String(e) });
                }
                if (!recovered || !from || recovered !== from) {
                  return JSON.stringify({
                    ok:false,
                    error:'caller_mismatch',
                    recovered: recovered,
                    claimed: from,
                  });
                }
                return JSON.stringify({
                  ok:true,
                  callerEoa: recovered,
                  callId: callId,
                  sessionId: sessionId,
                  claimedTag: String(payload.beamioTag || payload.tag || ''),
                });
              } catch (e) {
                return JSON.stringify({ ok:false, error:String(e) });
              }
            })()
            """.trimIndent()
            main.post {
                wv.evaluateJavascript(js) { raw ->
                    try {
                        val unquoted = unwrapJsString(raw)
                        val obj = JSONObject(unquoted.ifBlank { "{}" })
                        if (obj.optBoolean("ok", false)) {
                            callback(Result.success(obj))
                        } else {
                            callback(
                                Result.failure(
                                    IllegalStateException(obj.optString("error", "decrypt_fail")),
                                ),
                            )
                        }
                    } catch (error: Exception) {
                        callback(Result.failure(error))
                    }
                }
            }
        }
    }

    fun encryptToRoute(
        routePublicArmor: String,
        plaintextJson: String,
        callback: (Result<String>) -> Unit,
    ) {
        ensureReady { ok ->
            if (!ok) {
                callback(Result.failure(IllegalStateException("openpgp host not ready")))
                return@ensureReady
            }
            val wv = webView
            if (wv == null) {
                callback(Result.failure(IllegalStateException("webview missing")))
                return@ensureReady
            }
            val js = """
            (async function(){
              try {
                const publicKey = await openpgp.readKey({ armoredKey: ${jsString(routePublicArmor)} });
                const message = await openpgp.createMessage({ text: ${jsString(plaintextJson)} });
                const encrypted = await openpgp.encrypt({ message, encryptionKeys: publicKey });
                return typeof encrypted === 'string' ? encrypted : String(encrypted);
              } catch (e) {
                return 'ERROR:' + String(e);
              }
            })()
            """.trimIndent()
            main.post {
                wv.evaluateJavascript(js) { raw ->
                    val armor = unwrapJsString(raw)
                    if (armor.startsWith("ERROR:") || !armor.contains("BEGIN PGP MESSAGE")) {
                        callback(Result.failure(IllegalStateException(armor.ifBlank { "encrypt_fail" })))
                    } else {
                        callback(Result.success(armor))
                    }
                }
            }
        }
    }

    private fun ensureReady(callback: (Boolean) -> Unit) {
        if (ready.get()) {
            callback(true)
            return
        }
        pendingReady.add(callback)
        bootstrapIfNeeded()
    }

    private fun bootstrapIfNeeded() {
        if (!bootstrapped.compareAndSet(false, true)) return
        main.post {
            try {
                val wv = WebView(appContext).apply {
                    settings.javaScriptEnabled = true
                    addJavascriptInterface(Bridge(), "BeamioOpenPgpAndroid")
                    webViewClient = object : WebViewClient() {}
                }
                webView = wv
                val openpgp = loadAsset("ChatCrypto/openpgp.min.js")
                    ?: loadAsset("openpgp.min.js")
                val ethers = loadAsset("ChatCrypto/ethers.umd.min.js")
                    ?: loadAsset("ethers.umd.min.js")
                if (openpgp.isNullOrBlank() || ethers.isNullOrBlank()) {
                    Log.e(TAG, "missing bundled openpgp/ethers scripts")
                    flushReady(false)
                    return@post
                }
                val html = """
                <!DOCTYPE html><html><head><meta charset="utf-8"/></head><body>
                <script>$ethers</script>
                <script>$openpgp</script>
                <script>
                (function(){
                  try {
                    if (typeof openpgp === 'undefined' || typeof ethers === 'undefined') {
                      BeamioOpenPgpAndroid.onReady(false);
                      return;
                    }
                    BeamioOpenPgpAndroid.onReady(true);
                  } catch (e) {
                    BeamioOpenPgpAndroid.onReady(false);
                  }
                })();
                </script>
                </body></html>
                """.trimIndent()
                wv.loadDataWithBaseURL(
                    "https://appassets.androidplatform.net/",
                    html,
                    "text/html",
                    "utf-8",
                    null,
                )
            } catch (error: Exception) {
                Log.e(TAG, "bootstrap failed: ${error.message}")
                flushReady(false)
            }
        }
    }

    private fun loadAsset(path: String): String? = try {
        appContext.assets.open(path).bufferedReader().use { it.readText() }
    } catch (_: Exception) {
        null
    }

    private fun flushReady(ok: Boolean) {
        ready.set(ok)
        while (true) {
            val cb = pendingReady.poll() ?: break
            try {
                cb(ok)
            } catch (_: Exception) {
            }
        }
    }

    private inner class Bridge {
        @JavascriptInterface
        fun onReady(ok: Boolean) {
            Log.i(TAG, "host ready=$ok")
            main.post { flushReady(ok) }
        }
    }

    private fun jsString(raw: String): String {
        val escaped = raw
            .replace("\\", "\\\\")
            .replace("'", "\\'")
            .replace("\n", "\\n")
            .replace("\r", "\\r")
        return "'$escaped'"
    }

    private fun unwrapJsString(raw: String?): String {
        if (raw.isNullOrBlank() || raw == "null") return ""
        var s = raw.trim()
        if (s.startsWith("\"") && s.endsWith("\"") && s.length >= 2) {
            s = s.substring(1, s.length - 1)
                .replace("\\\"", "\"")
                .replace("\\n", "\n")
                .replace("\\r", "\r")
                .replace("\\\\", "\\")
        }
        return s
    }
}
