package com.beamio.app

import android.os.SystemClock
import android.util.Log
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebView
import androidx.webkit.WebViewCompat
import androidx.webkit.WebViewFeature

/**
 * Forwards PWA `console.*` / bridge `debugLog` to logcat.
 * Mirrors iOS [CashTreesWebConsoleRelay.swift].
 */
object CashTreesWebConsoleRelay {
    const val BRIDGE_NAME = "CashTreesWebConsole"
    private const val LOG_TAG = "PWA-JS"
    private const val INJECTION_FLAG = "__CT_CONSOLE_PROXY_V4__"
    private val tagConsoleRelayRegistered = "ct_console_relay_registered".hashCode()

    /** Dedup: JS proxy relays then calls original console → [onConsoleMessage] too. */
    @Volatile
    private var lastBridgeLogText: String? = null

    @Volatile
    private var lastBridgeLogAtMs: Long = 0L

    fun logNative(message: String) {
        Log.i(LOG_TAG, "[native] $message")
    }

    fun logAppBoot() {
        logNative("CashTrees Android app boot — filter logcat tag=$LOG_TAG")
    }

    fun injectionScript(): String = """
        (function(){
          if(window.$INJECTION_FLAG)return;
          window.$INJECTION_FLAG=true;
          var BRIDGE='CashTreesAndroid';
          var CONSOLE_H='$BRIDGE_NAME';
          var LEVELS=['log','warn','error','info','debug'];
          var pendingQueue=[];
          function stringify(v){
            if(v===undefined)return 'undefined';
            if(v===null)return 'null';
            if(typeof v==='string')return v;
            if(typeof v==='number'||typeof v==='boolean')return String(v);
            try{return JSON.stringify(v);}catch(e){
              try{return String(v);}catch(_){return '[object]';}
            }
          }
          function hasBridge(){
            return !!(window[BRIDGE]&&typeof window[BRIDGE].debugLog==='function');
          }
          function hasConsoleBridge(){
            return !!(window[CONSOLE_H]&&typeof window[CONSOLE_H].relay==='function');
          }
          function sendNative(level,message){
            try{
              if(hasConsoleBridge()){
                window[CONSOLE_H].relay(level,message);
                return true;
              }
              if(hasBridge()){
                window[BRIDGE].debugLog(level,message);
                return true;
              }
            }catch(e){}
            return false;
          }
          function relay(level,args){
            var text=Array.prototype.slice.call(args).map(stringify).join(' ');
            if(!sendNative(level,text)){
              pendingQueue.push({level:level,message:text});
            }
          }
          function flushPending(){
            if(!hasConsoleBridge()&&!hasBridge())return false;
            while(pendingQueue.length){
              var item=pendingQueue.shift();
              sendNative(item.level,item.message);
            }
            if(!window.__CT_CONSOLE_RELAY_READY_SENT__){
              window.__CT_CONSOLE_RELAY_READY_SENT__=true;
              sendNative('info','__console_relay_ready__');
            }
            return true;
          }
          var targetConsole=window.console;
          window.console=new Proxy(targetConsole,{
            get:function(obj,prop){
              var value=Reflect.get(obj,prop);
              if(typeof prop==='string'&&LEVELS.indexOf(prop)>=0&&typeof value==='function'){
                return function(){
                  relay(prop,arguments);
                  return value.apply(obj,arguments);
                };
              }
              return typeof value==='function'?value.bind(obj):value;
            }
          });
          if(!flushPending()){
            var attempts=0;
            (function tick(){
              if(flushPending()||++attempts>=500)return;
              setTimeout(tick,10);
            })();
          }
          if(!window.__CT_CONSOLE_ERROR_HOOKED__){
            window.__CT_CONSOLE_ERROR_HOOKED__=true;
            window.addEventListener('error',function(ev){
              try{
                var msg=(ev&&ev.message)||'script error';
                if(ev&&ev.filename){
                  msg += ' @ ' + ev.filename + ':' + (ev.lineno||0);
                }
                relay('error',[msg]);
              }catch(e){}
            });
            window.addEventListener('unhandledrejection',function(ev){
              var reason=ev.reason;
              relay('error',['Unhandled rejection: '+stringify(reason)]);
            });
          }
        })();
    """.trimIndent()

    fun probeScript(): String = "console.log('[PWA] __pwa_console_probe__');"

    /**
     * iOS parity: inject at document start (all frames) before app bundle runs.
     * Falls back to [reinject] on page lifecycle when feature unsupported.
     */
    fun registerDocumentStartScript(webView: WebView) {
        if (webView.getTag(tagConsoleRelayRegistered) == true) return
        if (!WebViewFeature.isFeatureSupported(WebViewFeature.DOCUMENT_START_SCRIPT)) {
            logNative("DOCUMENT_START_SCRIPT unsupported — using onPageStarted reinject only")
            webView.setTag(tagConsoleRelayRegistered, true)
            return
        }
        WebViewCompat.addDocumentStartJavaScript(
            webView,
            injectionScript(),
            setOf("*"),
        )
        webView.setTag(tagConsoleRelayRegistered, true)
        logNative("document-start console relay registered (all origins)")
    }

    fun reinject(webView: WebView, reason: String) {
        webView.evaluateJavascript(injectionScript(), null)
        webView.evaluateJavascript(probeScript(), null)
        logNative("console relay reinjected ($reason)")
    }

    fun handleBridgeConsoleLog(level: String, message: String) {
        rememberBridgeLog(message)
        writeLog(level, message)
    }

    /** [WebChromeClient.onConsoleMessage] fallback (subframes / early boot). */
    fun handleWebViewConsoleMessage(
        line: String,
        level: ConsoleMessage.MessageLevel,
        source: String?,
        lineNumber: Int,
    ) {
        val trimmed = line.trim()
        if (trimmed.isEmpty()) return
        if (isDuplicateOfRecentBridgeLog(trimmed)) return

        val suffix = buildString {
            if (!source.isNullOrBlank()) {
                append(" @ ")
                append(source)
                if (lineNumber > 0) append(':').append(lineNumber)
            }
        }
        val levelName = when (level) {
            ConsoleMessage.MessageLevel.ERROR -> "error"
            ConsoleMessage.MessageLevel.WARNING -> "warn"
            ConsoleMessage.MessageLevel.DEBUG -> "debug"
            ConsoleMessage.MessageLevel.TIP -> "info"
            ConsoleMessage.MessageLevel.LOG -> "log"
            else -> "log"
        }
        writeLog(levelName, trimmed + suffix)
    }

    private fun rememberBridgeLog(message: String) {
        lastBridgeLogText = message
        lastBridgeLogAtMs = SystemClock.elapsedRealtime()
    }

    private fun isDuplicateOfRecentBridgeLog(message: String): Boolean {
        val prev = lastBridgeLogText ?: return false
        if (prev != message) return false
        return SystemClock.elapsedRealtime() - lastBridgeLogAtMs < 120L
    }

    private fun writeLog(level: String, message: String) {
        val text = message.ifEmpty { "(empty)" }
        when (level.lowercase()) {
            "error" -> Log.e(LOG_TAG, text)
            "warn", "warning" -> Log.w(LOG_TAG, text)
            "info" -> Log.i(LOG_TAG, text)
            "debug" -> Log.d(LOG_TAG, text)
            "log" -> Log.i(LOG_TAG, text)
            else -> Log.i(LOG_TAG, text)
        }
    }

    /** Secondary JS interface: `window.CashTreesWebConsole.relay(level, message)`. */
    class JsRelay {
        @JavascriptInterface
        fun relay(level: String, message: String) {
            handleBridgeConsoleLog(level, message)
        }
    }
}
