//
//  CashTreesWebConsoleRelay.swift
//  CashTrees_iOS
//
//  Forwards PWA `console.*` output to Console.app via os.Logger (Unified Logging).
//

import Foundation
import os
import WebKit

enum CashTreesWebConsoleRelay {
    static let handlerName = "CashTreesWebConsole"
    static let bridgeHandlerName = "CashTreesIOS"
    /// Console.app: Process CashTrees_iOS, subsystem=com.beamio.beamio, category=PWA-JS.
    static let logSubsystem = "com.beamio.beamio"
    static let logCategory = "PWA-JS"
    static let logTag = "PWA-JS"

    private static let logger = Logger(subsystem: logSubsystem, category: logCategory)

    static func logNative(_ message: String) {
        logger.info("[native] \(message, privacy: .public)")
        debugNSLog("[native] \(message)")
    }

    static func logAppBoot() {
        logNative("CashTrees_iOS app boot — filter Console.app: subsystem=\(logSubsystem) category=\(logCategory)")
    }

    static func pageUserScript(
        source: String,
        injectionTime: WKUserScriptInjectionTime,
        forMainFrameOnly: Bool
    ) -> WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: injectionTime,
            forMainFrameOnly: forMainFrameOnly,
            in: .page
        )
    }

    static func injectionScript() -> String {
        """
        (function(){
          if(window.__CT_CONSOLE_PROXY_V4__)return;
          window.__CT_CONSOLE_PROXY_V4__=true;
          var CONSOLE_H='\(handlerName)';
          var BRIDGE_H='\(bridgeHandlerName)';
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
          function hasHandler(name){
            return !!(window.webkit&&window.webkit.messageHandlers&&window.webkit.messageHandlers[name]);
          }
          function sendNative(level,message){
            try{
              if(hasHandler(CONSOLE_H)){
                window.webkit.messageHandlers[CONSOLE_H].postMessage({level:level,message:message});
                return true;
              }
              if(hasHandler(BRIDGE_H)){
                window.webkit.messageHandlers[BRIDGE_H].postMessage({
                  action:'consoleLog',
                  level:level,
                  message:message
                });
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
            if(!hasHandler(CONSOLE_H)&&!hasHandler(BRIDGE_H))return false;
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
            var timer=setInterval(function(){
              if(flushPending()||++attempts>=500)clearInterval(timer);
            },10);
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
          }
        })();
        """
    }

    static func probeScript() -> String {
        "console.log('[PWA] __pwa_console_probe__');"
    }

    static func reinject(into webView: WKWebView, reason: String) {
        let install = injectionScript()
        webView.callAsyncJavaScript(install, arguments: [:], in: nil, in: .page) { result in
            if case .failure(let error) = result {
                logNative("reinject(\(reason)) install failed: \(error.localizedDescription)")
                return
            }
            logNative("reinject(\(reason)) install ok")
            webView.callAsyncJavaScript(probeScript(), arguments: [:], in: nil, in: .page) { probeResult in
                if case .failure(let error) = probeResult {
                    logNative("reinject(\(reason)) probe failed: \(error.localizedDescription)")
                }
            }
        }
    }

    static func handle(_ message: WKScriptMessage) {
        guard message.name == handlerName else { return }
        if let body = message.body as? [String: Any] {
            emit(level: body["level"], message: body["message"])
            return
        }
        if let text = message.body as? String {
            emit(level: "log", message: text)
            return
        }
        emit(level: "log", message: String(describing: message.body))
    }

    static func handleBridgeConsoleLog(_ body: [String: Any]) {
        emit(level: body["level"], message: body["message"])
    }

    private static func emit(level: Any?, message: Any?) {
        let levelText = (level as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let resolvedLevel = (levelText?.isEmpty == false) ? levelText! : "log"
        let text: String
        if let s = message as? String {
            text = s
        } else {
            text = String(describing: message ?? "")
        }
        logPwa(level: resolvedLevel, message: text)
    }

    private static func logPwa(level: String, message: String) {
        switch level {
        case "debug":
            logger.debug("\(message, privacy: .public)")
        case "info":
            logger.info("\(message, privacy: .public)")
        case "warn", "warning":
            logger.warning("\(message, privacy: .public)")
        case "error":
            logger.error("\(message, privacy: .public)")
        case "log":
            logger.info("\(message, privacy: .public)")
        default:
            logger.info("\(message, privacy: .public)")
        }
        debugNSLog("[\(level.uppercased())] \(message)")
    }

    #if DEBUG
    private static func debugNSLog(_ message: String) {
        NSLog("[\(logTag)] %@", message)
    }
    #else
    private static func debugNSLog(_ message: String) {}
    #endif
}

/// Dedicated handler object so WKUserContentController retains a stable target.
final class CashTreesWebConsoleMessageHandler: NSObject, WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        CashTreesWebConsoleRelay.handle(message)
    }
}
