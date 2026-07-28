//
//  CashTreesNativeAppStateBridge.swift
//  CashTrees_iOS
//
//  PWA → Native generic app state (footer badges, app icon badge, …).
//

import Foundation
import UIKit
import UserNotifications

enum CashTreesNativeAppStateBridge {
    static func applyFromWebPayload(_ state: [String: Any]?) {
        let badge = resolveAppIconBadge(from: state)
        applyAppIconBadge(badge)
    }

    private static func resolveAppIconBadge(from state: [String: Any]?) -> Int {
        guard let state else { return 0 }
        if let explicit = parseNonNegativeInt(state["appIconBadge"]) {
            return explicit
        }
        if let footer = state["footerBadges"] as? [String: Any],
           let chat = parseNonNegativeInt(footer["chat"]) {
            return chat
        }
        return 0
    }

    private static func parseNonNegativeInt(_ value: Any?) -> Int? {
        switch value {
        case let v as Int:
            return max(0, min(v, 999))
        case let v as NSNumber:
            return max(0, min(v.intValue, 999))
        case let v as Double:
            return max(0, min(Int(v), 999))
        default:
            return nil
        }
    }

    static func applyAppIconBadge(_ count: Int) {
        let safe = max(0, min(count, 999))
        DispatchQueue.main.async {
            if #available(iOS 16.0, *) {
                setBadgeCountModern(safe)
            } else {
                UIApplication.shared.applicationIconBadgeNumber = safe
            }
        }
    }

    @available(iOS 16.0, *)
    private static func setBadgeCountModern(_ count: Int) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                center.requestAuthorization(options: [.badge]) { granted, _ in
                    guard granted else { return }
                    center.setBadgeCount(count) { _ in }
                }
            case .authorized, .provisional, .ephemeral:
                center.setBadgeCount(count) { _ in }
            case .denied:
                break
            @unknown default:
                break
            }
        }
    }
}
