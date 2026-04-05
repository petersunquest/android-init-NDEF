//
//  iOS_NDEFApp.swift
//  iOS_NDEF
//
//  Created by peter on 2026-03-30.
//

import SwiftUI
import UIKit

/// Info.plist lists all iPad orientations (multitasking rule); runtime stays portrait-only.
final class iOS_NDEFAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        .portrait
    }
}

@main
struct iOS_NDEFApp: App {
    @UIApplicationDelegateAdaptor(iOS_NDEFAppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
