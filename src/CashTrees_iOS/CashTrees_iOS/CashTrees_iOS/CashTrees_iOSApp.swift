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
        UNUserNotificationCenter.current().delegate = self
        // Re-register if we already have a bound identity (cold start after prior grant).
        if CashTreesPushRegistration.boundEoa != nil {
            CashTreesPushRegistration.requestAuthorizationAndRegister()
        }
        return true
    }

    /// Foreground: suppress chat APNs banners/sound (SSE may already show the message),
    /// but still apply `.badge` so the home-screen icon updates if the user backgrounds/force-quits
    /// before the next offline notify (empty options previously dropped badge entirely).
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
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
        .portrait
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
