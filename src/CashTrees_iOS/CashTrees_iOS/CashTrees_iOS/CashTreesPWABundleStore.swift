//
//  CashTreesPWABundleStore.swift
//  CashTrees_iOS
//

import Foundation
import ZIPFoundation

extension Notification.Name {
    static let cashTreesEmbeddedPwaUpdateAvailable = Notification.Name("cashTreesEmbeddedPwaUpdateAvailable")
}

/// Documents-backed PWA bundle: `active/` (live), `staging/` (downloaded), `backup/` (rollback).
final class CashTreesPWABundleStore {
    static let shared = CashTreesPWABundleStore()

    private let fileManager = FileManager.default
    private let lock = NSLock()

    let rootDir: URL
    let activeDir: URL
    let stagingDir: URL
    let backupDir: URL

    private(set) var pendingVersion: String?

    private init() {
        guard let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else {
            fatalError("Documents directory unavailable")
        }
        rootDir = documents.appendingPathComponent("silentpass_pwa", isDirectory: true)
        activeDir = rootDir.appendingPathComponent("active", isDirectory: true)
        stagingDir = rootDir.appendingPathComponent("staging", isDirectory: true)
        backupDir = rootDir.appendingPathComponent("backup", isDirectory: true)
        pendingVersion = Self.readPendingVersion(from: stagingDir)
    }

    func bootstrapIfNeeded() throws {
        lock.lock()
        defer { lock.unlock() }
        try fileManager.createDirectory(at: rootDir, withIntermediateDirectories: true)
        if hasValidBundle(at: activeDir) { return }
        if fileManager.fileExists(atPath: activeDir.path) {
            try? fileManager.removeItem(at: activeDir)
        }
        try fileManager.createDirectory(at: activeDir, withIntermediateDirectories: true)
        guard let zipPath = Bundle.main.url(forResource: "SilentPassUI", withExtension: "zip") else {
            throw NSError(
                domain: "CashTreesPWABundleStore",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "SilentPassUI.zip missing from app bundle"]
            )
        }
        try fileManager.unzipItem(at: zipPath, to: activeDir)
        removeMacOsMetadata(from: activeDir)
        guard hasValidBundle(at: activeDir) else {
            throw NSError(
                domain: "CashTreesPWABundleStore",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Bundled SilentPassUI.zip did not contain index.html"]
            )
        }
    }

    func activeRootDirectory() -> URL {
        lock.lock()
        defer { lock.unlock() }
        return activeDir
    }

    func activeVersion() -> String {
        readUpdateInfo(from: activeDir)?.ver ?? "0.0.0"
    }

    func resolveFileURL(for requestPath: String) -> URL? {
        let root = activeRootDirectory()
        var path = requestPath
        if path.isEmpty || path == "/" { path = "/index.html" }
        if !path.hasPrefix("/") { path = "/\(path)" }
        let relative = String(path.dropFirst())
        let candidate = root.appendingPathComponent(relative)
        if fileManager.fileExists(atPath: candidate.path) { return candidate }
        if !relative.contains(".") {
            let index = root.appendingPathComponent("index.html")
            if fileManager.fileExists(atPath: index.path) { return index }
        }
        return nil
    }

    func installDownloadToStaging(from zipFile: URL, expectedVersion: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if fileManager.fileExists(atPath: stagingDir.path) {
            try fileManager.removeItem(at: stagingDir)
        }
        try fileManager.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try fileManager.unzipItem(at: zipFile, to: stagingDir)
        removeMacOsMetadata(from: stagingDir)
        guard hasValidBundle(at: stagingDir) else {
            try? fileManager.removeItem(at: stagingDir)
            pendingVersion = nil
            throw NSError(
                domain: "CashTreesPWABundleStore",
                code: 500,
                userInfo: [NSLocalizedDescriptionKey: "Downloaded bundle missing index.html"]
            )
        }
        pendingVersion = expectedVersion
    }

    func promoteStagingToActive() throws {
        lock.lock()
        defer { lock.unlock() }
        guard hasValidBundle(at: stagingDir) else {
            throw NSError(
                domain: "CashTreesPWABundleStore",
                code: 404,
                userInfo: [NSLocalizedDescriptionKey: "No staged PWA update"]
            )
        }
        if fileManager.fileExists(atPath: backupDir.path) {
            try? fileManager.removeItem(at: backupDir)
        }
        if fileManager.fileExists(atPath: activeDir.path) {
            try fileManager.moveItem(at: activeDir, to: backupDir)
        }
        try fileManager.moveItem(at: stagingDir, to: activeDir)
        pendingVersion = nil
    }

    func clearStaging() {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: stagingDir)
        pendingVersion = nil
    }

    func hasPendingUpdate() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return pendingVersion != nil && hasValidBundle(at: stagingDir)
    }

    func pendingUpdateVersion() -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard pendingVersion != nil, hasValidBundle(at: stagingDir) else { return nil }
        return pendingVersion
    }

    // MARK: - Helpers

    private func hasValidBundle(at dir: URL) -> Bool {
        fileManager.fileExists(atPath: dir.appendingPathComponent("index.html").path)
    }

    private func readUpdateInfo(from dir: URL) -> CashTreesPWAUpdateInfo? {
        let url = dir.appendingPathComponent("update.json")
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(CashTreesPWAUpdateInfo.self, from: data)
        else { return nil }
        return info
    }

    private static func readPendingVersion(from staging: URL) -> String? {
        let fm = FileManager.default
        let index = staging.appendingPathComponent("index.html")
        guard fm.fileExists(atPath: index.path) else { return nil }
        let url = staging.appendingPathComponent("update.json")
        guard fm.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let info = try? JSONDecoder().decode(CashTreesPWAUpdateInfo.self, from: data)
        else { return nil }
        return info.ver
    }

    private func removeMacOsMetadata(from directory: URL) {
        let macosx = directory.appendingPathComponent("__MACOSX", isDirectory: true)
        if fileManager.fileExists(atPath: macosx.path) {
            try? fileManager.removeItem(at: macosx)
        }
    }

    static func isSemverNewer(oldVer: String, newVer: String) -> Bool {
        let oldParts = oldVer.split(separator: ".").map { Int($0) ?? 0 }
        let newParts = newVer.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(oldParts.count, newParts.count)
        for i in 0..<count {
            let o = i < oldParts.count ? oldParts[i] : 0
            let n = i < newParts.count ? newParts[i] : 0
            if n > o { return true }
            if n < o { return false }
        }
        return false
    }
}
