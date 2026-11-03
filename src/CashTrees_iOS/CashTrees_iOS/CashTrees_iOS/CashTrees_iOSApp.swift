//
//  CashTrees_iOSApp.swift
//  CashTrees_iOS
//
//  Created by peter on 2026-03-27.
//

import ConetChatSDK
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
        #if DEBUG || BEAMIO_QA
        // QA builds: the SDK crypto host's recovery events (times and states only).
        BeamioOpenPgpHost.diagnostics = { BeamioQALog.write("pgp-host \($0)") }
        #endif
        BeamioVoipIncomingBootstrap.shared.start()
        // A dial that was still ringing when the app last died: cancel it now.
        BeamioNativeVoiceSignaling.recoverDialAfterRelaunch()
        BeamioGuardianRoster.kick()
        UNUserNotificationCenter.current().delegate = self
        // Re-register if we already have a bound identity (cold start after prior grant).
		if CashTreesPushRegistration.boundEoa != nil {
			CashTreesPushRegistration.requestAuthorizationAndRegister()
		} else {
			// Still refresh the alert token so Dev install-over can rebind before PWA unlock.
			CashTreesPushRegistration.forceRegisterForRemoteNotifications()
		}
		// iOS 26+: LaunchOptionsKey.url / OpenURLOptionsKey are deprecated.
		// Cold-start and warm custom-scheme opens use UIScene.ConnectionOptions
		// (configurationForConnecting / scene openURLContexts) plus SwiftUI
		// `.onOpenURL`. VoiceCall payloads still arrive via
		// didReceiveRemoteNotification / userNotificationCenter below.
		_ = launchOptions
		return true
	}

	func application(
		_ application: UIApplication,
		configurationForConnecting connectingSceneSession: UISceneSession,
		options: UIScene.ConnectionOptions
	) -> UISceneConfiguration {
		if let url = options.urlContexts.first?.url {
			BeamioDeepLink.accept("ACCEPT scene-url")
			NSLog("[BeamioDeepLink] scene.urlContexts %@", url.absoluteString)
			if !Self.handleDebugURL(url) {
				BeamioDeepLink.stashColdOpenURL(url)
			}
		} else if let activity = options.userActivities.first(where: {
			BeamioCallKitVideoButton.activityTypes.contains($0.activityType)
		}) {
			// CallKit Video button while the app had no scene (PushKit launch).
			BeamioDeepLink.accept("ACCEPT scene-callkit-video")
			BeamioCallKitVideoButton.handle(activity, source: "scene-connect")
		} else if let url = options.userActivities.compactMap(\.webpageURL).first {
			BeamioDeepLink.accept("ACCEPT scene-activity")
			BeamioDeepLink.stashColdOpenURL(url)
		} else {
			BeamioDeepLink.accept("ACCEPT scene-connect-empty")
		}
		return UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
	}

	@discardableResult
	static func handleDebugURL(_ url: URL) -> Bool {
		if BeamioDeepLink.handleDebugIncomingIfPresent(url) { return true }
		if BeamioDeepLink.handleDebugDeclineIfPresent(url) { return true }
		if BeamioDeepLink.handleDebugAnswerIfPresent(url) { return true }
		if BeamioDeepLink.handleDebugInCallIfPresent(url) { return true }
		if BeamioDeepLink.handleDebugEndAllIfPresent(url) { return true }
		if BeamioDeepLink.handleDebugRemoteEndIfPresent(url) { return true }
		if BeamioDeepLink.handleBusyChromeRescueIfPresent(url) { return true }
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
        // "@tag turned on video" during a call → Beamio call screen.
        if BeamioPeerVideoNotice.handleTap(userInfo: response.notification.request.content.userInfo) {
            completionHandler()
            return
        }
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
                    BeamioDeepLink.accept("ACCEPT on-open-url")
                    Task { @MainActor in
                        if CashTreesAppDelegate.handleDebugURL(url) { return }
                        deepLinkStore.handleIncomingURL(url)
                    }
                }
                // CallKit in-call Video button → video in the Beamio call screen.
                .onContinueUserActivity("INStartCallIntent") { activity in
                    BeamioCallKitVideoButton.handle(activity, source: "continue")
                }
                .onContinueUserActivity("INStartVideoCallIntent") { activity in
                    BeamioCallKitVideoButton.handle(activity, source: "continue")
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
