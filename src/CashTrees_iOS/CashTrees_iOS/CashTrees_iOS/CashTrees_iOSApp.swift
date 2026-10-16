//
//  CashTrees_iOSApp.swift
//  CashTrees_iOS
//
//  Created by peter on 2026-03-27.
//

import SwiftUI
import UIKit
import UserNotifications

final class CashTreesAppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // PushKit + CallKit must be ready before WebView — same as Android MessagingService
        // so a force-quit app still shows the system incoming-call UI and wakes Beamio.
        BeamioVoipIncomingBootstrap.shared.start()
        BeamioGuardianRoster.kick()
        UNUserNotificationCenter.current().delegate = self
        // Re-register if we already have a bound identity (cold start after prior grant).
		if CashTreesPushRegistration.boundEoa != nil {
			CashTreesPushRegistration.requestAuthorizationAndRegister()
		} else {
			// Still refresh the alert token so Dev install-over can rebind before PWA unlock.
			CashTreesPushRegistration.forceRegisterForRemoteNotifications()
		}
		// iOS 26+: LaunchOptionsKey.remoteNotification is deprecated. Cold-start /
		// background voiceCall payloads arrive via
		// application(_:didReceiveRemoteNotification:fetchCompletionHandler:) and
		// userNotificationCenter(_:didReceive:withCompletionHandler:) below.
		//
		// CoreDevice `--payload-url` / cold open often delivers custom schemes only via
		// LaunchOptionsKey.url — SwiftUI `.onOpenURL` alone misses that path.
		if let url = launchOptions?[.url] as? URL {
			NSLog("[BeamioDeepLink] launchOptions.url %@", url.absoluteString)
			_ = Self.handleDebugURL(url)
		}
		return true
	}

	/// Warm / background → foreground custom-scheme opens (incl. Safari / CoreDevice).
	func application(
		_ app: UIApplication,
		open url: URL,
		options: [UIApplication.OpenURLOptionsKey: Any] = [:]
	) -> Bool {
		NSLog("[BeamioDeepLink] application.open %@", url.absoluteString)
		return Self.handleDebugURL(url)
	}

	@discardableResult
	static func handleDebugURL(_ url: URL) -> Bool {
		if BeamioDeepLink.handleDebugIncomingIfPresent(url) { return true }
		if BeamioDeepLink.handleDebugDeclineIfPresent(url) { return true }
		if BeamioDeepLink.handleDebugAnswerIfPresent(url) { return true }
		if BeamioDeepLink.handleDebugEndAllIfPresent(url) { return true }
		return false
	}

    /// Foreground: suppress chat APNs banners/sound (SSE may already show the message),
    /// but still apply `.badge` so the home-screen icon updates if the user backgrounds/force-quits
    /// before the next offline notify (empty options previously dropped badge entirely).
    /// `type=voiceCall` alert fallback must wake CallKit even while the app is active.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        let userInfo = notification.request.content.userInfo
        if CashTreesPushRegistration.postIncomingVoiceCallIfPresent(from: userInfo) {
            if #available(iOS 14.0, *) {
                completionHandler([.banner, .sound, .badge, .list])
            } else {
                completionHandler([.alert, .sound, .badge])
            }
            return
        }
        if applicationIsActive {
            completionHandler([.badge])
            return
        }
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .badge, .list])
        } else {
            completionHandler([.alert, .sound, .badge])
        }
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        CashTreesPushRegistration.postIncomingVoiceCallIfPresent(
            from: response.notification.request.content.userInfo
        )
        completionHandler()
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        let handled = CashTreesPushRegistration.postIncomingVoiceCallIfPresent(from: userInfo)
        completionHandler(handled ? .newData : .noData)
    }

    private var applicationIsActive: Bool {
        if #available(iOS 13.0, *) {
            return UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .contains { $0.activationState == .foregroundActive }
        }
        return UIApplication.shared.applicationState == .active
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        UIDevice.current.userInterfaceIdiom == .pad ? .all : .portrait
    }

    func application(
        _ application: UIApplication,
        didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
    ) {
        CashTreesPushRegistration.handleDidRegister(deviceToken: deviceToken)
    }

    func application(
        _ application: UIApplication,
        didFailToRegisterForRemoteNotificationsWithError error: Error
    ) {
        CashTreesPushRegistration.handleDidFail(error: error)
    }
}

@main
struct CashTrees_iOSApp: App {
    @UIApplicationDelegateAdaptor(CashTreesAppDelegate.self) private var appDelegate
    @StateObject private var deepLinkStore = CashTreesDeepLinkStore()

    var body: some Scene {
        WindowGroup {
            ContentView(deepLinkStore: deepLinkStore)
                .onAppear {
                    CashTreesWebConsoleRelay.logAppBoot()
                    // After App Store install: restore merchant/coupon + referrer from pasteboard.
                    deepLinkStore.consumeDeferredDeepLinkFromPasteboardIfNeeded()
                }
                .onOpenURL { url in
                    Task { @MainActor in
                        if CashTreesAppDelegate.handleDebugURL(url) { return }
                        deepLinkStore.handleIncomingURL(url)
                    }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    guard let url = activity.webpageURL else { return }
                    Task { @MainActor in
                        deepLinkStore.handleIncomingURL(url)
                    }
                }
        }
    }
}
