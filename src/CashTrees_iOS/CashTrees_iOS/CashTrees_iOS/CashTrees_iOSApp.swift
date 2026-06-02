//
//  CashTrees_iOSApp.swift
//  CashTrees_iOS
//
//  Created by peter on 2026-03-27.
//

import SwiftUI
import UIKit

final class CashTreesAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
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
