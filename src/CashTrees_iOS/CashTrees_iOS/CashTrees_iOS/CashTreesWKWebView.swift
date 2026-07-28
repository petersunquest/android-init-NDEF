//
//  CashTreesWKWebView.swift
//  CashTrees_iOS
//
//  Removes the default WKWebView keyboard form accessory bar
//  (Previous / Next field arrows + Done/Check) above the soft keyboard.
//

import ObjectiveC.runtime
import WebKit

/// WKWebView used by the Consumer shell; strips WebKit's default input accessory toolbar.
final class CashTreesWKWebView: WKWebView {
    override var inputAccessoryView: UIView? { nil }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        stripInnerContentInputAccessoryView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        stripInnerContentInputAccessoryView()
    }

    /// WebKit's first responder is usually `WKContentView`, not the outer WKWebView.
    func stripInnerContentInputAccessoryView() {
        CashTreesWKWebViewInputAccessory.strip(from: self)
    }
}

private final class CashTreesNoInputAccessoryViewHelper: NSObject {
    @objc var inputAccessoryView: UIView? { nil }
}

private enum CashTreesWKWebViewInputAccessory {
    static func strip(from webView: WKWebView) {
        guard
            let contentView = webView.scrollView.subviews.first(where: {
                String(describing: type(of: $0)).hasPrefix("WKContent")
            }),
            let contentClass = object_getClass(contentView)
        else { return }

        let className = "\(contentClass)_CashTreesNoInputAccessoryView"
        var noAccessoryClass: AnyClass? = NSClassFromString(className)
        if noAccessoryClass == nil, let classNameC = className.cString(using: .ascii) {
            noAccessoryClass = objc_allocateClassPair(contentClass, classNameC, 0)
            if let noAccessoryClass {
                objc_registerClassPair(noAccessoryClass)
            }
        }
        guard
            let targetClass = noAccessoryClass,
            let templateMethod = class_getInstanceMethod(
                CashTreesNoInputAccessoryViewHelper.self,
                #selector(getter: CashTreesNoInputAccessoryViewHelper.inputAccessoryView)
            )
        else { return }

        class_addMethod(
            targetClass,
            #selector(getter: CashTreesNoInputAccessoryViewHelper.inputAccessoryView),
            method_getImplementation(templateMethod),
            method_getTypeEncoding(templateMethod)
        )
        object_setClass(contentView, targetClass)
    }
}
