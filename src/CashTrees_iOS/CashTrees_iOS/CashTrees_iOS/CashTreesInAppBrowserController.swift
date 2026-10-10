//
//  CashTreesInAppBrowserController.swift
//  CashTrees_iOS
//
//  Full-screen in-app WebView opened from the PWA bridge (bottom → top).
//  Floating chrome (circular Back + domain title capsule) matches Beamio Chat /
//  Home: safe-area top, shared scroll show/hide (opacity + translateY).
//

import UIKit
import WebKit

/// Presents a full-screen secondary WebView over the Consumer shell.
final class CashTreesInAppBrowserController: UIViewController, WKNavigationDelegate, UIScrollViewDelegate {
    private let initialURL: URL
    private let domainTitle: String

    private let webSurface = UIColor(red: 0 / 255, green: 4 / 255, blue: 20 / 255, alpha: 1)

    // Beamio scroll chrome (useScrollCapsuleOpacity / beamio-scrollable-top-controls-global).
    private let scrollThreshold: CGFloat = 40
    private let fadeRange: CGFloat = 100
    private let opacityEps: CGFloat = 0.02
    private let hideUnlockMs: TimeInterval = 0.3
    private let revealDebounceMs: TimeInterval = 0.5
    private let chromeAnimMs: TimeInterval = 0.3

    private var chromeTopConstraint: NSLayoutConstraint?
    private var chromeOpacity: CGFloat = 1
    private var lastScrollTop: CGFloat = 0
    private var latestScrollTop: CGFloat = 0
    private var hideUnlockWorkItem: DispatchWorkItem?
    private var revealWorkItem: DispatchWorkItem?
    private var revealPendingDistance: CGFloat = 0
    private var revealArmed = false
    private var revealReady = false

    private lazy var titleLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = domainTitle
        label.textAlignment = .center
        label.font = .systemFont(ofSize: 15, weight: .bold)
        label.textColor = UIColor(red: 15 / 255, green: 23 / 255, blue: 42 / 255, alpha: 1)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }()

    /// Center domain capsule — same floating chrome language as Chat identity pill.
    private lazy var titleCapsule: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        view.layer.cornerRadius = 22
        view.layer.borderWidth = 1
        view.layer.borderColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08)
        view.layer.shadowColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        view.layer.shadowOpacity = 0.08
        view.layer.shadowRadius = 12
        view.layer.shadowOffset = CGSize(width: 0, height: 4)
        view.isUserInteractionEnabled = false
        return view
    }()

    private lazy var backButton: UIButton = {
        let button = UIButton(type: .system)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.accessibilityLabel = "Back"
        button.accessibilityIdentifier = "inAppBrowserBack"
        let config = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        button.setImage(UIImage(systemName: "chevron.left", withConfiguration: config), for: .normal)
        button.tintColor = UIColor(red: 44 / 255, green: 47 / 255, blue: 49 / 255, alpha: 1)
        button.backgroundColor = UIColor.white.withAlphaComponent(0.92)
        button.layer.cornerRadius = 18
        button.layer.borderWidth = 1
        // Plain CGColor — avoid UIColor.cgColor (resolves against the deprecated shared screen).
        button.layer.borderColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.08)
        button.layer.shadowColor = CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        button.layer.shadowOpacity = 0.16
        button.layer.shadowRadius = 5
        button.layer.shadowOffset = CGSize(width: 0, height: 2)
        button.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        return button
    }()

    /// Floating chrome: Back + domain title share one opacity/transform layer.
    private lazy var floatingChrome: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        return view
    }()

    private lazy var webView: WKWebView = {
        let config = WKWebViewConfiguration()
        config.allowsInlineMediaPlayback = true
        // Lock pinch / browser zoom; keep viewport-fit so safe-area CSS still works.
        let viewportJS = """
        (function() {
          var m = document.querySelector('meta[name="viewport"]');
          var fit = 'viewport-fit=cover';
          var locked = 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, ' + fit;
          if (!m) {
            m = document.createElement('meta');
            m.name = 'viewport';
            (document.head || document.documentElement).appendChild(m);
            m.setAttribute('content', locked);
          } else {
            var c = m.getAttribute('content') || '';
            if (c.indexOf('user-scalable') === -1 || c.indexOf('maximum-scale') === -1) {
              m.setAttribute('content', locked);
            } else if (c.indexOf('viewport-fit') === -1) {
              m.setAttribute('content', c ? (c + ', ' + fit) : fit);
            }
          }
        })();
        """
        config.userContentController.addUserScript(
            WKUserScript(source: viewportJS, injectionTime: .atDocumentEnd, forMainFrameOnly: true)
        )
        let wv = WKWebView(frame: .zero, configuration: config)
        wv.translatesAutoresizingMaskIntoConstraints = false
        wv.navigationDelegate = self
        wv.allowsBackForwardNavigationGestures = true
        wv.isOpaque = true
        wv.backgroundColor = webSurface
        let sv = wv.scrollView
        sv.backgroundColor = webSurface
        sv.contentInsetAdjustmentBehavior = .never
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 1
        sv.zoomScale = 1
        sv.bouncesZoom = false
        sv.pinchGestureRecognizer?.isEnabled = false
        return wv
    }()

    init(url: URL) {
        self.initialURL = url
        self.domainTitle = Self.domainTitle(for: url)
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .overFullScreen
        modalTransitionStyle = .coverVertical
        isModalInPresentation = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        hideUnlockWorkItem?.cancel()
        revealWorkItem?.cancel()
        if webView.scrollView.delegate === self {
            webView.scrollView.delegate = nil
        }
    }

    /// Extract host for the top title (no caller-supplied title param).
    static func domainTitle(for url: URL) -> String {
        let host = (url.host ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if host.isEmpty { return url.absoluteString }
        if host.lowercased().hasPrefix("www.") {
            return String(host.dropFirst(4))
        }
        return host
    }

    /// Only http(s) may open in the in-app browser.
    static func sanitizedHTTPURL(from raw: String?) -> URL? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty, let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }
        guard scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = webSurface

        view.addSubview(webView)
        view.addSubview(floatingChrome)
        floatingChrome.addSubview(backButton)
        floatingChrome.addSubview(titleCapsule)
        titleCapsule.addSubview(titleLabel)

        let top = floatingChrome.topAnchor.constraint(equalTo: view.topAnchor, constant: chromeTopInset())
        chromeTopConstraint = top

        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            top,
            floatingChrome.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            floatingChrome.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            floatingChrome.heightAnchor.constraint(equalToConstant: 44),

            backButton.leadingAnchor.constraint(equalTo: floatingChrome.leadingAnchor, constant: 16),
            backButton.centerYAnchor.constraint(equalTo: floatingChrome.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 36),
            backButton.heightAnchor.constraint(equalToConstant: 36),

            titleCapsule.centerXAnchor.constraint(equalTo: floatingChrome.centerXAnchor),
            titleCapsule.centerYAnchor.constraint(equalTo: floatingChrome.centerYAnchor),
            titleCapsule.heightAnchor.constraint(equalToConstant: 44),
            titleCapsule.leadingAnchor.constraint(greaterThanOrEqualTo: backButton.trailingAnchor, constant: 12),
            titleCapsule.trailingAnchor.constraint(lessThanOrEqualTo: floatingChrome.trailingAnchor, constant: -16),

            titleLabel.leadingAnchor.constraint(equalTo: titleCapsule.leadingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: titleCapsule.trailingAnchor, constant: -16),
            titleLabel.topAnchor.constraint(equalTo: titleCapsule.topAnchor, constant: 10),
            titleLabel.bottomAnchor.constraint(equalTo: titleCapsule.bottomAnchor, constant: -10),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
        ])

        webView.scrollView.delegate = self
        applyChromeOpacity(1, animated: false)
        lockWebViewZoom()
        webView.load(URLRequest(url: initialURL))
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        chromeTopConstraint?.constant = chromeTopInset()
    }

    /// `max(1rem, env(safe-area-inset-top))` — Beamio fixed-top capsule protocol.
    private func chromeTopInset() -> CGFloat {
        max(16, view.safeAreaInsets.top)
    }

    @objc private func closeTapped() {
        dismiss(animated: true)
    }

    private func lockWebViewZoom() {
        let sv = webView.scrollView
        sv.minimumZoomScale = 1
        sv.maximumZoomScale = 1
        sv.zoomScale = 1
        sv.bouncesZoom = false
        sv.pinchGestureRecognizer?.isEnabled = false
    }

    // MARK: - Floating chrome opacity (shared by Back + domain title)

    private func computeOpacity(scrollTop: CGFloat) -> CGFloat {
        if scrollTop <= scrollThreshold { return 1 }
        return max(0, 1 - (scrollTop - scrollThreshold) / fadeRange)
    }

    private func applyChromeOpacity(_ next: CGFloat, animated: Bool) {
        let clamped = min(1, max(0, next))
        if abs(clamped - chromeOpacity) < opacityEps, clamped > 0, clamped < 1 { return }
        chromeOpacity = clamped
        let transform = CGAffineTransform(translationX: 0, y: -(1 - clamped) * floatingChrome.bounds.height.nonZeroOr(44))
        let apply = {
            self.floatingChrome.alpha = clamped
            self.floatingChrome.transform = transform
            self.floatingChrome.isUserInteractionEnabled = clamped >= 0.05
            self.backButton.isUserInteractionEnabled = clamped >= 0.05
        }
        if animated {
            UIView.animate(
                withDuration: chromeAnimMs,
                delay: 0,
                options: [.curveEaseOut, .allowUserInteraction, .beginFromCurrentState],
                animations: apply
            )
        } else {
            apply()
        }
    }

    private func commitOpacity(_ next: CGFloat) {
        applyChromeOpacity(next, animated: true)
    }

    private func scheduleOpacity(scrollTop: CGFloat) {
        let sv = webView.scrollView
        let contentH = sv.contentSize.height
        let boundsH = sv.bounds.height
        if contentH <= boundsH + 1 {
            lastScrollTop = scrollTop
            latestScrollTop = scrollTop
            commitOpacity(1)
            return
        }

        let previous = lastScrollTop
        let delta = scrollTop - previous
        lastScrollTop = scrollTop
        latestScrollTop = scrollTop

        if delta > 0 {
            revealArmed = false
            revealReady = false
            revealPendingDistance = 0
            revealWorkItem?.cancel()
            revealWorkItem = nil
            if hideUnlockWorkItem != nil { return }
            let next = computeOpacity(scrollTop: scrollTop)
            let unlock = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.hideUnlockWorkItem = nil
                if self.latestScrollTop > self.scrollThreshold, self.chromeOpacity > 0 {
                    self.commitOpacity(self.computeOpacity(scrollTop: self.latestScrollTop))
                }
            }
            hideUnlockWorkItem = unlock
            DispatchQueue.main.asyncAfter(deadline: .now() + hideUnlockMs, execute: unlock)
            commitOpacity(next)
            return
        }

        if delta < 0, chromeOpacity < 1 {
            revealPendingDistance += abs(delta)
            if revealReady {
                let pending = revealPendingDistance
                revealPendingDistance = 0
                commitOpacity(min(1, chromeOpacity + pending / fadeRange))
                return
            }
            if !revealArmed {
                revealArmed = true
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.revealWorkItem = nil
                    self.revealArmed = false
                    self.revealReady = true
                    let pending = self.revealPendingDistance
                    self.revealPendingDistance = 0
                    if pending <= 0 || self.chromeOpacity >= 1 { return }
                    self.commitOpacity(min(1, self.chromeOpacity + pending / self.fadeRange))
                }
                revealWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + revealDebounceMs, execute: work)
            }
            return
        }

        if delta == 0, scrollTop <= scrollThreshold {
            commitOpacity(1)
        }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard scrollView === webView.scrollView else { return }
        scheduleOpacity(scrollTop: scrollView.contentOffset.y)
    }

    // MARK: - WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lockWebViewZoom()
        if let host = webView.url.map({ Self.domainTitle(for: $0) }), !host.isEmpty {
            titleLabel.text = host
        }
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "http" || scheme == "https" || scheme == "about" || scheme == "blob" || scheme.isEmpty {
            decisionHandler(.allow)
            return
        }
        // mailto / tel / wallet schemes leave the in-app browser.
        UIApplication.shared.open(url, options: [:], completionHandler: nil)
        decisionHandler(.cancel)
    }
}

private extension CGFloat {
    func nonZeroOr(_ fallback: CGFloat) -> CGFloat {
        self > 0.5 ? self : fallback
    }
}
