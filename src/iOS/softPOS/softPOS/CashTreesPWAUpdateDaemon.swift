//
//  CashTreesPWAUpdateDaemon.swift
//  softPOS
//

import Foundation

/// Polls `https://pos.beamio.app/update.json`, downloads newer bundles into `staging/`.
@MainActor
final class CashTreesPWAUpdateDaemon {
    static let shared = CashTreesPWAUpdateDaemon(bundleStore: CashTreesPWABundleStore.shared)

    static let checkIntervalSeconds: TimeInterval = 15 * 60

    private let bundleStore: CashTreesPWABundleStore
    private let session: URLSession
    private var scheduleTask: Task<Void, Never>?
    private var checkInFlight = false

    private init(bundleStore: CashTreesPWABundleStore) {
        self.bundleStore = bundleStore
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    func start() {
        guard scheduleTask == nil else { return }
        scheduleTask = Task { [weak self] in
            await self?.runLoop()
        }
    }

    func stop() {
        scheduleTask?.cancel()
        scheduleTask = nil
    }

    func checkNow() async {
        await performCheck()
    }

    private func runLoop() async {
        await performCheck()
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: UInt64(Self.checkIntervalSeconds * 1_000_000_000))
            if Task.isCancelled { break }
            await performCheck()
        }
    }

    private func performCheck() async {
        guard !checkInFlight else { return }
        checkInFlight = true
        defer { checkInFlight = false }

        do {
            let remote = try await fetchRemoteUpdateInfo()
            let current = bundleStore.activeVersion()
            guard CashTreesPWABundleStore.isSemverNewer(oldVer: current, newVer: remote.ver) else {
                return
            }
            if let pending = bundleStore.pendingUpdateVersion(), pending == remote.ver {
                postUpdateAvailable(current: current, pending: remote.ver)
                return
            }
            try await downloadAndStage(remote: remote)
            postUpdateAvailable(current: current, pending: remote.ver)
        } catch {
            print("⚠️ CashTreesPWAUpdateDaemon: \(error.localizedDescription)")
        }
    }

    private func fetchRemoteUpdateInfo() async throws -> CashTreesPWAUpdateInfo {
        var request = URLRequest(url: CashTreesPWAScheme.remoteUpdateManifestURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(CashTreesPWAUpdateInfo.self, from: data)
    }

    private func downloadAndStage(remote: CashTreesPWAUpdateInfo) async throws {
        let downloadURL = CashTreesPWAScheme.remoteBundleBaseURL.appendingPathComponent(remote.filename)
        var request = URLRequest(url: downloadURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (tempZip, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        let fm = FileManager.default
        let stagedZip = fm.temporaryDirectory.appendingPathComponent("beamio_pos_staging_\(UUID().uuidString).zip")
        if fm.fileExists(atPath: stagedZip.path) {
            try fm.removeItem(at: stagedZip)
        }
        try fm.copyItem(at: tempZip, to: stagedZip)
        defer { try? fm.removeItem(at: stagedZip) }
        try bundleStore.installDownloadToStaging(from: stagedZip, expectedVersion: remote.ver)
    }

    private func postUpdateAvailable(current: String, pending: String) {
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
