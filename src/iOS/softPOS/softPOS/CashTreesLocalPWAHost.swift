//
//  CashTreesLocalPWAHost.swift
//  softPOS
//
//  Bootstraps bundled POS PWA → Documents/active → custom scheme handler (no HTTP server).
//

import Combine
import Foundation

@MainActor
final class CashTreesLocalPWAHost: ObservableObject {
    static let shared = CashTreesLocalPWAHost()

    let schemeHandler = CashTreesLocalSchemeHandler()

    @Published private(set) var isReady = false
    @Published private(set) var lastError: String?

    var entryURL: URL { CashTreesPWAScheme.entryURL }

    var baseURL: URL {
        URL(string: "\(CashTreesPWAScheme.scheme)://\(CashTreesPWAScheme.host)/")!
    }

    private let bundleStore = CashTreesPWABundleStore.shared
    private var startTask: Task<Void, Never>?

    private init() {}

    func startIfNeeded() {
        guard startTask == nil else { return }
        startTask = Task { [weak self] in
            await self?.boot()
        }
    }

    func activeVersion() -> String {
        bundleStore.activeVersion()
    }

    func pendingUpdateVersion() -> String? {
        bundleStore.pendingUpdateVersion()
    }

    func refreshOnForeground() async {
        await CashTreesPWAUpdateDaemon.shared.checkNow()
        notifyPendingUpdateIfNeeded()
    }

    func applyPendingUpdate() async -> Bool {
        guard bundleStore.hasPendingUpdate() else {
            lastError = "No staged update"
            return false
        }
        await schemeHandler.waitForInFlightTasks()
        do {
            try bundleStore.promoteStagingToActive()
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            print("❌ CashTreesLocalPWAHost applyPendingUpdate: \(error.localizedDescription)")
            return false
        }
    }

    private func boot() async {
        do {
            try bundleStore.bootstrapIfNeeded()
            isReady = true
            lastError = nil
            CashTreesPWAUpdateDaemon.shared.start()
            notifyPendingUpdateIfNeeded()
        } catch {
            lastError = error.localizedDescription
            print("❌ CashTreesLocalPWAHost boot failed: \(error.localizedDescription)")
        }
    }

    private func notifyPendingUpdateIfNeeded() {
        guard let pending = bundleStore.pendingUpdateVersion() else { return }
        let current = bundleStore.activeVersion()
        NotificationCenter.default.post(
            name: .cashTreesEmbeddedPwaUpdateAvailable,
            object: nil,
            userInfo: [
                "currentVer": current,
                "pendingVer": pending,
            ]
        )
    }
}
