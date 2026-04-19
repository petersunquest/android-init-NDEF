import AVFoundation
import Combine
import CoreNFC
import Foundation
import SwiftUI
import UIKit

@MainActor
final class POSViewModel: ObservableObject {
    let api = BeamioAPIClient()

    @Published var showWelcome = false
    @Published var showOnboarding = false
    /// Full-screen launch logo until Home first load completes (existing wallet). Welcome/onboarding never covered.
    @Published private(set) var showLaunchSplash = false

    @Published private(set) var walletPrivateKeyHex: String?
    @Published private(set) var walletAddress: String?

    @Published var merchantInfraCard: String = BeamioConstants.defaultBeamioUserCard
    /// `/api/myPosAddress` `terminalMetadata.allowedTopupMethods`; on fetch failure keep last value.
    @Published var posTerminalPolicy: PosTerminalPolicy = .allAllowed
    /// On-chain reload/mint budget for this POS on the program card (Terminal Onboarding). `nil` if not fetched or RPC failed.
    @Published var posTerminalReloadQuota: PosTerminalReloadQuota?
    @Published var terminalProfile: TerminalProfile?
    @Published var adminProfile: TerminalProfile?

    /// `nil` = unknown (align Android); `false` = no AA / welcome panel
    @Published var hasAAAccount: Bool?
    /// Today dashboard (getAdminStatsFull); `nil` = not loaded or RPC failed
    @Published var cardChargeAmount: Double?
    @Published var cardTopUpAmount: Double?
    @Published private(set) var homeStatsLoaded = false
    /// Home full refresh in progress — ignore overlapping triggers (duplicate Tasks, concurrent refresh).
    private var homeRefreshInFlight = false
    /// While the parent-permission full-screen gate is up: wake every 6s and call `refreshHomeProfiles` if idle (no overlap).
    private var parentPermissionGatePollTask: Task<Void, Never>?
    private static let parentPermissionGatePollIntervalNs: UInt64 = 6_000_000_000
    /// After a **trusted** `getCardAdminInfo` (`ok: true`): whether this wallet may use POS (owner, `upperAdmin`, or any `admins[]` entry). `nil` = never persisted / reset.
    private var lastTrustedInfraPosHomeAccess: Bool?
    /// Filled in `reconcileParentPermissionGateWithServer` when access is **trusted allowed** for `merchantInfraCard`; consumed once by `refreshHomeProfiles` for upper-admin capsule (avoids a second `getCardAdminInfo` on the same tick).
    private var pendingGetCardAdminInfoRootForHome: (cardLower: String, root: [String: Any])?
    /// One-shot bootstrap refresh after the waiting gate first unlocks; covers delayed DB/API propagation without requiring app relaunch.
    private var pendingHomeBootstrapRefreshAfterGateAllow = false
    @Published var infraRoutingTaxPercent: Double?
    @Published var infraRoutingDiscountSummary: String?
    /// Infrastructure / program `BeamioUserCard` metadata `name` (`cards[].cardName`) for the POS `merchantInfraCard` row.
    @Published var homeMerchantProgramCardName: String?
    /// Card Issuance recharge tiers (`metadata` or `metadata.shareTokenMetadata` bonus fields) for `merchantInfraCard`; home row + top-up bump.
    @Published var programRechargeBonusRules: [BeamioRechargeBonusRule] = []

    @Published var homeToast: String?
    /// 注册成功后展示一次（与 web Recovery QR 秘密等价，勿记入日志）
    @Published var pendingRecoveryCode: String?
    /// Consumed once by `OnboardingView.onAppear` — parent `@BeamioTag` from Terminal Setup selection; default handle = `{parent}_POS_{nnnn}`.
    @Published var onboardingParentBeamioTag: String = ""
    /// Parent tag from Terminal Setup — copied to UserDefaults pending key when the permission flow starts; cleared when approved.
    var splashParentBeamioTagForPermission: String = ""
    /// Full-screen gate until a trusted `getCardAdminInfo` shows this wallet on the program card admin tree (`admins[]`, or owner / upperAdmin) (blocks mounting Home).
    @Published var showAwaitingParentPermissionGate = false {
        didSet {
            persistLastKnownParentPermissionGateUiStateIfPossible()
        }
    }
    /// Shown on the permission gate (normalized parent handle, no `@`).
    @Published var permissionGateParentTagLine: String = "" {
        didSet {
            persistLastKnownParentPermissionGateUiStateIfPossible()
        }
    }
    /// After tapping **Resend approval request**, no further resends until this time (persisted per wallet).
    @Published private(set) var terminalPermissionResendCooldownUntil: Date?
    /// Verra workspace gateway overlay (BeamioTag + password + Recovery QR) — opened from onboarding Restore link.
    @Published var showVerraWorkspaceGateway = false
    /// Full-screen waiting gate: pick another parent @BeamioTag for the CoNET approval request (POS filtered user search).
    @Published var changeParentWorkspaceAdminSheetPresented = false

    // Navigation
    enum Sheet: Identifiable {
        case readResult
        case scan(ScanPendingAction)
        var id: String {
            switch self {
            case .readResult: return "readResult"
            case let .scan(a): return "scan-\(a.rawValue)"
            }
        }
    }

    @Published var sheet: Sheet?
    @Published var amountInputMode: ScanPendingAction = .read
    @Published var amountString: String = "0"
    /// Set from Top-up amount sheet (`TopupAmountPadSheet`); shown on scan chrome caption.
    @Published var topupPaymentMethodTitle: String = "Credit Card"
    /// Pad confirm: `TopupPaymentMethodOption.rawValue` (`creditCard` / `cash` / `bonus`). Used to rebuild `currencySplit` after scan dismiss / QR (do not rely on a one-shot split object).
    @Published var pendingTopupMethodRaw: String = ""
    @Published var pendingTopupBonusExpanded: Bool = false
    @Published var pendingTopupBonusRatePercent: Int = 20
    /// Digits entered on the amount pad (principal). When Activate Bonus is on, this is the principal; `amountString` is total (principal + bonus).
    @Published var pendingTopupKeypadAmount: String = ""
    @Published var chargeTipRateBps: Int = 0

    @Published var scanMethod: ScanMethod = .nfc
    @Published var pendingScanAction: ScanPendingAction = .read
    @Published var isNfcBusy = false
    @Published var scanBanner: String = ""

    /// Charge + Scan QR: Android `paymentQrInterpreting` / central white card while parsing JSON.
    @Published var paymentQrInterpreting = false
    /// Charge + QR: invalid payment QR — tap center to rescan (`qrPaymentResetId` bumps scanner).
    @Published var paymentQrParseError: String?
    /// Charge + QR: Smart Routing rows (Android `PaymentRoutingMonitorDisplayCard`).
    @Published var paymentRoutingSteps: [PaymentRoutingStepRow] = []
    /// Charge + QR: failure after routing started (insufficient balance, postAAtoEOA, etc.); tap to retry.
    @Published var paymentTerminalError: String?
    /// Charge + QR success: show `PaymentSuccessView` inside scan sheet (Android inline `PaymentSuccessContent`).
    @Published var chargeApprovedInline: ChargeSuccessState?
    /// Bump to force `BeamioQRScannerView` rebuild after parse error / retry.
    @Published var qrPaymentResetId = 0
    /// Charge + NFC: tag read / early card query failures — aligned with Check Balance (`readQrExecuteError`).
    @Published var chargeNfcReadError: String?

    /// Top-up + Scan QR: Android `topupQrSigningInProgress` — hide camera, central white card "Sign & execute".
    @Published var topupQrSigningInProgress = false
    /// Top-up + QR execute failed — tap center to retry (`retryTopupQrExecute`).
    @Published var topupQrExecuteError: String?
    /// Top-up + NFC: tag read / card prep failures — same pattern as `readQrExecuteError` (tap center to retry NFC).
    @Published var topupNfcReadError: String?
    /// Rebuild QR preview after error / flow reset.
    @Published var topupQrResetId = 0
    /// Shown under "Sign & execute" (Android `topupExecuteUidDisplay`): `@beamioTag` or short wallet.
    @Published var topupQrCustomerHint: String = ""

    /// After NFC/QR customer identified: total credited (program recharge tier + keypad “Activate Bonus” + bonus-only split), for loading UI.
    @Published var topupExecuteDisplayTotal: Double?
    /// Extra credits beyond principal (program `bonusValue` + split `bonusCurrencyAmount`). Shown below total on loading / bottom chrome.
    @Published var topupExecuteDisplayBonus: Double?

    /// Check Balance + Scan QR: hide camera, central loading (`MainActivity` `nfcFetchingInfo` for read via QR).
    @Published var readQrFetchingInProgress = false
    /// Invalid link or API error — tap center to rescan (`readQrResetId` rebuilds scanner).
    @Published var readQrExecuteError: String?
    @Published var readQrResetId = 0
    /// After NFC is dismissed or unavailable: show QR scanner without requiring the segmented control (all scan flows).
    @Published var scanQrCameraArmed = false
    /// System NFC sheet is active — show the same in-panel “waiting for NFC” UI as Check Balance until tap, dismiss, fallback, or error.
    @Published var scanAwaitingNfcTap = false

    @Published var lastReadAssets: UIDAssets?
    @Published var lastReadError: String?
    @Published var lastReadRawJson: String?
    /// `true` if balance was loaded via beamio.app QR / wallet link (vs NFC tag).
    @Published var lastReadViaQr = false

    @Published var linkDeepLink: String = ""
    @Published var linkLockedSun: SunParams?
    @Published var showLinkCancel = false

    @Published var opMessage: String = ""
    @Published var opRunning = false

    /// Android `TopupScreen` / `TopupSuccessContent` full-screen result.
    @Published var topupSuccess: TopupSuccessState?
    /// Android `PaymentScreen` / `PaymentSuccessContent` full-screen result.
    @Published var chargeSuccess: ChargeSuccessState?
    /// Charge preflight: payer assets less than amount due (before payment API / sign).
    @Published var chargeInsufficientFunds: ChargeInsufficientFundsState?

    private let nfc = BeamioNFCSession()

    /// Last successful QR parse for Top-up retry (Android `topupScreenUid` / `topupScreenWallet`).
    private var topupQrLastBeamioTag: String?
    private var topupQrLastWallet: String?

    /// Per-install sandbox marker. UserDefaults is wiped when the user deletes the app, but Keychain
    /// entries for the same bundle ID often survive reinstall on device; clear orphans so init flow runs.
    private static let installContainerMarkerKey = "iosndef.install.container.marker"

    private static let terminalPermissionResendCooldownSeconds: TimeInterval = 120

    private static func pendingParentWorkspaceTagKey(wallet: String) -> String {
        "pos.pendingParentWorkspaceTag.\(wallet.lowercased())"
    }

    private static func terminalPermissionAutoSentKey(wallet: String) -> String {
        "pos.terminalPermissionAutoSent.\(wallet.lowercased())"
    }

    private static func permissionResendCooldownUntilKey(wallet: String) -> String {
        "pos.terminalPermissionResendCooldownUntil.\(wallet.lowercased())"
    }

    private static func lastTrustedInfraPosHomeAccessKey(wallet: String) -> String {
        "pos.lastTrustedInfraPosHomeAccess.\(wallet.lowercased())"
    }

    /// Last visible waiting-workspace cover state. Restored before async refresh to avoid a launch flicker.
    private static func lastKnownParentPermissionGateVisibleKey(wallet: String) -> String {
        "pos.lastKnownParentPermissionGateVisible.\(wallet.lowercased())"
    }

    private static func lastKnownParentPermissionGateTagKey(wallet: String) -> String {
        "pos.lastKnownParentPermissionGateTag.\(wallet.lowercased())"
    }

    /// Legacy key before sub-admin (`admins[]`) was included in the POS gate rule.
    private static func legacyLastTrustedInfraOwnerOrUpperKey(wallet: String) -> String {
        "pos.lastTrustedInfraIsOwnerOrUpperAdmin.\(wallet.lowercased())"
    }

    private func loadPersistedTrustedInfraPosHomeAccess(walletLower: String) {
        let newK = Self.lastTrustedInfraPosHomeAccessKey(wallet: walletLower)
        let oldK = Self.legacyLastTrustedInfraOwnerOrUpperKey(wallet: walletLower)
        if let v = UserDefaults.standard.object(forKey: newK) as? Bool {
            lastTrustedInfraPosHomeAccess = v
        } else if let v = UserDefaults.standard.object(forKey: oldK) as? Bool {
            lastTrustedInfraPosHomeAccess = v
            UserDefaults.standard.set(v, forKey: newK)
        } else {
            lastTrustedInfraPosHomeAccess = nil
        }
    }

    private func persistTrustedInfraPosHomeAccess(walletLower: String, allowed: Bool) {
        lastTrustedInfraPosHomeAccess = allowed
        UserDefaults.standard.set(allowed, forKey: Self.lastTrustedInfraPosHomeAccessKey(wallet: walletLower))
        UserDefaults.standard.removeObject(forKey: Self.legacyLastTrustedInfraOwnerOrUpperKey(wallet: walletLower))
    }

    private func resetTrustedInfraPosHomeAccessForWalletChange(walletLower: String) {
        lastTrustedInfraPosHomeAccess = nil
        pendingGetCardAdminInfoRootForHome = nil
        UserDefaults.standard.removeObject(forKey: Self.lastTrustedInfraPosHomeAccessKey(wallet: walletLower))
        UserDefaults.standard.removeObject(forKey: Self.legacyLastTrustedInfraOwnerOrUpperKey(wallet: walletLower))
    }

    private func normalizeParentBeamioTag(_ raw: String?) -> String {
        var tag = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while tag.hasPrefix("@") { tag.removeFirst() }
        return tag.replacingOccurrences(of: "@", with: "")
    }

    private func persistLastKnownParentPermissionGateUiStateIfPossible() {
        guard let walletLower = walletAddress?.lowercased() else { return }
        let defaults = UserDefaults.standard
        defaults.set(showAwaitingParentPermissionGate, forKey: Self.lastKnownParentPermissionGateVisibleKey(wallet: walletLower))
        let tag = normalizeParentBeamioTag(permissionGateParentTagLine)
        if tag.isEmpty {
            defaults.removeObject(forKey: Self.lastKnownParentPermissionGateTagKey(wallet: walletLower))
        } else {
            defaults.set(tag, forKey: Self.lastKnownParentPermissionGateTagKey(wallet: walletLower))
        }
    }

    /// Restore the last on-screen gate state before we refresh from server.
    private func restoreLastKnownParentPermissionGateUiState(walletLower: String) -> Bool {
        let defaults = UserDefaults.standard
        let visibleKey = Self.lastKnownParentPermissionGateVisibleKey(wallet: walletLower)
        guard defaults.object(forKey: visibleKey) != nil else { return false }
        showAwaitingParentPermissionGate = defaults.bool(forKey: visibleKey)
        let pendingTag = normalizeParentBeamioTag(defaults.string(forKey: Self.pendingParentWorkspaceTagKey(wallet: walletLower)))
        let savedTag = normalizeParentBeamioTag(defaults.string(forKey: Self.lastKnownParentPermissionGateTagKey(wallet: walletLower)))
        permissionGateParentTagLine = savedTag.isEmpty ? pendingTag : savedTag
        return true
    }

    private func applyInitialParentPermissionGateUiState(walletLower: String) {
        if restoreLastKnownParentPermissionGateUiState(walletLower: walletLower) {
            return
        }
        // Fallback for first launch before any UI snapshot exists.
        showAwaitingParentPermissionGate = (lastTrustedInfraPosHomeAccess != true)
        permissionGateParentTagLine = normalizeParentBeamioTag(
            UserDefaults.standard.string(forKey: Self.pendingParentWorkspaceTagKey(wallet: walletLower))
        )
    }

    /// Home data is keyed by infra card. When the resolved POS card changes in-session, immediately swap to that context
    /// so the first post-approval Home render does not stay bound to the old/default card until next launch.
    private func adoptMerchantInfraCardForHome(wallet w: String, addr raw: String, replaceDisplayValues: Bool) {
        let next = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeAddress(next) else { return }
        let prevLower = merchantInfraCard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let nextLower = next.lowercased()
        merchantInfraCard = next
        guard nextLower != prevLower else { return }
        pendingGetCardAdminInfoRootForHome = nil
        homeMerchantProgramCardName = nil
        posTerminalReloadQuota = nil
        programRechargeBonusRules = []
        resetTrustedInfraPosHomeAccessForWalletChange(walletLower: w.lowercased())
        // Keep the last rendered screen until the next trusted admin check decides whether Home is still allowed.
        applyTrustedStatsAndRoutingCachesForInfra(wallet: w, infra: next, replaceDisplayValues: replaceDisplayValues)
    }

    init() {
        reconcileKeychainWithAppContainer()

        if let hex = BeamioKeychain.loadPrivateKeyHex() {
            walletPrivateKeyHex = hex
            walletAddress = try? BeamioEthWallet.address(fromPrivateKeyHex: hex)
            showWelcome = false
            showOnboarding = false
            showLaunchSplash = true
            applyTrustedProfileCachesFromDisk()
            if let w = walletAddress {
                let wl = w.lowercased()
                loadPersistedTrustedInfraPosHomeAccess(walletLower: wl)
                // First paint should reuse the last rendered gate state, then async refresh reconciles with trusted server data.
                applyInitialParentPermissionGateUiState(walletLower: wl)
                applyTrustedStatsAndRoutingCachesForInfra(wallet: w, infra: merchantInfraCard, replaceDisplayValues: false)
            }
            if shouldDismissLaunchSplashFromTrustedHomeCache {
                showLaunchSplash = false
            }
        } else {
            showWelcome = true
            showOnboarding = false
            showLaunchSplash = false
        }

        nfc.onMessage = { [weak self] result in
            Task { @MainActor in
                await self?.handleNfcResult(result)
            }
        }
        nfc.onUserCanceled = { [weak self] in
            Task { @MainActor in
                await self?.handleScanSheetNfcDismissedByUser()
            }
        }
        nfc.onReadingUnavailable = { [weak self] in
            Task { @MainActor in
                await self?.handleScanNfcReadingUnavailable()
            }
        }

        Task { @MainActor in
            await refreshInfraCardFromDbIfPossible()
            if walletAddress != nil, !showWelcome, !showOnboarding {
                await refreshHomeProfiles()
            }
        }
    }

    /// Beamio trusted-cache / local-first: load profile JSON written only after successful profile search.
    private func applyTrustedProfileCachesFromDisk() {
        guard let w = walletAddress else { return }
        let loaded = POSHomeScreenTrustedCache.loadProfiles(wallet: w)
        if let t = loaded.terminal { terminalProfile = t }
        if let a = loaded.admin { adminProfile = a }
    }

    /// Restore stats + routing from disk for `(wallet, infra)`; `replaceDisplayValues` true when POS infra address changed so we do not show another card’s numbers.
    private func applyTrustedStatsAndRoutingCachesForInfra(wallet: String, infra: String, replaceDisplayValues: Bool) {
        let (c, t) = POSHomeScreenTrustedCache.loadStats(wallet: wallet, infraCard: infra)
        if replaceDisplayValues {
            cardChargeAmount = c
            cardTopUpAmount = t
            homeStatsLoaded = c != nil || t != nil
            if let rout = POSHomeScreenTrustedCache.loadRouting(wallet: wallet, infraCard: infra) {
                infraRoutingTaxPercent = rout.tax
                infraRoutingDiscountSummary = rout.summary
            } else {
                infraRoutingTaxPercent = nil
                infraRoutingDiscountSummary = nil
            }
        } else {
            if let c { cardChargeAmount = c }
            if let t { cardTopUpAmount = t }
            if c != nil || t != nil { homeStatsLoaded = true }
            if let rout = POSHomeScreenTrustedCache.loadRouting(wallet: wallet, infraCard: infra) {
                infraRoutingTaxPercent = rout.tax
                infraRoutingDiscountSummary = rout.summary
            }
        }
    }

    private var shouldDismissLaunchSplashFromTrustedHomeCache: Bool {
        terminalProfile != nil || adminProfile != nil || homeStatsLoaded
    }

    private func reconcileKeychainWithAppContainer() {
        let defaults = UserDefaults.standard
        guard defaults.string(forKey: Self.installContainerMarkerKey) == nil else { return }
        try? BeamioKeychain.deletePrivateKey()
        defaults.set(UUID().uuidString, forKey: Self.installContainerMarkerKey)
    }

    /// 首次创建：BIP39 助记词 → `createRecover` 风格 Argon2id+AES-GCM+recover → `POST /api/addUser` → Keychain
    func completeOnboarding(beamioAccountName rawTag: String, password: String, confirmPassword: String) async {
        homeToast = nil
        pendingRecoveryCode = nil
        var tag = rawTag.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("@") { tag.removeFirst() }
        guard tag.range(of: "^[a-zA-Z0-9_.]{3,20}$", options: .regularExpression) != nil else {
            homeToast = "Use a business handle of 3–20 letters, numbers, dots, or underscores."
            return
        }
        let pw = password
        let rules = Self.passwordRuleChecks(pw)
        guard rules.len8, rules.mixed, rules.numbers, pw == confirmPassword else {
            homeToast = "Password must be at least 8 characters with upper & lower case and a digit."
            return
        }
        let avail = await api.isBeamioAccountNameAvailable(tag)
        if avail == nil {
            homeToast = "Could not verify handle availability. Check network and try again."
            return
        }
        if avail == false {
            homeToast = "This handle is already taken."
            return
        }
        let mnemonic: String
        do {
            mnemonic = try BeamioBIP39.generateMnemonic12()
        } catch {
            homeToast = error.localizedDescription
            return
        }
        let payload: BeamioRecoverPayload.BuildResult
        do {
            payload = try BeamioRecoverPayload.build(beamioTag: tag, pin: pw, mnemonicPhrase: mnemonic)
        } catch {
            homeToast = error.localizedDescription
            return
        }
        let hex = payload.privateKeyHex
        do {
            let lower = try BeamioEthWallet.address(fromPrivateKeyHex: hex)
            let checksummed = try BeamioEIP55.checksumAddress(lowercaseHex40: String(lower.dropFirst(2)))
            let signMessage = try BeamioEthWallet.signEthereumPersonalMessage(privateKeyHex: hex, message: checksummed)
            let reg = await api.registerBeamioAccount(
                accountName: tag,
                walletAddress: checksummed,
                signMessage: signMessage,
                recover: payload.recover
            )
            guard reg.ok else {
                homeToast = reg.error ?? "Registration failed."
                return
            }
            try BeamioKeychain.savePrivateKeyHex(hex)
            walletPrivateKeyHex = hex
            walletAddress = lower
            resetTrustedInfraPosHomeAccessForWalletChange(walletLower: lower.lowercased())
            showAwaitingParentPermissionGate = true
            stopParentPermissionGatePolling()
            pendingRecoveryCode = payload.recoveryCode
            showOnboarding = false
            showWelcome = false
            showLaunchSplash = true
            let seeded = TerminalProfile(accountName: tag, firstName: nil, lastName: nil, image: nil, address: lower)
            terminalProfile = seeded
            POSHomeScreenTrustedCache.saveTerminal(seeded, wallet: lower)
            Task { @MainActor in
                await refreshInfraCardFromDbIfPossible()
                await refreshHomeProfiles()
                await maybeRunTerminalParentCoNetPermissionFlowAfterOnboarding()
            }
        } catch {
            homeToast = error.localizedDescription
        }
    }

    /// After first wallet creation from Terminal Setup: persist parent tag, keep full-screen gate until this wallet is on the program card admin tree; auto-send once if not yet sent.
    func maybeRunTerminalParentCoNetPermissionFlowAfterOnboarding() async {
        defer {
            if showAwaitingParentPermissionGate {
                startParentPermissionGatePollingIfNeeded()
            }
        }
        var parent = normalizeParentBeamioTag(splashParentBeamioTagForPermission)
        if parent.isEmpty, let w0 = walletAddress {
            let wl0 = w0.lowercased()
            parent = normalizeParentBeamioTag(
                UserDefaults.standard.string(forKey: Self.pendingParentWorkspaceTagKey(wallet: wl0))
            )
        }
        guard !parent.isEmpty else { return }
        guard let w = walletAddress, walletPrivateKeyHex != nil else { return }
        let wl = w.lowercased()

        UserDefaults.standard.set(parent, forKey: Self.pendingParentWorkspaceTagKey(wallet: wl))
        splashParentBeamioTagForPermission = ""
        permissionGateParentTagLine = parent
        showAwaitingParentPermissionGate = true
        syncTerminalPermissionResendCooldownFromDefaults(walletLower: wl)

        let infra = merchantInfraCard
        if let allowed = await posTerminalTrustedProgramCardAccess(wallet: w, infra: infra), allowed {
            clearTerminalParentPermissionPendingState(walletLower: wl)
            return
        }

        let autoKey = Self.terminalPermissionAutoSentKey(wallet: wl)
        if UserDefaults.standard.bool(forKey: autoKey) { return }

        let result = await sendTerminalPermissionCoNetMessage(parentNormalized: parent)
        if result.ok {
            UserDefaults.standard.set(true, forKey: autoKey)
            homeToast = "A permission request was sent to your workspace parent via CoNET. You can continue when they approve."
        } else if let err = result.userVisibleError {
            homeToast = err
        }
    }

    /// Manual resend from the awaiting-authorization overlay. Starts a **120s** cooldown immediately on tap (even if send fails).
    func resendTerminalParentPermissionRequest() async {
        guard let w = walletAddress, walletPrivateKeyHex != nil else { return }
        let wl = w.lowercased()
        syncTerminalPermissionResendCooldownFromDefaults(walletLower: wl)
        if let until = terminalPermissionResendCooldownUntil, until > Date() {
            homeToast = "Please wait before resending the approval request."
            return
        }

        var parent = UserDefaults.standard.string(forKey: Self.pendingParentWorkspaceTagKey(wallet: wl))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        while parent.hasPrefix("@") { parent.removeFirst() }
        parent = parent.replacingOccurrences(of: "@", with: "")
        if parent.isEmpty {
            var p = permissionGateParentTagLine.trimmingCharacters(in: .whitespacesAndNewlines)
            while p.hasPrefix("@") { p.removeFirst() }
            p = p.replacingOccurrences(of: "@", with: "")
            parent = p
        }
        guard !parent.isEmpty else {
            homeToast = "No workspace parent is set. Use Change workspace parent to pick one."
            return
        }
        UserDefaults.standard.set(parent, forKey: Self.pendingParentWorkspaceTagKey(wallet: wl))

        beginTerminalPermissionResendCooldown(walletLower: wl)

        let infra = merchantInfraCard
        if let allowed = await posTerminalTrustedProgramCardAccess(wallet: w, infra: infra), allowed {
            clearTerminalParentPermissionPendingState(walletLower: wl)
            return
        }

        let result = await sendTerminalPermissionCoNetMessage(parentNormalized: parent)
        if result.ok {
            homeToast = "Approval request sent again."
        } else if let err = result.userVisibleError {
            homeToast = err
        }
    }

    /// True when `getCardAdminInfo` lists this wallet on the program card: contract `owner`, response `upperAdmin`, or **any** address in `admins` (subordinate admin).
    private static func walletHasTrustedInfraPosHomeAccess(root: [String: Any], walletLower wl: String) -> Bool {
        let ow = (root["owner"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !ow.isEmpty, wl == ow { return true }
        let ua = (root["upperAdmin"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        if !ua.isEmpty, wl == ua { return true }
        guard let admins = root["admins"] as? [Any] else { return false }
        for a in admins {
            let s = String(describing: a).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if s == wl { return true }
        }
        return false
    }

    private struct PosTrustedProgramCardAccessDetail {
        let allowed: Bool
        /// Set when the allow/deny decision came from HTTP `getCardAdminInfo` (same JSON can seed Home `upperAdmin` without refetching).
        let httpAdminRootFromAccessCheck: [String: Any]?
    }

    /// Prefer Base `owner()` / `isAdmin(wallet)`; if RPC fails, fall back to HTTP `getCardAdminInfo` JSON. `nil` = both paths untrusted.
    private func posTerminalTrustedProgramCardAccessDetail(wallet w: String, infra: String) async -> PosTrustedProgramCardAccessDetail? {
        if let chain = await api.fetchPosProgramCardHomeAccessAllowed(cardAddress: infra, wallet: w) {
            return PosTrustedProgramCardAccessDetail(allowed: chain, httpAdminRootFromAccessCheck: nil)
        }
        guard let root = await api.fetchCardAdminInfoRoot(cardAddress: infra, wallet: w) else { return nil }
        let allowed = Self.walletHasTrustedInfraPosHomeAccess(root: root, walletLower: w.lowercased())
        return PosTrustedProgramCardAccessDetail(allowed: allowed, httpAdminRootFromAccessCheck: root)
    }

    private func posTerminalTrustedProgramCardAccess(wallet w: String, infra: String) async -> Bool? {
        guard let d = await posTerminalTrustedProgramCardAccessDetail(wallet: w, infra: infra) else { return nil }
        return d.allowed
    }

    /// After trusted **allowed** gate: ensure Home init has one `getCardAdminInfo` root for this program card (reuse HTTP root from access check when present; else fetch once for `upperAdmin` / routing).
    private func hydratePendingGetCardAdminInfoForHomeAfterTrustedAllow(wallet w: String, infra: String, httpRootFromAccess: [String: Any]?) async {
        let c = infra.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeAddress(c) else {
            pendingGetCardAdminInfoRootForHome = nil
            return
        }
        let cl = c.lowercased()
        if let r = httpRootFromAccess {
            pendingGetCardAdminInfoRootForHome = (cl, r)
            return
        }
        if let r = await api.fetchCardAdminInfoRoot(cardAddress: c, wallet: w) {
            pendingGetCardAdminInfoRootForHome = (cl, r)
        } else {
            pendingGetCardAdminInfoRootForHome = nil
        }
    }

    /// Workspace / parent `@BeamioTag` search: server-side filter via `GET /api/search-users-by-card-owner-or-admin` (replaces local `search-users` + `getCardAdminInfo` filter).
    func searchUsersListForPOSTerminal(keyward: String) async -> [TerminalProfile] {
        let infra = merchantInfraCard.trimmingCharacters(in: .whitespacesAndNewlines)
        return await api.searchUsersListForPOS(keyward: keyward, wallet: walletAddress, merchantInfraCard: infra)
    }

    private func posSearchUsersFirst(keyward: String) async -> TerminalProfile? {
        let infra = merchantInfraCard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let w = walletAddress else { return nil }
        return await api.searchUsersListForPOS(keyward: keyward, wallet: w, merchantInfraCard: infra).first
    }

    private func clearTerminalParentPermissionPendingState(walletLower: String) {
        stopParentPermissionGatePolling()
        let d = UserDefaults.standard
        d.removeObject(forKey: Self.pendingParentWorkspaceTagKey(wallet: walletLower))
        d.removeObject(forKey: Self.terminalPermissionAutoSentKey(wallet: walletLower))
        d.removeObject(forKey: Self.permissionResendCooldownUntilKey(wallet: walletLower))
        splashParentBeamioTagForPermission = ""
        permissionGateParentTagLine = ""
        showAwaitingParentPermissionGate = false
        terminalPermissionResendCooldownUntil = nil
    }

    private func syncTerminalPermissionResendCooldownFromDefaults(walletLower: String) {
        let key = Self.permissionResendCooldownUntilKey(wallet: walletLower)
        let t = UserDefaults.standard.double(forKey: key)
        guard t > 0 else {
            terminalPermissionResendCooldownUntil = nil
            return
        }
        let until = Date(timeIntervalSince1970: t)
        if until <= Date() {
            UserDefaults.standard.removeObject(forKey: key)
            terminalPermissionResendCooldownUntil = nil
        } else {
            terminalPermissionResendCooldownUntil = until
        }
    }

    private func beginTerminalPermissionResendCooldown(walletLower: String) {
        let until = Date().addingTimeInterval(Self.terminalPermissionResendCooldownSeconds)
        UserDefaults.standard.set(until.timeIntervalSince1970, forKey: Self.permissionResendCooldownUntilKey(wallet: walletLower))
        terminalPermissionResendCooldownUntil = until
    }

    /// - Returns: `userVisibleError` only when the flow should surface a toast (nil on success).
    /// Resolves parent @BeamioTag → EOA with **global** `GET /api/search-users` (SilentPassUI parity). Do **not** use `search-users-by-card-owner-or-admin` here: after POS binds the real program card, the parent may fall outside that filter while still being the valid CoNET recipient.
    private func sendTerminalPermissionCoNetMessage(parentNormalized parent: String) async -> (ok: Bool, userVisibleError: String?) {
        guard let w = walletAddress, let hex = walletPrivateKeyHex else { return (false, nil) }
        guard let parentProf = await api.searchUsers(keyward: parent),
              let pAddrRaw = parentProf.address?.trimmingCharacters(in: .whitespacesAndNewlines),
              !pAddrRaw.isEmpty
        else {
            return (false, "Could not find the parent workspace on Beamio.")
        }
        let childTag = terminalProfile?.accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chatReady = await BeamioConetChatRouteRegister.ensureRegisteredForSenderGossip(walletPrivateKeyHex: hex)
        guard chatReady else {
            return (false, "Could not register CoNET chat keys for this device. Check the network and try again.")
        }
        let ok = await BeamioConetGossipSend.sendTerminalPermissionRequest(
            recipientEoa: pAddrRaw,
            childEoa: w,
            childBeamioTag: childTag,
            parentBeamioTag: parent,
            walletPrivateKeyHex: hex
        )
        if ok { return (true, nil) }
        return (false, "Could not send the CoNET permission request. Check the network and try again.")
    }

    /// POS Home is blocked until **trusted** on-chain `owner`/`isAdmin` (or HTTP fallback) confirms this wallet on the program card.
    private func reconcileParentPermissionGateWithServer() async {
        guard let w = walletAddress else { return }
        let wl = w.lowercased()
        let rawPending = UserDefaults.standard.string(forKey: Self.pendingParentWorkspaceTagKey(wallet: wl))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let pending = normalizeParentBeamioTag(rawPending)
        let infra = merchantInfraCard
        let wasAwaitingGate = showAwaitingParentPermissionGate

        if let detail = await posTerminalTrustedProgramCardAccessDetail(wallet: w, infra: infra) {
            persistTrustedInfraPosHomeAccess(walletLower: wl, allowed: detail.allowed)
            if detail.allowed {
                await hydratePendingGetCardAdminInfoForHomeAfterTrustedAllow(wallet: w, infra: infra, httpRootFromAccess: detail.httpAdminRootFromAccessCheck)
                if wasAwaitingGate {
                    pendingHomeBootstrapRefreshAfterGateAllow = true
                }
                clearTerminalParentPermissionPendingState(walletLower: wl)
                return
            }
            pendingGetCardAdminInfoRootForHome = nil
            permissionGateParentTagLine = pending
            showAwaitingParentPermissionGate = true
            syncTerminalPermissionResendCooldownFromDefaults(walletLower: wl)
            startParentPermissionGatePollingIfNeeded()
            return
        }

        // Untrusted: Base RPC + HTTP both failed — must not widen access.
        pendingGetCardAdminInfoRootForHome = nil
        permissionGateParentTagLine = pending
        showAwaitingParentPermissionGate = true
        if !pending.isEmpty {
            syncTerminalPermissionResendCooldownFromDefaults(walletLower: wl)
        }
        startParentPermissionGatePollingIfNeeded()
    }

    private func startParentPermissionGatePollingIfNeeded() {
        guard showAwaitingParentPermissionGate else { return }
        guard parentPermissionGatePollTask == nil else { return }
        parentPermissionGatePollTask = Task { [weak self] in
            guard let self else { return }
            await self.runParentPermissionGatePollLoop()
        }
    }

    private func stopParentPermissionGatePolling() {
        parentPermissionGatePollTask?.cancel()
        parentPermissionGatePollTask = nil
    }

    /// Single flight: each tick waits 6s, then skips if `homeRefreshInFlight` or gate closed; otherwise `await refreshHomeProfiles()`.
    private func runParentPermissionGatePollLoop() async {
        defer { parentPermissionGatePollTask = nil }
        while showAwaitingParentPermissionGate, !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: Self.parentPermissionGatePollIntervalNs)
            } catch {
                break
            }
            guard showAwaitingParentPermissionGate, !Task.isCancelled else { break }
            if homeRefreshInFlight {
                continue
            }
            await refreshHomeProfiles()
        }
    }

    func clearSplashParentForTerminalSetup() {
        splashParentBeamioTagForPermission = ""
    }

    func openChangeParentWorkspaceAdminPicker() {
        changeParentWorkspaceAdminSheetPresented = true
    }

    func cancelChangeParentWorkspaceAdminPicker() {
        changeParentWorkspaceAdminSheetPresented = false
    }

    /// Replace pending parent tag, clear auto-send + resend cooldown, send a new permission request to the chosen @BeamioTag (if still not on the program card admin tree).
    func confirmChangeParentWorkspaceAdmin(normalizedParentTag raw: String) async {
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("@") { tag.removeFirst() }
        tag = tag.replacingOccurrences(of: "@", with: "")
        guard tag.range(of: "^[a-zA-Z0-9_.]{3,20}$", options: .regularExpression) != nil else {
            homeToast = "Enter a valid @BeamioTag (3–20 letters, numbers, dots, or underscores)."
            return
        }
        guard let w = walletAddress, walletPrivateKeyHex != nil else { return }
        let wl = w.lowercased()

        UserDefaults.standard.set(tag, forKey: Self.pendingParentWorkspaceTagKey(wallet: wl))
        permissionGateParentTagLine = tag
        UserDefaults.standard.removeObject(forKey: Self.terminalPermissionAutoSentKey(wallet: wl))
        UserDefaults.standard.removeObject(forKey: Self.permissionResendCooldownUntilKey(wallet: wl))
        terminalPermissionResendCooldownUntil = nil
        changeParentWorkspaceAdminSheetPresented = false

        let infra = merchantInfraCard
        if let allowed = await posTerminalTrustedProgramCardAccess(wallet: w, infra: infra), allowed {
            clearTerminalParentPermissionPendingState(walletLower: wl)
            return
        }

        let result = await sendTerminalPermissionCoNetMessage(parentNormalized: tag)
        if result.ok {
            UserDefaults.standard.set(true, forKey: Self.terminalPermissionAutoSentKey(wallet: wl))
            homeToast = "Approval request sent to @\(tag)."
        } else if let err = result.userVisibleError {
            homeToast = err
        }
    }

    /// `bizSite` `restoreWithUserPin` parity: chain recover blob → decrypt mnemonic → Keychain → Home.
    /// - Returns: `nil` on success; otherwise an English error line for inline UI (e.g. Verra gateway form).
    @discardableResult
    func restoreWorkspaceFromPin(beamioTag raw: String, accessPassword pin: String) async -> String? {
        splashParentBeamioTagForPermission = ""
        var tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while tag.hasPrefix("@") { tag.removeFirst() }
        tag = tag.replacingOccurrences(of: "@", with: "")
        guard tag.range(of: "^[a-zA-Z0-9_.]{3,20}$", options: .regularExpression) != nil else {
            return "Use 3–20 letters, numbers, dots, or underscores"
        }
        guard let outer = await api.getRecoverBase64ByAccountName(tag)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !outer.isEmpty
        else {
            return "Invalid Beamio Tag or Recovery Password, please try again"
        }
        guard let decoded = BeamioRecoverRestore.decodeStoragePayload(outerBase64: outer) else {
            return "Invalid Beamio Tag or Recovery Password, please try again"
        }
        let decryptedB64: String
        do {
            decryptedB64 = try BeamioRecoverCrypto.aes_gcm_decrypt_stored(
                cipherB64: decoded.img,
                password: pin,
                stored: decoded.stored
            )
        } catch {
            return "Invalid Beamio Tag or Recovery Password, please try again"
        }
        let phraseTrim = decryptedB64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mnemonicBytes = Data(base64Encoded: phraseTrim),
              let phrase = String(data: mnemonicBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phrase.isEmpty
        else {
            return "Invalid Beamio Tag or Recovery Password, please try again"
        }
        let hex: String
        do {
            hex = try BeamioBIP32.ethereumPrivateKeyHexFromMnemonic(phrase)
        } catch {
            return "Invalid Beamio Tag or Recovery Password, please try again"
        }
        do {
            let lower = try BeamioEthWallet.address(fromPrivateKeyHex: hex)
            try BeamioKeychain.savePrivateKeyHex(hex)
            walletPrivateKeyHex = hex
            walletAddress = lower
            loadPersistedTrustedInfraPosHomeAccess(walletLower: lower.lowercased())
            showAwaitingParentPermissionGate = (lastTrustedInfraPosHomeAccess != true)
            showWelcome = false
            showOnboarding = false
            showLaunchSplash = true
            applyTrustedProfileCachesFromDisk()
            let seeded = TerminalProfile(accountName: tag, firstName: nil, lastName: nil, image: nil, address: lower)
            terminalProfile = seeded
            POSHomeScreenTrustedCache.saveTerminal(seeded, wallet: lower)
            if let w = walletAddress {
                applyTrustedStatsAndRoutingCachesForInfra(wallet: w, infra: merchantInfraCard, replaceDisplayValues: false)
            }
            Task { @MainActor in
                await refreshInfraCardFromDbIfPossible()
                await refreshHomeProfiles()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// `bizSite` `restoreWithRedeem(recoveryCode, '')`: `keccak256(abi.encodePacked(code))` → chain blob → AES-GCM password `pin + code` with empty pin.
    @discardableResult
    func restoreWorkspaceFromRecoveryCode(_ rawCode: String) async -> String? {
        splashParentBeamioTagForPermission = ""
        let code = rawCode.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !code.isEmpty else {
            return "Recovery code is required."
        }
        let hashHex = BeamioEthWallet.solidityPackedKeccak256(utf8Parts: [code])
        guard let outer = await api.getRecoverBase64ByNameHash(hashHex: hashHex)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !outer.isEmpty
        else {
            return "Invalid recovery QR code"
        }
        guard let decoded = BeamioRecoverRestore.decodeStoragePayload(outerBase64: outer) else {
            return "Invalid recovery QR code"
        }
        let decryptedB64: String
        do {
            decryptedB64 = try BeamioRecoverCrypto.aes_gcm_decrypt_stored(
                cipherB64: decoded.img,
                password: code,
                stored: decoded.stored
            )
        } catch {
            return "Invalid recovery QR code"
        }
        let phraseTrim = decryptedB64.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let mnemonicBytes = Data(base64Encoded: phraseTrim),
              let phrase = String(data: mnemonicBytes, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !phrase.isEmpty
        else {
            return "Invalid recovery QR code"
        }
        let hex: String
        do {
            hex = try BeamioBIP32.ethereumPrivateKeyHexFromMnemonic(phrase)
        } catch {
            return "Invalid recovery QR code"
        }
        do {
            let lower = try BeamioEthWallet.address(fromPrivateKeyHex: hex)
            try BeamioKeychain.savePrivateKeyHex(hex)
            walletPrivateKeyHex = hex
            walletAddress = lower
            loadPersistedTrustedInfraPosHomeAccess(walletLower: lower.lowercased())
            showAwaitingParentPermissionGate = (lastTrustedInfraPosHomeAccess != true)
            showWelcome = false
            showOnboarding = false
            showLaunchSplash = true
            applyTrustedProfileCachesFromDisk()
            let seeded = TerminalProfile(accountName: nil, firstName: nil, lastName: nil, image: nil, address: lower)
            terminalProfile = seeded
            POSHomeScreenTrustedCache.saveTerminal(seeded, wallet: lower)
            if let w = walletAddress {
                applyTrustedStatsAndRoutingCachesForInfra(wallet: w, infra: merchantInfraCard, replaceDisplayValues: false)
            }
            Task { @MainActor in
                await refreshInfraCardFromDbIfPossible()
                await refreshHomeProfiles()
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private static func passwordRuleChecks(_ password: String) -> (len8: Bool, mixed: Bool, numbers: Bool) {
        let len8 = password.count >= 8
        let mixed = password.range(of: "[a-z]", options: .regularExpression) != nil
            && password.range(of: "[A-Z]", options: .regularExpression) != nil
        let numbers = password.range(of: "[0-9]", options: .regularExpression) != nil
        return (len8, mixed, numbers)
    }

    func goCreateWallet(prefillNormalizedHandle: String? = nil) {
        showVerraWorkspaceGateway = false
        onboardingParentBeamioTag = ""
        splashParentBeamioTagForPermission = ""
        if var p = prefillNormalizedHandle?.trimmingCharacters(in: .whitespacesAndNewlines), !p.isEmpty {
            while p.hasPrefix("@") { p.removeFirst() }
            p = p.replacingOccurrences(of: "@", with: "")
            if !p.isEmpty {
                onboardingParentBeamioTag = p
                splashParentBeamioTagForPermission = p
            }
        }
        showWelcome = false
        showOnboarding = true
    }

    /// `{parent}_POS_{nnnn}` within 20 chars (Cluster / `isBeamioAccountNameAvailable` rule).
    static func assemblePosTerminalBeamioTag(parent rawParent: String, sequence: Int) -> String {
        let tail = "_POS_" + String(format: "%04d", min(max(sequence, 0), 9999))
        var base = rawParent.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasPrefix("@") { base.removeFirst() }
        base = base.replacingOccurrences(of: "@", with: "")
        // Parent may be a short address label with `…`; only [a-zA-Z0-9_.] is valid for Beamio tags.
        base = base.replacingOccurrences(of: "[^a-zA-Z0-9_.]", with: "", options: .regularExpression)
        if base.isEmpty { base = "pos" }
        let maxPrefix = max(0, 20 - tail.count)
        if base.count > maxPrefix {
            base = String(base.prefix(maxPrefix))
        }
        let combined = base + tail
        guard combined.count >= 3 else {
            return "pos" + tail
        }
        return combined
    }

    private static let onboardTagAvailabilityRetries = 3
    private static let onboardTagAvailabilityRetryNanos: UInt64 = 400_000_000

    /// Registry says name is free (`true`) or taken (`false`); `nil` after retries = could not verify (do not prefill).
    private func isBeamioTagNameVerifiedAvailable(_ candidate: String) async -> Bool? {
        for attempt in 0 ..< Self.onboardTagAvailabilityRetries {
            let avail = await api.isBeamioAccountNameAvailable(candidate)
            if avail == true { return true }
            if avail == false { return false }
            if attempt < Self.onboardTagAvailabilityRetries - 1 {
                try? await Task.sleep(nanoseconds: Self.onboardTagAvailabilityRetryNanos)
            }
        }
        return nil
    }

    /// First assembled candidate for which on-chain availability is **confirmed** (`true`). Empty if none verified or RPC cannot confirm.
    func resolveFirstAvailablePosTerminalTag(parent rawParent: String) async -> String {
        let parent = rawParent.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "@", with: "")
        guard !parent.isEmpty else { return "" }
        for n in 1 ... 9999 {
            let candidate = Self.assemblePosTerminalBeamioTag(parent: parent, sequence: n)
            guard candidate.range(of: "^[a-zA-Z0-9_.]{3,20}$", options: .regularExpression) != nil else { continue }
            let verified = await isBeamioTagNameVerifiedAvailable(candidate)
            if verified == true { return candidate }
            if verified == false { continue }
            return ""
        }
        return ""
    }

    func refreshHomeProfiles() async {
        if homeRefreshInFlight { return }
        homeRefreshInFlight = true
        defer {
            homeRefreshInFlight = false
            if !showWelcome && !showOnboarding {
                showLaunchSplash = false
            }
            if pendingHomeBootstrapRefreshAfterGateAllow, !showAwaitingParentPermissionGate {
                pendingHomeBootstrapRefreshAfterGateAllow = false
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    await refreshHomeProfiles()
                }
            }
        }
        guard let w = walletAddress else { return }
        await refreshInfraCardFromDbIfPossible()
        await ensureMerchantInfraCardForPosDashboard(wallet: w)
        let infra = merchantInfraCard
        // Admin gate first (chain `isAdmin` / `owner`) so revoke is applied before slower `getWalletAssets` / stats.
        await reconcileParentPermissionGateWithServer()

        // Home refresh: **trusted** = successful parse of remote data; **untrusted** = network/HTTP/body errors (`nil` / `ok: false`).
        // Untrusted results must not be interpreted as “no data” and must not clear in-memory state or UserDefaults cache.

        // Upper-admin capsule: prefer `getCardAdminInfo` root cached during trusted gate (same program card as `isAdmin` check); else one HTTP fetch.
        // Resolve admin EOA → profile with **global** `search-users` (not POS-filtered API), same as CoNET parent lookup.
        // Use `upperAdmin` only (no `owner` fallback).
        let infraLower = infra.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let pend = pendingGetCardAdminInfoRootForHome, pend.cardLower == infraLower {
            pendingGetCardAdminInfoRootForHome = nil
            let root = pend.root
            if let adminAddr = (root["upperAdmin"] as? String)?.nilIfEmpty, !adminAddr.isEmpty {
                if let adminProf = await api.searchUsers(keyward: adminAddr) {
                    adminProfile = adminProf
                    POSHomeScreenTrustedCache.saveAdmin(adminProf, wallet: w)
                }
            } else {
                adminProfile = nil
                POSHomeScreenTrustedCache.removeAdmin(wallet: w)
            }
        } else {
            pendingGetCardAdminInfoRootForHome = nil
            if let adminTuple = await api.fetchCardAdminInfo(cardAddress: infra, wallet: w) {
                if let adminAddr = adminTuple.upperAdmin?.nilIfEmpty, !adminAddr.isEmpty {
                    if let adminProf = await api.searchUsers(keyward: adminAddr) {
                        adminProfile = adminProf
                        POSHomeScreenTrustedCache.saveAdmin(adminProf, wallet: w)
                    }
                } else {
                    adminProfile = nil
                    POSHomeScreenTrustedCache.removeAdmin(wallet: w)
                }
            }
        }

        if let term = await api.searchUsers(keyward: w) {
            terminalProfile = term
            POSHomeScreenTrustedCache.saveTerminal(term, wallet: w)
        }

        let ast = await api.getWalletAssets(wallet: w, merchantInfraCard: infra, merchantInfraOnly: false, forPostPayment: false)
        if ast.ok {
            hasAAAccount = ast.aaAddress?.nilIfEmpty != nil
            homeMerchantProgramCardName = Self.merchantProgramMetadataDisplayName(from: ast, merchantInfraCard: infra)
        }

        let st = await api.fetchAdminStatsDayChargeAndTopUp(wallet: w, infraCard: infra)
        if st.charge != nil || st.topUp != nil {
            if let c = st.charge { cardChargeAmount = c }
            if let t = st.topUp { cardTopUpAmount = t }
            POSHomeScreenTrustedCache.mergeAndSaveStats(wallet: w, infraCard: infra, charge: st.charge, topUp: st.topUp)
        }
        homeStatsLoaded = true

        if let r = await api.fetchInfraRoutingSummary(wallet: w, infraCard: infra) {
            infraRoutingTaxPercent = r.tax
            infraRoutingDiscountSummary = r.discountSummary
            POSHomeScreenTrustedCache.saveRouting(wallet: w, infraCard: infra, tax: r.tax, summary: r.discountSummary)
        }

        await refreshPosTerminalReloadQuotaFromChain(wallet: w, infraCard: infra)

        if looksLikeAddress(infra) {
            programRechargeBonusRules = await api.fetchProgramRechargeBonusRules(cardAddress: infra)
        } else {
            programRechargeBonusRules = []
        }
    }

    /// `getAdminAirdropLimit` + cumulative `mintCounterFromClear` — aligns with biz Terminal Onboarding reload cap.
    private func refreshPosTerminalReloadQuotaFromChain(wallet: String, infraCard: String) async {
        let infra = infraCard.trimmingCharacters(in: .whitespacesAndNewlines)
        guard looksLikeAddress(infra) else { return }
        if let q = await api.fetchPosTerminalReloadQuota(posWallet: wallet, programCard: infra) {
            posTerminalReloadQuota = q
        }
    }

    private func posTopupMethodRawAllowed(_ methodRaw: String) -> Bool {
        let r = methodRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch r {
        case "cash": return posTerminalPolicy.allowTopupCash
        case "creditCard": return posTerminalPolicy.allowTopupBankCard
        case "usdc": return posTerminalPolicy.allowTopupUsdc
        case "bonus": return posTerminalPolicy.allowTopupAirdrop
        default: return false
        }
    }

    /// Block when total top-up display amount exceeds remaining mint budget (same ~CAD scaling as biz staff terminal stats).
    private func validateTopupAgainstReloadQuota(totalAmountDisplay: Double) -> String? {
        guard let q = posTerminalReloadQuota else { return nil }
        if q.unlimited { return nil }
        guard totalAmountDisplay > 0 else { return nil }
        let rem = max(0, q.remainingDisplay)
        if totalAmountDisplay > rem + 0.000_001 {
            let remStr = String(format: "%.2f", rem)
            return "This top-up exceeds the terminal reload limit (\(remStr) remaining)."
        }
        return nil
    }

    /// Charge / Top-up 成功展示后约 6s 自动再拉取首页数据（`refreshHomeProfiles`）。
    func scheduleHomeProfilesRefreshAfterTxSuccess() {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            await refreshHomeProfiles()
        }
    }

    func copyWalletToPasteboard() {
        guard let w = walletAddress else { return }
        UIPasteboard.general.string = w
    }

    func refreshInfraCardFromDbIfPossible() async {
        guard let w = walletAddress else { return }
        guard let b = await api.fetchMyPosBinding(wallet: w), looksLikeAddress(b.cardAddress) else { return }
        posTerminalPolicy = b.policy
        adoptMerchantInfraCardForHome(wallet: w, addr: b.cardAddress, replaceDisplayValues: true)
    }

    private func payerUsdcBalance6ForChargePolicy(assets: UIDAssets) -> Int64 {
        let raw = Int64(((Double(assets.usdcBalance ?? "0") ?? 0) * 1_000_000.0).rounded())
        return posTerminalPolicy.allowPayerUsdcInCharge ? raw : 0
    }

    /// When Cluster has not bound this POS yet (`myPosAddress` empty), pick the first factory `cardsOfOwner` card where this wallet is `owner` or `isAdmin` so Home stats / `getWalletAssets` target the real program card (default constant is often wrong).
    private func ensureMerchantInfraCardForPosDashboard(wallet w: String) async {
        if let b = await api.fetchMyPosBinding(wallet: w), looksLikeAddress(b.cardAddress) {
            posTerminalPolicy = b.policy
            adoptMerchantInfraCardForHome(wallet: w, addr: b.cardAddress, replaceDisplayValues: true)
            return
        }
        let cards = await api.fetchMyCardAddresses(ownerEoa: w)
        for raw in cards {
            guard looksLikeAddress(raw) else { continue }
            if let allowed = await api.fetchPosProgramCardHomeAccessAllowed(cardAddress: raw, wallet: w), allowed {
                adoptMerchantInfraCardForHome(wallet: w, addr: raw, replaceDisplayValues: true)
                return
            }
        }
    }

    func beginReadBalance() {
        pendingScanAction = .read
        scanQrCameraArmed = false
        scanAwaitingNfcTap = true
        resetReadQrChrome()
        readQrResetId += 1
        scanMethod = .nfc
        sheet = .scan(.read)
        startNfcIfNeeded()
    }

    func beginTopUp() {
        pendingScanAction = .topup
        scanQrCameraArmed = false
        scanAwaitingNfcTap = true
        resetTopupQrChrome()
        topupQrResetId += 1
        scanMethod = .nfc
        sheet = .scan(.topup)
        startNfcIfNeeded()
    }

    func beginCharge(amount: String, tipBps: Int) {
        amountString = amount
        chargeTipRateBps = tipBps
        pendingScanAction = .payment
        scanQrCameraArmed = false
        scanAwaitingNfcTap = true
        resetPaymentQrChrome()
        qrPaymentResetId += 1
        scanMethod = .nfc
        sheet = .scan(.payment)
        startNfcIfNeeded()
    }

    func beginLinkApp() {
        pendingScanAction = .linkApp
        scanQrCameraArmed = false
        scanAwaitingNfcTap = true
        scanMethod = .nfc
        linkDeepLink = ""
        linkLockedSun = nil
        showLinkCancel = false
        sheet = .scan(.linkApp)
        startNfcIfNeeded()
    }

    private func startNfcIfNeeded() {
        guard scanMethod == .nfc else { return }
        scanBanner = "Hold the customer's NTAG 424 DNA card near the NFC sensor."
        nfc.begin()
    }

    func onQrScanned(_ text: String) async {
        switch pendingScanAction {
        case .payment:
            await handlePaymentQr(text)
        case .read:
            await handleReadOrTopupQr(text, mode: .read)
        case .topup:
            await handleReadOrTopupQr(text, mode: .topup)
        case .linkApp:
            scanBanner = "Link App works with NFC only."
        }
    }

    enum QrReadMode { case read, topup }

    /// Android `Uri.parse` + QR payloads: trim BOM/whitespace; if bare string fails, detect first http(s) link.
    private static func beamioCustomerLinkURL(from raw: String) -> URL? {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("\u{FEFF}") { trimmed = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines) }
        if let u = URL(string: trimmed), u.scheme == "http" || u.scheme == "https" { return u }
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let ns = trimmed as NSString
        let range = NSRange(location: 0, length: ns.length)
        guard let detector, let m = detector.firstMatch(in: trimmed, options: [], range: range),
              m.resultType == .link,
              let u = m.url,
              u.scheme == "http" || u.scheme == "https"
        else { return nil }
        return u
    }

    private func handleReadOrTopupQr(_ text: String, mode: QrReadMode) async {
        let url = Self.beamioCustomerLinkURL(from: text)
        let beamio = url.flatMap { BeamioOpenContainerQR.parseBeamioTab(from: $0) }
        let wallet = url.flatMap { BeamioOpenContainerQR.parseBeamioWallet(from: $0) }
        guard beamio != nil || wallet != nil else {
            if mode == .topup {
                // Android `handleQrScanResult`: both nil → `Cannot parse URL. Please scan a beamio.app link` (same for topup/read before branch)
                topupQrExecuteError = "Cannot parse URL. Please scan a beamio.app link"
                topupQrSigningInProgress = false
                topupQrResetId += 1
            } else {
                readQrExecuteError = "Cannot parse URL. Please scan a beamio.app link"
                readQrResetId += 1
            }
            return
        }
        if mode == .read {
            readQrExecuteError = nil
            readQrFetchingInProgress = true
            readQrResetId += 1
            await refreshInfraCardFromDbIfPossible()
            let assets: UIDAssets
            let rawJson: String?
            if let beamio {
                (assets, rawJson) = await api.getUIDAssetsWithRawJson(uid: beamio, sun: nil, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false)
            } else {
                (assets, rawJson) = await api.getWalletAssetsWithRawJson(wallet: wallet!, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false, forPostPayment: false)
            }
            readQrFetchingInProgress = false
            if assets.ok {
                lastReadAssets = assets
                lastReadRawJson = rawJson
                lastReadViaQr = true
                lastReadError = nil
                sheet = .readResult
                await refreshInfraCardFromDbIfPossible()
            } else {
                lastReadError = assets.error ?? "Query failed"
                readQrExecuteError = lastReadError
                readQrResetId += 1
            }
            return
        }

        // Top-up via QR (Android: close camera, `topupQrSigningInProgress`, no prefetch before prepare)
        topupQrSigningInProgress = true
        topupQrExecuteError = nil
        topupQrResetId += 1
        topupQrLastBeamioTag = beamio
        topupQrLastWallet = wallet
        if let b = beamio?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty {
            let t = b.hasPrefix("@") ? String(b.dropFirst()).trimmingCharacters(in: .whitespaces) : b
            topupQrCustomerHint = t.isEmpty ? "" : "@\(t)"
        } else if let w = wallet?.trimmingCharacters(in: .whitespacesAndNewlines), w.count >= 10 {
            topupQrCustomerHint = "\(w.prefix(6))…\(w.suffix(4))"
        } else {
            topupQrCustomerHint = ""
        }
        guard let key = walletPrivateKeyHex else {
            topupQrSigningInProgress = false
            topupQrExecuteError = "Wallet not initialized"
            return
        }
        await refreshInfraCardFromDbIfPossible()
        if let beamio {
            await runTopup(beamioTag: beamio, wallet: nil, privateKeyHex: key, topupFromQr: true)
        } else if let wallet {
            await runTopup(beamioTag: nil, wallet: wallet, privateKeyHex: key, topupFromQr: true)
        }
    }

    private func handlePaymentQr(_ text: String) async {
        paymentQrParseError = nil
        paymentTerminalError = nil
        let subtotal = Double(amountString) ?? 0
        guard subtotal > 0 else {
            paymentTerminalError = "Please enter amount first"
            return
        }
        guard walletAddress != nil else {
            paymentTerminalError = "Wallet not initialized"
            return
        }
        paymentQrInterpreting = true
        let parsed = BeamioOpenContainerQR.parse(text)
        guard var payload = parsed.payload else {
            paymentQrInterpreting = false
            paymentQrParseError = humanizeQrError(parsed.rejectReason ?? "unknown")
            return
        }
        let w = walletAddress!
        await refreshInfraCardFromDbIfPossible()
        let account = (payload["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !account.isEmpty else {
            paymentQrInterpreting = false
            paymentTerminalError = "Invalid payment code"
            return
        }
        paymentQrInterpreting = false
        isNfcBusy = true
        scanBanner = "Routing payment..."
        paymentRoutingSteps = Self.makeInitialPaymentRoutingSteps()
        paymentPatchStep(id: "detectingUser", status: .loading)
        paymentPatchStep(id: "detectingUser", status: .success, detail: "Dynamic QR detected")
        paymentPatchStep(id: "membership", status: .loading)

        let assets = await api.getWalletAssets(wallet: account, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false, forPostPayment: false)
        guard assets.ok else {
            paymentPatchStep(id: "membership", status: .error, detail: "")
            isNfcBusy = false
            scanBanner = ""
            let msg = assets.error ?? "Unable to fetch customer assets"
            paymentTerminalError = msg
            return
        }

        let hasCardholder =
            (assets.cards?.contains { (Int64($0.points6) ?? 0) > 0 } == true)
            || ((Int64(assets.points6 ?? "0") ?? 0) > 0)
        paymentPatchStep(id: "membership", status: .success, detail: hasCardholder ? "Cardholder" : "No membership")
        paymentPatchStep(id: "analyzingAssets", status: .loading)

        let payeeWallet = w
        let routingDetails = await api.fetchChargeTierRoutingDetails(wallet: payeeWallet, infraCard: merchantInfraCard)
        let taxP = routingDetails?.taxPercent ?? infraRoutingTaxPercent ?? 0.0
        let payCard = assets.cards?.first
        let metaBundle = await api.fetchCardMetadataTiersBundle(cardAddress: payCard?.cardAddress)
        let disc = BeamioPaymentRouting.pickChargeTierDiscountPercent(
            paymentCard: payCard,
            assets: assets,
            discountByTierKey: routingDetails?.discountByTierKey ?? [:],
            metadataTiers: metaBundle.rows,
            metadataTiersFromApi: metaBundle.fromApi
        )

        let oracle = await api.fetchOracle().toPaymentOracle()
        let request = subtotal
        let tip = BeamioPaymentRouting.chargeTipFromRequestAndBps(requestAmount: request, tipRateBps: chargeTipRateBps)
        let total = BeamioPaymentRouting.chargeTotalInCurrency(requestAmount: request, taxPercent: taxP, tierDiscountPercent: disc, tipAmount: tip)
        let payCurrency = payCard?.cardCurrency ?? assets.cardCurrency ?? "CAD"
        let amountUsdc6 = BeamioPaymentRouting.currencyToUsdc6(amount: total, currency: payCurrency, oracle: oracle)
        guard amountUsdc6 != "0", let entered = Int64(amountUsdc6), entered > 0 else {
            paymentPatchStep(id: "analyzingAssets", status: .error, detail: "Amount conversion failed")
            isNfcBusy = false
            scanBanner = ""
            paymentTerminalError = "Amount conversion failed"
            return
        }
        let unitPriceStr = assets.unitPriceUSDC6 ?? "0"
        let unitPrice = Int64(unitPriceStr) ?? 0
        let cards = BeamioPaymentRouting.chargeableCards(from: assets, infraCard: merchantInfraCard)
        let partQr = BeamioPaymentRouting.partitionPointsForMerchantCharge(cards: cards, merchantInfraCard: merchantInfraCard)
        let unitPoints6 = partQr.unitPricePoints6
        let oracleInfraCardsQr = partQr.oracleInfraCards
        let infraPoints6 = oracleInfraCardsQr.reduce(0) { $0 + (Int64($1.points6) ?? 0) }
        let usdcBal = payerUsdcBalance6ForChargePolicy(assets: assets)
        let unitBucketUsdc6 = (unitPoints6 > 0 && unitPrice > 0) ? (unitPoints6 * unitPrice) / 1_000_000 : 0
        let infraValue = oracleInfraCardsQr.reduce(0) { partial, c in
            partial + BeamioPaymentRouting.points6ToUsdc6(points6: Int64(c.points6) ?? 0, cardCurrency: c.cardCurrency, oracle: oracle)
        }
        let totalBal = unitBucketUsdc6 + infraValue + usdcBal

        let analyzingDetail: String
        if unitBucketUsdc6 >= entered {
            analyzingDetail = "Program points (sufficient)"
        } else if unitBucketUsdc6 > 0 {
            analyzingDetail = "Program points (partial)"
        } else {
            analyzingDetail = "USDC sufficient"
        }
        paymentPatchStep(id: "analyzingAssets", status: .success, detail: analyzingDetail)
        paymentPatchStep(id: "optimizingRoute", status: .loading)

        guard totalBal >= entered else {
            paymentPatchStep(id: "optimizingRoute", status: .error, detail: "Insufficient balance")
            presentChargeInsufficientFunds(
                assets: assets,
                payCard: payCard,
                payCurrency: payCurrency,
                chargeTotalInPayCurrency: total,
                subtotal: request,
                tip: tip,
                taxPercent: taxP,
                tierDiscountPercent: disc,
                requiredUsdc6: entered,
                availableUsdc6: totalBal,
                settlementViaQr: true,
                nfcRetryUid: nil,
                nfcRetrySun: nil,
                qrRetryAccount: account,
                qrRetryPayload: payload
            )
            return
        }

        let split = BeamioPaymentRouting.computeChargeContainerSplit(
            amountBig: entered,
            chargeTotalInPayCurrency: total,
            payCurrency: payCurrency,
            oracle: oracle,
            unitPriceUSDC6: unitPrice,
            ccsaPoints6: unitPoints6,
            infraPoints6: infraPoints6,
            infraCardCurrency: oracleInfraCardsQr.first?.cardCurrency,
            usdcBalance6: usdcBal
        )
        var items = BeamioPaymentRouting.buildPayItems(amountUsdc6: amountUsdc6, split: split, infraCard: merchantInfraCard)
        items = BeamioPaymentRouting.mergeInfraKind1Items(items, infraCard: merchantInfraCard)
        let beamio1155Wei = mergedInfraKind1Amount(from: items, infraCard: merchantInfraCard)
        let usdcWei = firstUsdcAmount6(from: items)
        let routeDetail: String
        if beamio1155Wei > 0, usdcWei > 0 {
            routeDetail = "Hybrid: points + USDC"
        } else if beamio1155Wei > 0 {
            routeDetail = "Points only"
        } else {
            routeDetail = "USDC only"
        }
        paymentPatchStep(id: "optimizingRoute", status: .success, detail: routeDetail)

        payload["items"] = items
        if payload["maxAmount"] == nil { payload["maxAmount"] = "0" }
        if payload["deadline"] == nil, let vb = payload["validBefore"] { payload["deadline"] = vb }
        let terminalAssets = await api.getWalletAssets(wallet: payeeWallet, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false, forPostPayment: false)
        let toAA = terminalAssets.aaAddress?.nilIfEmpty ?? (payload["to"] as? String)
        guard let toAA, looksLikeAddress(toAA) else {
            paymentPatchStep(id: "sendTx", status: .error, detail: "Merchant AA not found")
            isNfcBusy = false
            scanBanner = ""
            paymentTerminalError = "Merchant AA not found. Please ensure terminal is configured."
            return
        }
        payload["to"] = toAA
        let currencyAmountStr = String(format: "%.2f", total)
        let taxAmt = request * taxP / 100.0
        let taxFiat6 = Int64((taxAmt * 1_000_000.0).rounded())
        let taxBps = min(10_000, max(0, Int((taxP * 100.0).rounded())))
        let discAmt = request * BeamioPaymentRouting.normalizeTierDiscountPercent(disc) / 100.0
        let discFiat6 = Int64((discAmt * 1_000_000.0).rounded())
        let discBps = BeamioPaymentRouting.tierDiscountBasisPoints(disc)
        let bill: [String: Any] = [
            "nfcSubtotalCurrencyAmount": String(format: "%.2f", request),
            "nfcRequestCurrency": payCurrency,
            "nfcTaxAmountFiat6": String(taxFiat6),
            "nfcTaxRateBps": taxBps,
            "nfcDiscountAmountFiat6": String(discFiat6),
            "nfcDiscountRateBps": discBps,
        ].merging(
            tip > 0
                ? [
                    "nfcTipCurrencyAmount": String(format: "%.2f", tip),
                    "nfcTipRateBps": chargeTipRateBps,
                ]
                : [:],
            uniquingKeysWith: { $1 }
        )

        paymentPatchStep(id: "sendTx", status: .loading)
        let res = await api.postAAtoEOA(
            openContainerPayload: payload,
            currency: payCurrency,
            currencyAmount: currencyAmountStr,
            merchantInfraCard: merchantInfraCard,
            chargeBill: bill
        )
        if res.success {
            paymentPatchStep(id: "sendTx", status: .success, detail: "Sent")
            paymentPatchStep(id: "waitTx", status: .success, detail: "Transaction complete")
            paymentPatchStep(id: "refreshBalance", status: .loading, detail: "Fetching latest balance")
        } else {
            let msg = res.error ?? "Payment failed"
            paymentPatchStep(id: "sendTx", status: .error, detail: msg)
            paymentPatchStep(id: "waitTx", status: .error, detail: "")
            isNfcBusy = false
            scanBanner = ""
            paymentTerminalError = msg
            homeToast = msg
            return
        }
        let useInfraPost = split.ccsaPointsWei + split.infraPointsWei > 0
        let mNo = assets.memberNoPrimaryFromSortedCards().nilIfEmpty
        await completePaymentSuccessUi(
            amountTotal: total,
            payee: toAA,
            txHash: res.txHash,
            subtotal: request,
            tip: tip,
            payCurrency: payCurrency,
            memberNo: mNo,
            passCard: payCard,
            cardName: payCard?.cardName,
            tierName: payCard?.tierName,
            cardType: payCard?.cardType,
            settlementViaQr: true,
            taxPercent: taxP,
            tierDiscountPercent: disc,
            useInfraCardPostBalance: useInfraPost,
            inlineInSheet: true,
            fetchPostAssets: {
                await self.api.getWalletAssets(
                    wallet: account,
                    merchantInfraCard: self.merchantInfraCard,
                    merchantInfraOnly: false,
                    forPostPayment: true
                )
            }
        )
    }

    private static func makeInitialPaymentRoutingSteps() -> [PaymentRoutingStepRow] {
        [
            .init(id: "detectingUser", label: "Detecting User", detail: "", status: .pending),
            .init(id: "membership", label: "Checking Membership", detail: "", status: .pending),
            .init(id: "analyzingAssets", label: "Analyzing Assets", detail: "", status: .pending),
            .init(id: "optimizingRoute", label: "Optimizing Route", detail: "", status: .pending),
            .init(id: "sendTx", label: "Sending transaction", detail: "", status: .pending),
            .init(id: "waitTx", label: "Waiting for transaction", detail: "", status: .pending),
            .init(id: "refreshBalance", label: "Refreshing balance", detail: "", status: .pending),
        ]
    }

    private func paymentPatchStep(id: String, status: PaymentRoutingStepStatus, detail: String = "") {
        paymentRoutingSteps = paymentRoutingSteps.map { row in
            guard row.id == id else { return row }
            let d = detail.isEmpty ? row.detail : detail
            return PaymentRoutingStepRow(id: row.id, label: row.label, detail: d, status: status)
        }
    }

    /// Sum kind==1 amounts for infra ERC1155 after merge (Android `beamio1155PointsWei`).
    private func mergedInfraKind1Amount(from items: [[String: Any]], infraCard: String) -> Int64 {
        let infra = infraCard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var sum: Int64 = 0
        for it in items {
            guard (it["kind"] as? Int) == 1 else { continue }
            let asset = ((it["asset"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard asset == infra else { continue }
            sum += Int64((it["amount"] as? String) ?? "") ?? 0
        }
        return sum
    }

    private func firstUsdcAmount6(from items: [[String: Any]]) -> Int64 {
        for it in items {
            guard (it["kind"] as? Int) == 0 else { continue }
            return Int64((it["amount"] as? String) ?? "") ?? 0
        }
        return 0
    }

    func retryPaymentQrParse() {
        paymentQrParseError = nil
        qrPaymentResetId += 1
    }

    func retryPaymentAfterTerminalError() {
        paymentTerminalError = nil
        paymentRoutingSteps = []
        scanBanner = ""
        chargeNfcReadError = nil
        isNfcBusy = false
        qrPaymentResetId += 1
        if pendingScanAction == .payment, scanMethod == .nfc {
            scanAwaitingNfcTap = true
            nfc.begin()
        }
    }

    /// Top-up + QR: Android `retryTopupQrExecute` — re-run prepare/sign/post with last scanned link.
    func retryTopupQrExecute() {
        guard topupQrExecuteError != nil, !(topupQrExecuteError ?? "").isEmpty else { return }
        if topupQrLastBeamioTag == nil && topupQrLastWallet == nil {
            topupQrExecuteError = nil
            topupQrResetId += 1
            return
        }
        topupQrExecuteError = nil
        topupQrSigningInProgress = true
        topupQrResetId += 1
        guard let key = walletPrivateKeyHex else {
            topupQrSigningInProgress = false
            topupQrExecuteError = "Wallet not initialized"
            return
        }
        Task { @MainActor in
            await refreshInfraCardFromDbIfPossible()
            if let tag = topupQrLastBeamioTag {
                await runTopup(beamioTag: tag, wallet: nil, privateKeyHex: key, topupFromQr: true)
            } else if let w = topupQrLastWallet {
                await runTopup(beamioTag: nil, wallet: w, privateKeyHex: key, topupFromQr: true)
            } else {
                topupQrSigningInProgress = false
                topupQrExecuteError = "Missing customer link. Scan QR again."
            }
        }
    }

    func dismissChargeApprovedInline() {
        chargeApprovedInline = nil
        paymentRoutingSteps = []
        scanBanner = ""
        isNfcBusy = false
        nfc.invalidate()
        sheet = nil
        Task { @MainActor in
            await refreshHomeProfiles()
        }
    }

    private func resetPaymentQrChrome() {
        paymentQrInterpreting = false
        paymentQrParseError = nil
        paymentRoutingSteps = []
        paymentTerminalError = nil
        chargeApprovedInline = nil
        chargeNfcReadError = nil
    }

    private func resetTopupQrChrome() {
        topupQrSigningInProgress = false
        topupQrExecuteError = nil
        topupNfcReadError = nil
        topupQrLastBeamioTag = nil
        topupQrLastWallet = nil
        topupQrCustomerHint = ""
        topupExecuteDisplayTotal = nil
        topupExecuteDisplayBonus = nil
    }

    private func resetReadQrChrome() {
        readQrFetchingInProgress = false
        readQrExecuteError = nil
    }

    /// Check Balance: dismiss error and reopen NFC wait or QR camera (matches `scanMethod`).
    func retryReadQrAfterError() {
        guard readQrExecuteError != nil, !(readQrExecuteError ?? "").isEmpty else { return }
        readQrExecuteError = nil
        readQrResetId += 1
        guard pendingScanAction == .read else { return }
        if scanMethod == .nfc {
            scanQrCameraArmed = false
            scanAwaitingNfcTap = true
            nfc.begin()
        }
    }

    /// Top-up + NFC: same tap-to-retry as Check Balance after NFC read / execute prep failure.
    func retryTopupNfcAfterScanBannerError() {
        guard pendingScanAction == .topup else { return }
        scanBanner = ""
        topupNfcReadError = nil
        topupQrResetId += 1
        scanQrCameraArmed = false
        scanMethod = .nfc
        scanAwaitingNfcTap = true
        nfc.begin()
    }

    /// Charge + NFC: tap-to-retry after NFC read failure or `scanBanner` error (align Check Balance).
    func retryPaymentNfcAfterScanBannerError() {
        guard pendingScanAction == .payment else { return }
        scanBanner = ""
        chargeNfcReadError = nil
        qrPaymentResetId += 1
        scanQrCameraArmed = false
        paymentQrParseError = nil
        scanMethod = .nfc
        scanAwaitingNfcTap = true
        nfc.begin()
    }

    private func humanizeQrError(_ r: String) -> String {
        if r.hasPrefix("not a JSON") { return "Invalid QR: data is not valid JSON." }
        if r.contains("missing or empty account") { return "Invalid QR: missing customer account." }
        if r.contains("missing or empty signature") { return "Invalid QR: missing payment signature." }
        if r.contains("neither open relay") { return "Invalid QR: unrecognized payment format." }
        return "Could not read payment code."
    }

    /// User closed the iOS NFC sheet → fall back to QR (Check Balance, Top-up, Charge). **Link App** is NFC-only: return Home.
    private func handleScanSheetNfcDismissedByUser() async {
        guard case .scan = sheet else { return }
        isNfcBusy = false
        scanAwaitingNfcTap = false
        if pendingScanAction == .linkApp {
            closeLinkAppScanReturnHome()
            return
        }
        // Defensive: tag read may have just set these; do not arm QR (would clear errors via `setScanMethod(.qr)`).
        switch pendingScanAction {
        case .payment:
            if let e = chargeNfcReadError, !e.isEmpty { return }
        case .topup:
            if let e = topupNfcReadError, !e.isEmpty { return }
        case .read:
            if let e = readQrExecuteError, !e.isEmpty { return }
        case .linkApp:
            return
        }
        await armScanQrCameraAfterUserDismissedNfc()
    }

    /// Tag reading not available (`readingAvailable` false) → QR fallback (Check Balance, Top-up, Charge). **Link App** returns Home.
    private func handleScanNfcReadingUnavailable() async {
        guard case .scan = sheet else { return }
        isNfcBusy = false
        scanAwaitingNfcTap = false
        if pendingScanAction == .linkApp {
            closeLinkAppScanReturnHome(
                message: "NFC is turned off or unavailable. Link App requires NFC."
            )
            return
        }
        await armScanQrCameraFromNfcFallback()
    }

    /// Link App has no QR workflow — dismiss scan sheet and reset link state (return to Home).
    private func closeLinkAppScanReturnHome(message: String? = nil) {
        guard pendingScanAction == .linkApp else { return }
        linkDeepLink = ""
        linkLockedSun = nil
        showLinkCancel = false
        closeScanSheet()
        if let message, !message.isEmpty {
            homeToast = message
        }
    }

    /// After user dismisses NFC we may restart NFC if camera is denied (`readingAvailable` is typically still true).
    private func armScanQrCameraAfterUserDismissedNfc() async {
        let ok = await requestCameraIfNeeded()
        if ok {
            setScanMethod(.qr)
            scanQrCameraArmed = true
        } else {
            homeToast = "Camera access denied"
            scanQrCameraArmed = false
            setScanMethod(.nfc)
            nfc.begin()
        }
    }

    /// NFC cannot run — open QR; do not loop `nfc.begin()` when both NFC and camera are unusable.
    private func armScanQrCameraFromNfcFallback() async {
        if pendingScanAction == .linkApp {
            closeLinkAppScanReturnHome(
                message: "NFC is turned off or unavailable. Link App requires NFC."
            )
            return
        }
        let ok = await requestCameraIfNeeded()
        if ok {
            setScanMethod(.qr)
            scanQrCameraArmed = true
        } else {
            homeToast = "Camera access denied"
            scanQrCameraArmed = false
            scanMethod = .nfc
            scanAwaitingNfcTap = false
            scanBanner = "Hold the customer's NTAG 424 DNA card near the NFC sensor."
            if NFCTagReaderSession.readingAvailable {
                nfc.begin()
            } else if pendingScanAction == .read {
                readQrExecuteError = "NFC is not available on this device. Allow camera access to scan the customer's link."
                readQrResetId += 1
            } else {
                scanBanner = "NFC is not available. Allow camera access to scan a QR code."
            }
        }
    }

    /// User-visible NFC tag read failure (English UI). System sheet has already closed.
    private func nfcTagReadErrorMessage(from err: Error) -> String {
        let d = err.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        if d.isEmpty { return "NFC read error. Please try again." }
        return "NFC read error. \(d)"
    }

    /// NFC flow detail lines for Top-up / Charge (avoid double `NFC read error.` prefix).
    private func nfcFlowErrorMessage(detail: String) -> String {
        let t = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return "NFC read error. Please try again." }
        if t.lowercased().hasPrefix("nfc read error.") { return t }
        return "NFC read error. \(t)"
    }

    private func handleNfcResult(_ result: Result<(url: URL, raw: String), Error>) async {
        guard let open = sheet, case .scan = open else { return }
        switch result {
        case let .failure(err):
            isNfcBusy = false
            // Tag read / NDEF errors: stay on NFC, show tap-to-retry (Charge/Top-up/Read). Do not auto-open QR —
            // QR is only armed when the user **dismisses** the system NFC sheet (`handleScanSheetNfcDismissedByUser`)
            // or when the device cannot read tags at all (`handleScanNfcReadingUnavailable`).
            scanQrCameraArmed = false
            scanMethod = .nfc
            scanAwaitingNfcTap = false
            let msg = nfcTagReadErrorMessage(from: err)
            switch pendingScanAction {
            case .read:
                readQrExecuteError = msg
                readQrResetId += 1
            case .topup:
                topupNfcReadError = msg
                topupQrResetId += 1
            case .payment:
                chargeNfcReadError = msg
                qrPaymentResetId += 1
            case .linkApp:
                scanBanner = msg
            }
        case let .success(pair):
            let url = pair.url
            await refreshInfraCardFromDbIfPossible()
            switch pendingScanAction {
            case .read:
                await handleNfcRead(url: url)
            case .topup:
                await handleNfcTopup(url: url)
            case .payment:
                await handleNfcPayment(url: url)
            case .linkApp:
                await handleNfcLinkApp(url: url)
            }
        }
    }

    private func handleNfcRead(url: URL) async {
        scanAwaitingNfcTap = false
        let sun = BeamioSunParser.sunParams(from: url)
        let uid =
            sun?.uid
            ?? BeamioSunParser.uidHexPreview(from: url)
            ?? ""
        guard !uid.isEmpty else {
            readQrExecuteError = "NFC read error. Cannot read UID from this card."
            readQrResetId += 1
            return
        }
        isNfcBusy = true
        scanBanner = "Querying..."
        defer {
            isNfcBusy = false
            scanBanner = ""
        }
        let (assets, rawJson) = await api.getUIDAssetsWithRawJson(uid: uid, sun: sun, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false)
        if assets.ok {
            lastReadAssets = assets
            lastReadRawJson = rawJson
            lastReadViaQr = false
            lastReadError = nil
            readQrExecuteError = nil
            sheet = .readResult
            await refreshInfraCardFromDbIfPossible()
        } else {
            lastReadError = assets.error ?? "Query failed"
            let detail = lastReadError ?? "Query failed"
            readQrExecuteError = "NFC read error. \(detail)"
            readQrResetId += 1
        }
    }

    private func handleNfcTopup(url: URL) async {
        scanAwaitingNfcTap = false
        topupNfcReadError = nil
        guard let key = walletPrivateKeyHex else {
            topupNfcReadError = nfcFlowErrorMessage(detail: "Wallet not initialized.")
            return
        }
        let sun = BeamioSunParser.sunParams(from: url)
        let uid =
            sun?.uid
            ?? BeamioSunParser.uidHexPreview(from: url)
            ?? ""
        guard let sun else {
            topupNfcReadError = nfcFlowErrorMessage(detail: "Card does not support SUN. Cannot top up.")
            return
        }
        guard !uid.isEmpty else {
            topupNfcReadError = nfcFlowErrorMessage(detail: "Cannot read UID from this card.")
            return
        }
        await runTopup(beamioTag: nil, wallet: nil, uid: uid, sun: sun, privateKeyHex: key, topupFromQr: false)
    }

    private func reportTopupFailure(_ message: String, topupFromQr: Bool, homeToast: Bool = false) {
        isNfcBusy = false
        topupExecuteDisplayTotal = nil
        topupExecuteDisplayBonus = nil
        if topupFromQr {
            topupQrSigningInProgress = false
            topupQrExecuteError = message
        } else {
            topupNfcReadError = nfcFlowErrorMessage(detail: message)
            scanBanner = ""
        }
        if homeToast {
            self.homeToast = message
        }
    }

    /// Matches membership NFT convention (`NFT_START_ID`); unexpired row on the program card ⇒ treated as member for top-up threshold checks.
    private static let beamioMembershipNftMinTokenId: Int64 = 100

    /// Mirrors `_hasValidCard` semantics close enough for preflight: any **non-expired** program-card membership NFT ⇒ not “non-member” for `UC_BelowMinThreshold`.
    private static func cardHasValidMembershipForTopup(_ card: CardItem?) -> Bool {
        guard let card else { return false }
        let primary = card.primaryMemberTokenId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if let p = Int64(primary), p > 0 {
            if let nft = card.nfts.first(where: {
                $0.tokenId == primary || $0.tokenId.caseInsensitiveCompare(primary) == .orderedSame
            }) {
                return !nft.isExpired
            }
            return true
        }
        for nft in card.nfts {
            let tid = Int64(nft.tokenId) ?? 0
            if tid >= beamioMembershipNftMinTokenId, !nft.isExpired {
                return true
            }
        }
        return false
    }

    /// Before sign/submit: **only without valid membership** — minted `points6` must be ≥ lowest tier `minUsdc6` (`_requirePointsMintAllowsFirstMembership`). When input currency matches on-chain card currency, uses `ceil(amountCurrency6 * 1e6 / pointsUnitPriceInCurrencyE6)` like `MemberCard.nfcTopupPreparePayload` — **not** oracle `currencyToUsdc6` vs tier (wrong units). If chain read fails or currencies differ, skip local check (server/chain still enforce).
    private func validateTopupMeetsMinimumTierForNonMember(
        amountStr: String,
        cardAddr: String,
        preCard: CardItem?,
        currency: String,
        customerAa: String? = nil
    ) async -> String? {
        guard let amt = Double(amountStr), amt > 0 else { return nil }
        guard !Self.cardHasValidMembershipForTopup(preCard) else { return nil }
        if let aa = customerAa?.trimmingCharacters(in: .whitespacesAndNewlines), !aa.isEmpty,
           await api.chainHasValidMembershipForTopup(programCard: cardAddr, userAa: aa) {
            return nil
        }
        let bundle = await api.fetchCardMetadataTiersBundle(cardAddress: cardAddr)
        let rows = bundle.rows
        guard !rows.isEmpty else { return nil }
        let minU = rows.map(\.minUsdc6).min() ?? 0
        guard minU > 0 else { return nil }

        let ccy = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let amtMicro = (amt * 1_000_000.0).rounded(.towardZero)
        guard amtMicro.isFinite, amtMicro > 0, amtMicro <= Double(Int64.max) else { return nil }
        let amountCurrency6 = Int64(amtMicro)
        guard amountCurrency6 > 0 else { return nil }

        guard let chain = await api.fetchBeamioUserCardCurrencyCodeAndPointsUnitPriceE6(cardAddress: cardAddr),
              chain.code.uppercased() == ccy
        else { return nil }

        let priceE6 = chain.priceE6
        guard priceE6 > 0 else { return nil }

        let ac6 = UInt64(amountCurrency6)
        let prodMul = ac6.multipliedReportingOverflow(by: 1_000_000)
        guard !prodMul.overflow else { return nil }
        let topPoints6 = Self.topupCeilDivUInt64(prodMul.partialValue, priceE6)
        guard topPoints6 < UInt64(minU) else { return nil }

        let minPayCur6 = Self.decimalCeilDiv(Decimal(minU) * Decimal(priceE6), Decimal(1_000_000))
        let minPayDec = minPayCur6 / Decimal(1_000_000)
        let minPay = Double(truncating: NSDecimalNumber(decimal: minPayDec))
        let nf = NumberFormatter()
        nf.numberStyle = .decimal
        nf.minimumFractionDigits = 2
        nf.maximumFractionDigits = 2
        nf.locale = Locale(identifier: "en_US")
        let minFormatted = nf.string(from: NSNumber(value: minPay)) ?? String(format: "%.2f", minPay)
        return "No active membership for this customer. Top-up must be at least \(minFormatted) \(ccy) (first tier minimum for this card)."
    }

    private static func topupCeilDivUInt64(_ a: UInt64, _ b: UInt64) -> UInt64 {
        guard b > 0 else { return 0 }
        return (a + b - 1) / b
    }

    private static func decimalCeilDiv(_ numerator: Decimal, _ denominator: Decimal) -> Decimal {
        guard numerator >= 0, denominator > 0 else { return 0 }
        let one = Decimal(1)
        return (numerator + denominator - one) / denominator
    }

    /// Android `executeWalletTopupInternal`: first `getWalletAssets`; on failure `ensureAaForEoaSync` then retry once.
    private func getWalletAssetsForTopupWithEnsureAA(wallet: String, infra: String) async -> UIDAssets {
        var assets = await api.getWalletAssets(
            wallet: wallet,
            merchantInfraCard: infra,
            merchantInfraOnly: false,
            forPostPayment: false
        )
        if !assets.ok {
            _ = await api.ensureAAForEOA(eoa: wallet)
            assets = await api.getWalletAssets(
                wallet: wallet,
                merchantInfraCard: infra,
                merchantInfraOnly: false,
                forPostPayment: false
            )
        }
        return assets
    }

    /// Cleared only when top-up completes successfully (not when closing the scan sheet — QR retry must keep pad semantics).
    private func clearPendingTopupPadAccountingParams() {
        pendingTopupMethodRaw = ""
        pendingTopupBonusExpanded = false
        pendingTopupBonusRatePercent = 20
        pendingTopupKeypadAmount = ""
    }

    private func resolveTopupMethodRawForSplit() -> String {
        let raw = pendingTopupMethodRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !raw.isEmpty { return raw }
        let title = topupPaymentMethodTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.caseInsensitiveCompare("Cash") == .orderedSame { return "cash" }
        if title.caseInsensitiveCompare("Bonus") == .orderedSame { return "bonus" }
        if title.caseInsensitiveCompare("USDC") == .orderedSame { return "usdc" }
        return "creditCard"
    }

    /// Rebuild split for every `/api/nfcTopup` (NFC or QR) so closing the scan sheet does not drop indexer legs.
    private func resolvedNfcTopupCurrencySplit(forApiTotalAmount amt: String) -> NfcTopupCurrencySplit? {
        let normalizedAmt = amt.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        let keypadStored = pendingTopupKeypadAmount.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        let keypadBase = keypadStored.isEmpty ? normalizedAmt : keypadStored
        let methodRaw = resolveTopupMethodRawForSplit()
        if let s = BeamioAPIClient.nfcTopupCurrencySplitFromPosKeypad(
            keypadAmount: keypadBase,
            methodRaw: methodRaw,
            bonusExpanded: pendingTopupBonusExpanded,
            selectedBonusRate: pendingTopupBonusRatePercent
        ) {
            return s
        }
        return BeamioAPIClient.nfcTopupCurrencySplitAllCard(amount: normalizedAmt)
    }

    /// Keypad / QR principal used to match `BeamioRechargeBonusRule.paymentAmount` (before promo bump).
    private func topupKeypadPrincipalForBonusMatch(from amountStringVal: String) -> Double {
        let normalizedAmt = amountStringVal.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        let keypadStored = pendingTopupKeypadAmount.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "")
        let base = keypadStored.isEmpty ? normalizedAmt : keypadStored
        return Double(base) ?? 0
    }

    /// When `paymentPrincipal` is **≥** a rule’s `paymentAmount`, that tier qualifies; if several qualify, use the one with the **largest** `paymentAmount` (best tier). Same `bonusValue` is added to **actual** principal sent to the API.
    private func selectProgramRechargeBonusRule(forPaymentPrincipal paymentPrincipal: Double) -> BeamioRechargeBonusRule? {
        guard paymentPrincipal > 0, !programRechargeBonusRules.isEmpty else { return nil }
        let pay = (paymentPrincipal * 100).rounded() / 100
        let qualifying = programRechargeBonusRules.filter { r in
            let threshold = (r.paymentAmount * 100).rounded() / 100
            return pay + 1e-6 >= threshold
        }
        return qualifying.max(by: { $0.paymentAmount < $1.paymentAmount })
    }

    /// When keypad principal qualifies for a recharge tier (`>= paymentAmount`), API total = principal + fixed `bonusValue` or proportional `principal * (bonusValue / paymentAmount)` (biz `bonusProportional`). Skips if “Activate Bonus” or Bonus-only method.
    private func resolveTopupApiAmountAndSplit(keypadAmountString amt: String, methodRaw: String) -> (apiAmount: String, split: NfcTopupCurrencySplit?, programRechargeBonus: Double) {
        let defaultSplit = resolvedNfcTopupCurrencySplit(forApiTotalAmount: amt)
        if methodRaw == "bonus" || pendingTopupBonusExpanded {
            return (amt, defaultSplit, 0)
        }
        let principal = topupKeypadPrincipalForBonusMatch(from: amt)
        guard let rule = selectProgramRechargeBonusRule(forPaymentPrincipal: principal) else {
            return (amt, defaultSplit, 0)
        }
        let programBonus: Double = {
            if rule.bonusProportional {
                guard rule.paymentAmount > 1e-9 else { return 0 }
                let raw = principal * rule.bonusValue / rule.paymentAmount
                return (raw * 100).rounded() / 100
            }
            return rule.bonusValue
        }()
        if programBonus < 1e-9 {
            return (amt, defaultSplit, 0)
        }
        let total = principal + programBonus
        guard total > 0 else {
            return (amt, defaultSplit, 0)
        }
        let api = String(format: "%.2f", (total * 100).rounded() / 100)
        let split = BeamioAPIClient.nfcTopupCurrencySplitFromPosKeypad(
            keypadAmount: api,
            methodRaw: methodRaw,
            bonusExpanded: false,
            selectedBonusRate: 0
        ) ?? BeamioAPIClient.nfcTopupCurrencySplitAllCard(amount: api)
        return (api, split, programBonus)
    }

    private static func parseTopupSplitAmountField(_ raw: String?) -> Double {
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: "") ?? ""
        guard let v = Double(t), v.isFinite else { return 0 }
        return v
    }

    private func runTopup(beamioTag: String?, wallet: String?, uid: String? = nil, sun: SunParams? = nil, privateKeyHex: String, topupFromQr: Bool = false) async {
        topupExecuteDisplayTotal = nil
        topupExecuteDisplayBonus = nil
        let amt = amountString
        guard Double(amt) ?? 0 > 0 else {
            reportTopupFailure("Invalid amount", topupFromQr: topupFromQr)
            return
        }
        await refreshInfraCardFromDbIfPossible()
        let infra = merchantInfraCard
        let methodRaw = resolveTopupMethodRawForSplit()
        guard posTopupMethodRawAllowed(methodRaw) else {
            reportTopupFailure("This payment method is not enabled for this terminal. Ask the merchant to update device settings in Terminal Onboarding.", topupFromQr: topupFromQr)
            return
        }
        let (apiAmountString, currencySplit, programRechargeBonus) = resolveTopupApiAmountAndSplit(keypadAmountString: amt, methodRaw: methodRaw)
        let splitBonus = Self.parseTopupSplitAmountField(currencySplit?.bonusCurrencyAmount)
        let totalFromSplit = Self.parseTopupSplitAmountField(currencySplit?.currencyAmount)
        let apiParsed = Double(apiAmountString.replacingOccurrences(of: ",", with: "")) ?? 0
        let totalDisplay = totalFromSplit > 0 ? totalFromSplit : apiParsed
        let bonusDisplay = programRechargeBonus + splitBonus
        if totalDisplay > 0 {
            topupExecuteDisplayTotal = totalDisplay
        }
        if bonusDisplay > 1e-9 {
            topupExecuteDisplayBonus = bonusDisplay
        }
        isNfcBusy = true
        if !topupFromQr {
            scanBanner = "Sign & execute…"
        }
        if let w = walletAddress {
            await refreshPosTerminalReloadQuotaFromChain(wallet: w, infraCard: infra)
        }
        let totalTopupDisplay: Double = {
            guard let s = currencySplit else { return Double(apiAmountString.replacingOccurrences(of: ",", with: "")) ?? 0 }
            return Double(s.currencyAmount.replacingOccurrences(of: ",", with: "")) ?? 0
        }()
        if let quotaErr = validateTopupAgainstReloadQuota(totalAmountDisplay: totalTopupDisplay) {
            reportTopupFailure(quotaErr, topupFromQr: topupFromQr)
            return
        }
        let topupPrepareCurrency = (await api.fetchBeamioUserCardCurrencyCodeAndPointsUnitPriceE6(cardAddress: infra))?.code ?? "CAD"

        if let beamioTag {
            let tagPrep = await api.nfcTopupPrepare(
                uid: nil,
                wallet: nil,
                beamioTag: beamioTag,
                amount: apiAmountString,
                sun: nil,
                infraCard: infra,
                currency: topupPrepareCurrency
            )
            if let err = tagPrep.error {
                reportTopupFailure(err, topupFromQr: topupFromQr)
                return
            }
            guard let resolvedWallet = tagPrep.wallet else {
                reportTopupFailure("Server did not return wallet. Please retry", topupFromQr: topupFromQr)
                return
            }
            guard let cardAddr = tagPrep.cardAddr, let data = tagPrep.data,
                  let deadline = tagPrep.deadline, let nonce = tagPrep.nonce
            else {
                reportTopupFailure("Prepare failed", topupFromQr: topupFromQr)
                return
            }

            let preAssets = await getWalletAssetsForTopupWithEnsureAA(wallet: resolvedWallet, infra: infra)
            guard preAssets.ok else {
                reportTopupFailure(preAssets.error ?? "Query failed", topupFromQr: topupFromQr)
                return
            }
            let preCard = preAssets.cards?.first { $0.cardAddress.caseInsensitiveCompare(cardAddr) == .orderedSame }
            let preBal = preCard?.points ?? preAssets.points ?? "0"
            let cur = preCard?.cardCurrency ?? preAssets.cardCurrency ?? "CAD"
            let custAddr = preAssets.address

            if let err = await validateTopupMeetsMinimumTierForNonMember(amountStr: apiAmountString, cardAddr: cardAddr, preCard: preCard, currency: cur, customerAa: preAssets.aaAddress) {
                reportTopupFailure(err, topupFromQr: topupFromQr)
                return
            }

            let sigBeamio: String
            do {
                sigBeamio = try BeamioEthWallet.signExecuteForAdmin(
                    privateKeyHex: privateKeyHex,
                    cardAddr: cardAddr,
                    dataHex: data,
                    deadline: deadline,
                    nonceHex: nonce
                )
            } catch {
                reportTopupFailure(error.localizedDescription, topupFromQr: topupFromQr)
                return
            }
            let payBeamio = await api.nfcTopup(
                uid: nil,
                wallet: resolvedWallet,
                cardAddr: cardAddr,
                data: data,
                deadline: deadline,
                nonce: nonce,
                adminSignature: sigBeamio,
                sun: nil,
                currencySplit: currencySplit
            )
            guard payBeamio.success else {
                let msg = payBeamio.error ?? "Top-up failed"
                reportTopupFailure(msg, topupFromQr: topupFromQr, homeToast: !topupFromQr)
                return
            }

            await completeTopupSuccessUi(
                amount: apiAmountString,
                txHash: payBeamio.txHash,
                cardAddr: cardAddr,
                preBalance: preBal,
                cardCurrency: cur,
                address: custAddr,
                preCard: preCard,
                settlementViaQr: true,
                fetchPostAssets: {
                    await self.api.getWalletAssets(
                        wallet: resolvedWallet,
                        merchantInfraCard: self.merchantInfraCard,
                        merchantInfraOnly: false,
                        forPostPayment: false
                    )
                }
            )
            return
        }

        var prep: BeamioAPIClient.NfcTopupPrepareResult

        if let wallet {
            prep = await api.nfcTopupPrepare(
                uid: nil,
                wallet: wallet,
                beamioTag: nil,
                amount: apiAmountString,
                sun: nil,
                infraCard: infra,
                currency: topupPrepareCurrency
            )
            if prep.error != nil {
                _ = await api.ensureAAForEOA(eoa: wallet)
                prep = await api.nfcTopupPrepare(
                    uid: nil,
                    wallet: wallet,
                    beamioTag: nil,
                    amount: apiAmountString,
                    sun: nil,
                    infraCard: infra,
                    currency: topupPrepareCurrency
                )
            }
            guard prep.error == nil, let cardAddr = prep.cardAddr, let data = prep.data,
                  let deadline = prep.deadline, let nonce = prep.nonce
            else {
                reportTopupFailure(prep.error ?? "Prepare failed", topupFromQr: topupFromQr)
                return
            }

            let preWalletAssets = await getWalletAssetsForTopupWithEnsureAA(wallet: wallet, infra: infra)
            guard preWalletAssets.ok else {
                reportTopupFailure(preWalletAssets.error ?? "Query failed", topupFromQr: topupFromQr)
                return
            }
            let preCardW = preWalletAssets.cards?.first { $0.cardAddress.caseInsensitiveCompare(cardAddr) == .orderedSame }
            let preBalW = preCardW?.points ?? preWalletAssets.points ?? "0"
            let curW = preCardW?.cardCurrency ?? preWalletAssets.cardCurrency ?? "CAD"
            let custAddrW = preWalletAssets.address

            if let err = await validateTopupMeetsMinimumTierForNonMember(amountStr: apiAmountString, cardAddr: cardAddr, preCard: preCardW, currency: curW, customerAa: preWalletAssets.aaAddress) {
                reportTopupFailure(err, topupFromQr: topupFromQr)
                return
            }

            let sigW: String
            do {
                sigW = try BeamioEthWallet.signExecuteForAdmin(
                    privateKeyHex: privateKeyHex,
                    cardAddr: cardAddr,
                    dataHex: data,
                    deadline: deadline,
                    nonceHex: nonce
                )
            } catch {
                reportTopupFailure(error.localizedDescription, topupFromQr: topupFromQr)
                return
            }
            let payW = await api.nfcTopup(
                uid: nil,
                wallet: wallet,
                cardAddr: cardAddr,
                data: data,
                deadline: deadline,
                nonce: nonce,
                adminSignature: sigW,
                sun: nil,
                currencySplit: currencySplit
            )
            guard payW.success else {
                let msg = payW.error ?? "Top-up failed"
                reportTopupFailure(msg, topupFromQr: topupFromQr, homeToast: !topupFromQr)
                return
            }
            await completeTopupSuccessUi(
                amount: apiAmountString,
                txHash: payW.txHash,
                cardAddr: cardAddr,
                preBalance: preBalW,
                cardCurrency: curW,
                address: custAddrW,
                preCard: preCardW,
                settlementViaQr: true,
                fetchPostAssets: {
                    await self.api.getWalletAssets(
                        wallet: wallet,
                        merchantInfraCard: self.merchantInfraCard,
                        merchantInfraOnly: false,
                        forPostPayment: false
                    )
                }
            )
            return
        }

        guard let uidN = uid, let sunN = sun, !uidN.isEmpty else {
            reportTopupFailure("Cannot read UID", topupFromQr: topupFromQr)
            return
        }

        prep = await api.nfcTopupPrepare(
            uid: uidN,
            wallet: nil,
            beamioTag: nil,
            amount: apiAmountString,
            sun: sunN,
            infraCard: infra,
            currency: topupPrepareCurrency
        )

        guard prep.error == nil, let cardAddr = prep.cardAddr, let data = prep.data,
              let deadline = prep.deadline, let nonce = prep.nonce
        else {
            reportTopupFailure(prep.error ?? "Prepare failed", topupFromQr: topupFromQr)
            return
        }

        let preUidAssets = await api.getUIDAssets(
            uid: uidN,
            sun: sunN,
            merchantInfraCard: infra,
            merchantInfraOnly: false
        )
        guard preUidAssets.ok else {
            reportTopupFailure(preUidAssets.error ?? "Query failed", topupFromQr: topupFromQr)
            return
        }
        let preCardN = preUidAssets.cards?.first { $0.cardAddress.caseInsensitiveCompare(cardAddr) == .orderedSame }
        let preBalN = preCardN?.points ?? preUidAssets.points ?? "0"
        let curN = preCardN?.cardCurrency ?? preUidAssets.cardCurrency ?? "CAD"
        let custAddrN = preUidAssets.address

        if let err = await validateTopupMeetsMinimumTierForNonMember(amountStr: apiAmountString, cardAddr: cardAddr, preCard: preCardN, currency: curN, customerAa: preUidAssets.aaAddress) {
            reportTopupFailure(err, topupFromQr: topupFromQr)
            return
        }

        let sigN: String
        do {
            sigN = try BeamioEthWallet.signExecuteForAdmin(
                privateKeyHex: privateKeyHex,
                cardAddr: cardAddr,
                dataHex: data,
                deadline: deadline,
                nonceHex: nonce
            )
        } catch {
            reportTopupFailure(error.localizedDescription, topupFromQr: topupFromQr)
            return
        }
        let payN = await api.nfcTopup(
            uid: uidN,
            wallet: nil,
            cardAddr: cardAddr,
            data: data,
            deadline: deadline,
            nonce: nonce,
            adminSignature: sigN,
            sun: sunN,
            currencySplit: currencySplit
        )
        guard payN.success else {
            let msg = payN.error ?? "Top-up failed"
            reportTopupFailure(msg, topupFromQr: topupFromQr, homeToast: !topupFromQr)
            return
        }

        await completeTopupSuccessUi(
            amount: apiAmountString,
            txHash: payN.txHash,
            cardAddr: cardAddr,
            preBalance: preBalN,
            cardCurrency: curN,
            address: custAddrN,
            preCard: preCardN,
            settlementViaQr: false,
            fetchPostAssets: {
                await self.api.getUIDAssets(
                    uid: uidN,
                    sun: sunN,
                    merchantInfraCard: self.merchantInfraCard,
                    merchantInfraOnly: false
                )
            }
        )
    }

    /// Android: `Thread.sleep(3000)` then refresh assets; dismiss scan and show `TopupSuccessContent`.
    private func completeTopupSuccessUi(
        amount: String,
        txHash: String?,
        cardAddr: String,
        preBalance: String,
        cardCurrency: String,
        address: String?,
        preCard: CardItem?,
        settlementViaQr: Bool,
        fetchPostAssets: @escaping () async -> UIDAssets
    ) async {
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let postAssets = await fetchPostAssets()
        var postCard = preCard
        var postBalanceStr = "—"
        if postAssets.ok {
            let pc = postAssets.cards?.first { $0.cardAddress.caseInsensitiveCompare(cardAddr) == .orderedSame }
            if let pc { postCard = pc }
            postBalanceStr = postCard?.points ?? postAssets.points ?? "—"
        }
        /// 与 Android `enrichCardTierFromMetadata` / getUIDAssets 卡级 tiers 对齐：升级后档名已更新但 NFT 缓存底色未变时，用 `metadata.tiers` 行覆盖 `cardBackground`。
        if let base = postCard ?? preCard {
            let bundle = await api.fetchCardMetadataTiersBundle(cardAddress: cardAddr)
            postCard = BeamioPaymentRouting.mergePrimaryTierStyleFromCardMetadata(card: base, tiers: bundle.rows)
        }
        let memberNo = postCard?.formattedMemberNumber() ?? ""
        let tagTrim = postAssets.beamioTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = TopupSuccessState(
            amount: amount,
            txHash: txHash ?? "",
            preBalance: preBalance,
            postBalance: postBalanceStr,
            cardCurrency: cardCurrency,
            address: address,
            memberNo: memberNo.isEmpty ? nil : memberNo,
            cardBackground: postCard?.cardBackground ?? preCard?.cardBackground,
            cardImage: postCard?.cardImage ?? preCard?.cardImage,
            tierName: postCard?.tierName ?? preCard?.tierName,
            tierDescription: postCard?.tierDescription ?? preCard?.tierDescription,
            passCard: postCard ?? preCard,
            settlementViaQr: settlementViaQr,
            customerBeamioTag: tagTrim.isEmpty ? nil : tagTrim
        )
        isNfcBusy = false
        scanBanner = ""
        topupQrSigningInProgress = false
        topupQrExecuteError = nil
        topupNfcReadError = nil
        topupExecuteDisplayTotal = nil
        topupExecuteDisplayBonus = nil
        nfc.invalidate()
        sheet = nil
        clearPendingTopupPadAccountingParams()
        topupSuccess = state
        scheduleHomeProfilesRefreshAfterTxSuccess()
        await refreshInfraCardFromDbIfPossible()
    }

    private func handleNfcPayment(url: URL) async {
        chargeNfcReadError = nil
        guard walletPrivateKeyHex != nil else {
            chargeNfcReadError = nfcFlowErrorMessage(detail: "Wallet not initialized.")
            return
        }
        let sun = BeamioSunParser.sunParams(from: url)
        let uid =
            sun?.uid
            ?? BeamioSunParser.uidHexPreview(from: url)
            ?? ""
        guard !uid.isEmpty else {
            chargeNfcReadError = nfcFlowErrorMessage(detail: "Cannot read UID from this card.")
            return
        }
        let subtotal = Double(amountString) ?? 0
        guard subtotal > 0 else {
            chargeNfcReadError = nfcFlowErrorMessage(detail: "Invalid amount.")
            return
        }
        scanAwaitingNfcTap = false
        paymentTerminalError = nil
        isNfcBusy = true
        scanBanner = ""
        paymentRoutingSteps = Self.makeInitialPaymentRoutingSteps()
        paymentPatchStep(id: "detectingUser", status: .loading)
        paymentPatchStep(id: "detectingUser", status: .success, detail: "NFC card detected")
        paymentPatchStep(id: "membership", status: .loading)
        paymentPatchStep(id: "membership", status: .success, detail: "NFC card payment")
        paymentPatchStep(id: "analyzingAssets", status: .loading)
        await refreshInfraCardFromDbIfPossible()
        let assets = await api.getUIDAssets(uid: uid, sun: sun, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false)
        guard assets.ok else {
            paymentPatchStep(id: "analyzingAssets", status: .error, detail: "")
            isNfcBusy = false
            paymentRoutingSteps = []
            paymentTerminalError = nil
            chargeNfcReadError = nfcFlowErrorMessage(detail: assets.error ?? "Card not registered")
            scanBanner = ""
            qrPaymentResetId += 1
            return
        }
        paymentPatchStep(id: "analyzingAssets", status: .success, detail: "Card + USDC balance")
        let oracle = await api.fetchOracle().toPaymentOracle()
        let payee = walletAddress ?? ""
        let payCard = assets.cards?.first
        let payCurrency = payCard?.cardCurrency ?? assets.cardCurrency ?? "CAD"
        let routingDetails = await api.fetchChargeTierRoutingDetails(wallet: payee, infraCard: merchantInfraCard)
        let taxP = routingDetails?.taxPercent ?? infraRoutingTaxPercent ?? 0.0
        let metaBundle = await api.fetchCardMetadataTiersBundle(cardAddress: payCard?.cardAddress)
        let disc = BeamioPaymentRouting.pickChargeTierDiscountPercent(
            paymentCard: payCard,
            assets: assets,
            discountByTierKey: routingDetails?.discountByTierKey ?? [:],
            metadataTiers: metaBundle.rows,
            metadataTiersFromApi: metaBundle.fromApi
        )
        let tip = BeamioPaymentRouting.chargeTipFromRequestAndBps(requestAmount: subtotal, tipRateBps: chargeTipRateBps)
        let total = BeamioPaymentRouting.chargeTotalInCurrency(requestAmount: subtotal, taxPercent: taxP, tierDiscountPercent: disc, tipAmount: tip)
        let amountUsdc6 = BeamioPaymentRouting.currencyToUsdc6(amount: total, currency: payCurrency, oracle: oracle)
        guard let amountBig = Int64(amountUsdc6), amountBig > 0 else {
            paymentPatchStep(id: "analyzingAssets", status: .error, detail: "Amount conversion failed")
            isNfcBusy = false
            paymentTerminalError = "Amount conversion failed"
            scanBanner = ""
            return
        }
        let prep = await api.payByNfcUidPrepare(uid: uid, payee: payee, amountUsdc6: amountUsdc6, sun: sun)
        let ok = (prep["ok"] as? Bool) == true
        let account = prep["account"] as? String
        let nonce = prep["nonce"] as? String
        let deadline = prep["deadline"] as? String
        let payeeAA = prep["payeeAA"] as? String
        let unitPriceStr = prep["unitPriceUSDC6"] as? String
        guard ok, let account, let nonce, let deadline, let payeeAA, let unitPriceStr,
              let unitPrice = Int64(unitPriceStr), unitPrice > 0
        else {
            paymentPatchStep(id: "optimizingRoute", status: .error, detail: (prep["error"] as? String) ?? "Prepare failed")
            isNfcBusy = false
            paymentTerminalError = (prep["error"] as? String) ?? "Prepare failed"
            scanBanner = ""
            return
        }
        paymentPatchStep(id: "optimizingRoute", status: .loading)
        let usdcBal = payerUsdcBalance6ForChargePolicy(assets: assets)
        let cards = BeamioPaymentRouting.chargeableCards(from: assets, infraCard: merchantInfraCard)
        let partNfc = BeamioPaymentRouting.partitionPointsForMerchantCharge(cards: cards, merchantInfraCard: merchantInfraCard)
        let unitPointsStr = partNfc.unitPricePoints6
        let oracleInfraCardsNfc = partNfc.oracleInfraCards
        let infraPointsStr = oracleInfraCardsNfc.reduce(0) { $0 + (Int64($1.points6) ?? 0) }
        let unitBucketUsdc6Nfc = (unitPointsStr > 0 && unitPrice > 0) ? (unitPointsStr * unitPrice) / 1_000_000 : 0
        let infraValue = oracleInfraCardsNfc.reduce(0) { partial, c in
            partial + BeamioPaymentRouting.points6ToUsdc6(points6: Int64(c.points6) ?? 0, cardCurrency: c.cardCurrency, oracle: oracle)
        }
        let totalBal = unitBucketUsdc6Nfc + infraValue + usdcBal
        guard totalBal >= amountBig else {
            paymentPatchStep(id: "analyzingAssets", status: .error, detail: "Insufficient balance")
            presentChargeInsufficientFunds(
                assets: assets,
                payCard: payCard,
                payCurrency: payCurrency,
                chargeTotalInPayCurrency: total,
                subtotal: subtotal,
                tip: tip,
                taxPercent: taxP,
                tierDiscountPercent: disc,
                requiredUsdc6: amountBig,
                availableUsdc6: totalBal,
                settlementViaQr: false,
                nfcRetryUid: uid,
                nfcRetrySun: sun,
                qrRetryAccount: nil,
                qrRetryPayload: nil
            )
            return
        }
        paymentPatchStep(id: "optimizingRoute", status: .success, detail: "Direct: NFC → Merchant")
        let split = BeamioPaymentRouting.computeChargeContainerSplit(
            amountBig: amountBig,
            chargeTotalInPayCurrency: total,
            payCurrency: payCurrency,
            oracle: oracle,
            unitPriceUSDC6: unitPrice,
            ccsaPoints6: unitPointsStr,
            infraPoints6: infraPointsStr,
            infraCardCurrency: oracleInfraCardsNfc.first?.cardCurrency,
            usdcBalance6: usdcBal
        )
        var items = BeamioPaymentRouting.buildPayItems(amountUsdc6: amountUsdc6, split: split, infraCard: merchantInfraCard)
        items = BeamioPaymentRouting.mergeInfraKind1Items(items, infraCard: merchantInfraCard)
        let container: [String: Any] = [
            "account": account,
            "to": payeeAA,
            "items": items,
            "nonce": nonce,
            "deadline": deadline,
        ]
        let taxFiat6 = Int64((subtotal * taxP / 100.0 * 1_000_000.0).rounded())
        let discNorm = BeamioPaymentRouting.normalizeTierDiscountPercent(disc)
        let discFiat6 = Int64((subtotal * discNorm / 100.0 * 1_000_000.0).rounded())
        var bill: [String: Any] = [
            "nfcSubtotalCurrencyAmount": String(format: "%.2f", subtotal),
            "nfcRequestCurrency": payCurrency,
            "nfcTaxAmountFiat6": String(taxFiat6),
            "nfcTaxRateBps": Int((taxP * 100.0).rounded()),
            "nfcDiscountAmountFiat6": String(discFiat6),
            "nfcDiscountRateBps": BeamioPaymentRouting.tierDiscountBasisPoints(disc),
        ]
        if tip > 0 {
            bill["nfcTipCurrencyAmount"] = String(format: "%.2f", tip)
            if chargeTipRateBps > 0 { bill["nfcTipRateBps"] = chargeTipRateBps }
        }
        paymentPatchStep(id: "sendTx", status: .loading)
        let pay = await api.payByNfcUidSignContainer(
            uid: uid,
            containerPayload: container,
            amountUsdc6: amountUsdc6,
            sun: sun,
            nfcBill: bill
        )
        guard pay.success else {
            let msg = pay.error ?? "Payment failed"
            paymentPatchStep(id: "sendTx", status: .error, detail: msg)
            paymentPatchStep(id: "waitTx", status: .error, detail: "")
            isNfcBusy = false
            paymentTerminalError = msg
            scanBanner = ""
            homeToast = msg
            return
        }
        paymentPatchStep(id: "sendTx", status: .success, detail: "Sent")
        paymentPatchStep(id: "waitTx", status: .success, detail: "Transaction complete")
        paymentPatchStep(id: "refreshBalance", status: .loading, detail: "Fetching latest balance")
        let useInfraPost = split.ccsaPointsWei + split.infraPointsWei > 0
        let mNo = assets.memberNoPrimaryFromSortedCards().nilIfEmpty
        await completePaymentSuccessUi(
            amountTotal: total,
            payee: payeeAA,
            txHash: pay.txHash,
            subtotal: subtotal,
            tip: tip,
            payCurrency: payCurrency,
            memberNo: mNo,
            passCard: payCard,
            cardName: payCard?.cardName,
            tierName: payCard?.tierName,
            cardType: payCard?.cardType,
            settlementViaQr: false,
            taxPercent: taxP,
            tierDiscountPercent: disc,
            useInfraCardPostBalance: useInfraPost,
            fetchPostAssets: {
                await self.api.getUIDAssets(
                    uid: uid,
                    sun: sun,
                    merchantInfraCard: self.merchantInfraCard,
                    merchantInfraOnly: false
                )
            }
        )
    }

    /// Android: NFC sleep 3s, QR sleep 5s — 再拉余额；NFC 全屏 `chargeSuccess`，Charge+QR 内联 `chargeApprovedInline`。
    private func completePaymentSuccessUi(
        amountTotal: Double,
        payee: String,
        txHash: String?,
        subtotal: Double,
        tip: Double,
        payCurrency: String,
        memberNo: String?,
        passCard: CardItem?,
        cardName: String?,
        tierName: String?,
        cardType: String?,
        settlementViaQr: Bool,
        taxPercent: Double,
        tierDiscountPercent: Double,
        useInfraCardPostBalance: Bool,
        inlineInSheet: Bool = false,
        isPartialApproval: Bool = false,
        originalOrderTotal: Double? = nil,
        remainingShortfall: Double? = nil,
        fetchPostAssets: @escaping () async -> UIDAssets
    ) async {
        let delayNs: UInt64 = settlementViaQr ? 5_000_000_000 : 3_000_000_000
        try? await Task.sleep(nanoseconds: delayNs)
        let oracle = await api.fetchOracle().toPaymentOracle()
        let postAssets = await fetchPostAssets()
        let postBalStr: String
        if postAssets.ok,
           let cad = BeamioPaymentRouting.postPaymentBalanceCad(
               from: postAssets,
               oracle: oracle,
               infraCard: merchantInfraCard,
               useInfraCardRow: useInfraCardPostBalance
           )
        {
            postBalStr = String(format: "%.2f", cad)
        } else {
            postBalStr = "—"
        }
        var refreshedPass = passCard
        if postAssets.ok, let addr = passCard?.cardAddress,
           let pc = postAssets.cards?.first(where: { $0.cardAddress.caseInsensitiveCompare(addr) == .orderedSame })
        {
            refreshedPass = pc
        }
        /// 与 Top-up 成功页一致：`metadata.tiers` 主档行覆盖 stale NFT `cardBackground` / `cardImage`。
        if let base = refreshedPass ?? passCard {
            let ca = base.cardAddress.trimmingCharacters(in: .whitespacesAndNewlines)
            if !ca.isEmpty {
                let bundle = await api.fetchCardMetadataTiersBundle(cardAddress: ca)
                refreshedPass = BeamioPaymentRouting.mergePrimaryTierStyleFromCardMetadata(card: base, tiers: bundle.rows)
            }
        }
        if inlineInSheet, !isPartialApproval {
            let refreshDetail = postBalStr == "—" ? "Unavailable" : "Updated"
            paymentPatchStep(id: "refreshBalance", status: .success, detail: refreshDetail)
        }
        let tagTrim = postAssets.beamioTag?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let walletTrim = postAssets.address?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let state = ChargeSuccessState(
            amount: String(format: "%.2f", amountTotal),
            payee: payee,
            txHash: txHash ?? "",
            subtotal: String(format: "%.2f", subtotal),
            tip: tip > 0 ? String(format: "%.2f", tip) : nil,
            postBalance: postBalStr,
            cardCurrency: payCurrency,
            memberNo: memberNo,
            cardBackground: refreshedPass?.cardBackground ?? passCard?.cardBackground,
            cardImage: refreshedPass?.cardImage ?? passCard?.cardImage,
            cardName: refreshedPass?.cardName ?? cardName,
            tierName: refreshedPass?.tierName ?? tierName,
            cardType: refreshedPass?.cardType ?? cardType,
            passCard: refreshedPass ?? passCard,
            settlementViaQr: settlementViaQr,
            chargeTaxPercent: taxPercent,
            chargeTierDiscountPercent: tierDiscountPercent,
            tableNumber: nil,
            isPartialApproval: isPartialApproval,
            originalOrderTotal: originalOrderTotal.map { String(format: "%.2f", $0) },
            remainingShortfall: remainingShortfall.map { String(format: "%.2f", $0) },
            customerBeamioTag: tagTrim.isEmpty ? nil : tagTrim,
            customerWalletAddress: walletTrim.isEmpty ? nil : walletTrim
        )
        isNfcBusy = false
        scanBanner = ""
        nfc.invalidate()
        if inlineInSheet, !isPartialApproval {
            paymentRoutingSteps = []
            chargeApprovedInline = state
        } else {
            sheet = nil
            chargeSuccess = state
        }
        scheduleHomeProfilesRefreshAfterTxSuccess()
    }

    private func handleNfcLinkApp(url: URL) async {
        scanAwaitingNfcTap = false
        guard let sun = BeamioSunParser.sunParams(from: url) else {
            scanBanner = "Card does not support SUN. Cannot link app."
            return
        }
        isNfcBusy = true
        scanBanner = "Linking…"
        await refreshInfraCardFromDbIfPossible()
        let r = await api.postNfcLinkApp(sun: sun, infraCard: merchantInfraCard)
        isNfcBusy = false
        if r.success, let url = r.deepLinkUrl {
            linkDeepLink = url
            linkLockedSun = nil
            showLinkCancel = false
            scanBanner = "Link ready"
            await refreshInfraCardFromDbIfPossible()
        } else {
            scanBanner = r.error ?? "Link App failed"
            if r.errorCode == "NFC_LINK_APP_CARD_LOCKED" {
                linkLockedSun = sun
                showLinkCancel = true
            }
        }
    }

    func cancelLinkLock() async {
        guard let sun = linkLockedSun else { return }
        opRunning = true
        let r = await api.postNfcLinkAppCancel(sun: sun)
        opRunning = false
        if r.success {
            linkLockedSun = nil
            showLinkCancel = false
            linkDeepLink = ""
            scanBanner = ""
            homeToast = "Link lock cancelled"
            closeScanSheet()
        } else {
            homeToast = r.error ?? "Cancel failed"
        }
    }

    func requestCameraIfNeeded() async -> Bool {
        await withCheckedContinuation { cont in
            AVCaptureDevice.requestAccess(for: .video) { ok in
                cont.resume(returning: ok)
            }
        }
    }

    /// Dismiss scan sheet and stop NFC session (foreground equivalent of Android disableForegroundDispatch).
    func closeScanSheet() {
        nfc.invalidate()
        sheet = nil
        scanBanner = ""
        isNfcBusy = false
        scanQrCameraArmed = false
        scanAwaitingNfcTap = false
        resetPaymentQrChrome()
        resetTopupQrChrome()
        resetReadQrChrome()
        // Re-run admin gate + home refresh after Check Balance / dismissed scan flows (same idea as payment success dismiss).
        if walletAddress != nil, !showWelcome, !showOnboarding {
            Task {
                await refreshHomeProfiles()
            }
        }
    }

    func dismissTopupSuccess() {
        topupSuccess = nil
    }

    func dismissChargeSuccess() {
        chargeSuccess = nil
    }

    func dismissChargeInsufficientFunds() {
        chargeInsufficientFunds = nil
    }

    func topUpAfterInsufficientFunds() {
        chargeInsufficientFunds = nil
        topupPaymentMethodTitle = "USDC"
        pendingTopupMethodRaw = "creditCard"
        pendingTopupBonusExpanded = false
        pendingTopupBonusRatePercent = 0
        pendingTopupKeypadAmount = amountString
        beginTopUp()
    }

    /// After partial approval: dismiss success and open Charge again for the remaining amount (same keypad amount + tip).
    func continueChargeAfterPartialApproval() {
        let amt = amountString
        let bps = chargeTipRateBps
        beginCharge(amount: amt, tipBps: bps)
    }

    /// Pay with all currently available payer assets (USDC6 total), then show partial approval if order was larger.
    func chargeAvailableBalanceAfterInsufficientFunds() {
        guard let ins = chargeInsufficientFunds else { return }
        homeToast = nil
        guard ins.availableUsdc6 > 0 else {
            homeToast = "No available balance"
            return
        }
        let uid = ins.retryNfcUid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let sun = ins.retryNfcSun
        let qrAcc = ins.retryQrAccount?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let qrPay: [String: Any]? = {
            guard let j = ins.retryQrPayloadJson, !j.isEmpty,
                  let data = j.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return nil }
            return obj
        }()
        let hasRetry = (uid != nil) || (qrAcc != nil && qrPay != nil)
        guard hasRetry else {
            homeToast = "Cannot retry payment from here. Start Charge again."
            return
        }
        dismissChargeInsufficientFunds()

        pendingScanAction = .payment
        sheet = .scan(.payment)
        paymentQrInterpreting = false
        paymentQrParseError = nil
        paymentTerminalError = nil
        paymentRoutingSteps = Self.makeInitialPaymentRoutingSteps()
        scanBanner = "Charging available balance…"
        isNfcBusy = true
        scanAwaitingNfcTap = false
        scanQrCameraArmed = false
        chargeApprovedInline = nil

        if uid != nil {
            scanMethod = .nfc
            nfc.invalidate()
            paymentPatchStep(id: "detectingUser", status: .success, detail: "NFC card detected")
            paymentPatchStep(id: "membership", status: .success, detail: "NFC card payment")
            paymentPatchStep(id: "analyzingAssets", status: .loading)
        } else {
            scanMethod = .qr
            nfc.invalidate()
            paymentPatchStep(id: "detectingUser", status: .success, detail: "Dynamic QR detected")
            paymentPatchStep(id: "membership", status: .loading)
            paymentPatchStep(id: "analyzingAssets", status: .loading)
        }

        opRunning = true
        opMessage = "Charging available balance…"
        Task { @MainActor in
            defer {
                opRunning = false
                opMessage = ""
            }
            if let u = uid, !u.isEmpty {
                await executePartialMaxNfcCharge(ins: ins, uid: u, sun: sun)
            } else if let acc = qrAcc, let base = qrPay {
                await executePartialMaxQrCharge(ins: ins, payerAccount: acc, basePayload: base)
            }
        }
    }

    /// Close scan / QR chrome and show full-screen insufficient-funds UI (matches Balance Loaded–style page).
    private func presentChargeInsufficientFunds(
        assets: UIDAssets,
        payCard: CardItem?,
        payCurrency: String,
        chargeTotalInPayCurrency: Double,
        subtotal: Double,
        tip: Double,
        taxPercent: Double,
        tierDiscountPercent: Double,
        requiredUsdc6: Int64,
        availableUsdc6: Int64,
        settlementViaQr: Bool,
        nfcRetryUid: String?,
        nfcRetrySun: SunParams?,
        qrRetryAccount: String?,
        qrRetryPayload: [String: Any]?
    ) {
        let tag = assets.beamioTag?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let rawAddr = assets.address?.trimmingCharacters(in: .whitespacesAndNewlines)
        let walletShort: String? = {
            guard let a = rawAddr, a.count >= 10 else { return nil }
            return "\(a.prefix(6))…\(a.suffix(4))"
        }()
        let memberNo = assets.memberNoPrimaryFromSortedCards().nilIfEmpty
        let trimmedNfcUid = nfcRetryUid?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let trimmedQrAcc = qrRetryAccount?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let qrPayloadJson: String? = {
            guard trimmedQrAcc != nil, let p = qrRetryPayload,
                  JSONSerialization.isValidJSONObject(p),
                  let data = try? JSONSerialization.data(withJSONObject: p, options: [])
            else { return nil }
            return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        }()
        let state = ChargeInsufficientFundsState(
            chargeTotalInPayCurrency: chargeTotalInPayCurrency,
            payCurrency: payCurrency,
            requiredUsdc6: requiredUsdc6,
            availableUsdc6: availableUsdc6,
            subtotal: subtotal,
            tip: tip,
            taxPercent: taxPercent,
            tierDiscountPercent: tierDiscountPercent,
            beamioTag: tag,
            walletShort: walletShort,
            memberNo: memberNo,
            passCard: payCard,
            settlementViaQr: settlementViaQr,
            retryNfcUid: trimmedNfcUid,
            retryNfcSun: trimmedNfcUid != nil ? nfcRetrySun : nil,
            retryQrAccount: trimmedQrAcc,
            retryQrPayloadJson: trimmedQrAcc != nil ? qrPayloadJson : nil
        )
        isNfcBusy = false
        scanBanner = ""
        paymentTerminalError = nil
        paymentQrParseError = nil
        paymentQrInterpreting = false
        paymentRoutingSteps = []
        chargeApprovedInline = nil
        nfc.invalidate()
        sheet = nil
        chargeInsufficientFunds = state
    }

    /// Switch between Tap Card and Scan QR while sheet is open.
    func setScanMethod(_ m: ScanMethod) {
        if pendingScanAction == .linkApp, m == .qr { return }
        if pendingScanAction == .payment, m != scanMethod {
            paymentQrParseError = nil
            paymentQrInterpreting = false
            paymentTerminalError = nil
            paymentRoutingSteps = []
            chargeApprovedInline = nil
            chargeNfcReadError = nil
            isNfcBusy = false
            scanBanner = ""
            qrPaymentResetId += 1
        }
        if pendingScanAction == .topup, m != scanMethod {
            resetTopupQrChrome()
            isNfcBusy = false
            scanBanner = ""
            topupQrResetId += 1
        }
        if pendingScanAction == .read, m != scanMethod {
            resetReadQrChrome()
            isNfcBusy = false
            scanBanner = ""
            readQrResetId += 1
        }
        scanMethod = m
        if m == .nfc {
            scanQrCameraArmed = false
            scanAwaitingNfcTap = true
            scanBanner = "Hold the customer's NTAG 424 DNA card near the NFC sensor."
            nfc.begin()
        } else {
            nfc.invalidate()
            scanBanner = "Point the camera at the QR code."
            scanAwaitingNfcTap = false
        }
    }

    /// USDC6 可扣总额：prepare `unitPriceUSDC6` 点桶 + 他址 infrastructure 点（oracle）+ USDC。
    private func computeChargeableTotalUsdc6(
        assets: UIDAssets,
        oracle: BeamioPaymentRouting.OracleRates,
        unitPriceUSDC6: Int64,
        merchantInfraCard: String
    ) -> Int64 {
        let usdcBal = payerUsdcBalance6ForChargePolicy(assets: assets)
        let cards = BeamioPaymentRouting.chargeableCards(from: assets, infraCard: merchantInfraCard)
        let part = BeamioPaymentRouting.partitionPointsForMerchantCharge(cards: cards, merchantInfraCard: merchantInfraCard)
        let unitP = part.unitPricePoints6
        let unitVal = (unitP > 0 && unitPriceUSDC6 > 0) ? (unitP * unitPriceUSDC6) / 1_000_000 : 0
        let infraVal = part.oracleInfraCards.reduce(0) { partial, c in
            partial + BeamioPaymentRouting.points6ToUsdc6(points6: Int64(c.points6) ?? 0, cardCurrency: c.cardCurrency, oracle: oracle)
        }
        return unitVal + infraVal + usdcBal
    }

    /// Android `payByNfcUidWithContainer`：用 prepare 的 `unitPriceUSDC6` 估值 program / BeamioUserCard 点，再加 oracle 基础设施点与 USDC。
    private func nfcBackedSpendableUsdc6(
        unitPricePoints6: Int64,
        oracleInfraCards: [CardItem],
        unitPriceUSDC6: Int64,
        usdcBalance6: Int64,
        oracle: BeamioPaymentRouting.OracleRates
    ) -> Int64 {
        let unitVal = (unitPricePoints6 > 0 && unitPriceUSDC6 > 0) ? (unitPricePoints6 * unitPriceUSDC6) / 1_000_000 : 0
        let infraVal = oracleInfraCards.reduce(0) { partial, c in
            partial + BeamioPaymentRouting.points6ToUsdc6(points6: Int64(c.points6) ?? 0, cardCurrency: c.cardCurrency, oracle: oracle)
        }
        return unitVal + infraVal + usdcBalance6
    }

    /// Android `chargeTotalInPayForSplit = totalCurrency * (totalBalance6 / required6)` — scale **fiat** from the original order by the USDC6 ratio; do not convert USDC6 → fiat via oracle (avoids double conversion vs input totals).
    private func partialChargeFiatFromOriginalOrder(ins: ChargeInsufficientFundsState, effectiveUsdc6: Int64) -> Double {
        let den = max(ins.requiredUsdc6, 1)
        let scaled = ins.chargeTotalInPayCurrency * (Double(effectiveUsdc6) / Double(den))
        return min(ins.chargeTotalInPayCurrency, max(0, scaled))
    }

    private func scaledNfcBillForPartialCharge(ins: ChargeInsufficientFundsState, chargedFiat: Double, payCurrency: String) -> [String: Any] {
        let total = max(ins.chargeTotalInPayCurrency, 0.000_001)
        let ratio = min(1, max(0, chargedFiat / total))
        let sReq = ins.subtotal * ratio
        let sTip = ins.tip * ratio
        let taxFiat6 = Int64((sReq * ins.taxPercent / 100.0 * 1_000_000.0).rounded())
        let taxBps = min(10_000, max(0, Int((ins.taxPercent * 100.0).rounded())))
        let discNorm = BeamioPaymentRouting.normalizeTierDiscountPercent(ins.tierDiscountPercent)
        let discFiat6 = Int64((sReq * discNorm / 100.0 * 1_000_000.0).rounded())
        let discBps = BeamioPaymentRouting.tierDiscountBasisPoints(ins.tierDiscountPercent)
        var bill: [String: Any] = [
            "nfcSubtotalCurrencyAmount": String(format: "%.2f", sReq),
            "nfcRequestCurrency": payCurrency,
            "nfcTaxAmountFiat6": String(taxFiat6),
            "nfcTaxRateBps": taxBps,
            "nfcDiscountAmountFiat6": String(discFiat6),
            "nfcDiscountRateBps": discBps,
        ]
        if sTip > 0 {
            bill["nfcTipCurrencyAmount"] = String(format: "%.2f", sTip)
            if chargeTipRateBps > 0 { bill["nfcTipRateBps"] = chargeTipRateBps }
        }
        return bill
    }

    private func surfacePartialChargeRoutingFailure(message: String, stepId: String) {
        homeToast = message
        paymentTerminalError = message
        isNfcBusy = false
        scanBanner = ""
        nfc.invalidate()
        paymentPatchStep(id: stepId, status: .error, detail: message)
    }

    private func executePartialMaxNfcCharge(ins: ChargeInsufficientFundsState, uid: String, sun: SunParams?) async {
        homeToast = nil
        guard walletAddress != nil else {
            surfacePartialChargeRoutingFailure(message: "Wallet not initialized", stepId: "analyzingAssets")
            return
        }
        await refreshInfraCardFromDbIfPossible()
        let amountCandidate = ins.availableUsdc6
        guard amountCandidate > 0 else {
            surfacePartialChargeRoutingFailure(message: "No available balance", stepId: "analyzingAssets")
            return
        }
        let assets = await api.getUIDAssets(uid: uid, sun: sun, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false)
        guard assets.ok else {
            surfacePartialChargeRoutingFailure(message: assets.error ?? "Card not registered", stepId: "analyzingAssets")
            return
        }
        paymentPatchStep(id: "analyzingAssets", status: .success, detail: "Card + USDC balance")
        paymentPatchStep(id: "optimizingRoute", status: .loading)
        let oracle = await api.fetchOracle().toPaymentOracle()
        let payee = walletAddress ?? ""
        let payCard = assets.cards?.first
        let payCurrency = payCard?.cardCurrency ?? assets.cardCurrency ?? ins.payCurrency

        let usdcBal = payerUsdcBalance6ForChargePolicy(assets: assets)
        let cards = BeamioPaymentRouting.chargeableCards(from: assets, infraCard: merchantInfraCard)
        let part = BeamioPaymentRouting.partitionPointsForMerchantCharge(cards: cards, merchantInfraCard: merchantInfraCard)
        let unitPointsStr = part.unitPricePoints6
        let oracleInfraCards = part.oracleInfraCards
        let infraPointsStr = oracleInfraCards.reduce(0) { $0 + (Int64($1.points6) ?? 0) }

        var unitPrice = Int64(assets.unitPriceUSDC6 ?? "0") ?? 0
        if unitPrice <= 0 {
            let probe = await api.payByNfcUidPrepare(uid: uid, payee: payee, amountUsdc6: "1", sun: sun)
            let probeOk = (probe["ok"] as? Bool) == true
            let ups = probe["unitPriceUSDC6"] as? String
            guard probeOk, let ups, let up = Int64(ups), up > 0 else {
                surfacePartialChargeRoutingFailure(message: (probe["error"] as? String) ?? "Prepare failed", stepId: "optimizingRoute")
                return
            }
            unitPrice = up
        }

        let freshTotal = computeChargeableTotalUsdc6(
            assets: assets,
            oracle: oracle,
            unitPriceUSDC6: unitPrice,
            merchantInfraCard: merchantInfraCard
        )
        var amountBig = min(amountCandidate, freshTotal)
        guard amountBig > 0 else {
            surfacePartialChargeRoutingFailure(message: "No available balance", stepId: "analyzingAssets")
            return
        }

        var accountAddr: String?
        var nonce: String?
        var deadline: String?
        var payeeAA: String?
        var unitPriceFromPrep: Int64 = 0
        var prepareReady = false
        for _ in 0 ..< 4 {
            let prep = await api.payByNfcUidPrepare(uid: uid, payee: payee, amountUsdc6: String(amountBig), sun: sun)
            let ok = (prep["ok"] as? Bool) == true
            guard ok,
                  let acc = prep["account"] as? String,
                  let nn = prep["nonce"] as? String,
                  let dl = prep["deadline"] as? String,
                  let pAA = prep["payeeAA"] as? String,
                  let ups = prep["unitPriceUSDC6"] as? String,
                  let upPrep = Int64(ups), upPrep > 0
            else {
                surfacePartialChargeRoutingFailure(message: (prep["error"] as? String) ?? "Prepare failed", stepId: "optimizingRoute")
                return
            }
            unitPriceFromPrep = upPrep
            let backed = nfcBackedSpendableUsdc6(
                unitPricePoints6: unitPointsStr,
                oracleInfraCards: oracleInfraCards,
                unitPriceUSDC6: unitPriceFromPrep,
                usdcBalance6: usdcBal,
                oracle: oracle
            )
            if backed >= amountBig {
                accountAddr = acc
                nonce = nn
                deadline = dl
                payeeAA = pAA
                prepareReady = true
                break
            }
            amountBig = backed
            if amountBig <= 0 {
                surfacePartialChargeRoutingFailure(message: "No available balance", stepId: "optimizingRoute")
                return
            }
        }

        guard prepareReady, let accountAddr, let nonce, let deadline, let payeeAA, unitPriceFromPrep > 0 else {
            surfacePartialChargeRoutingFailure(message: "Could not lock payment amount. Try again.", stepId: "optimizingRoute")
            return
        }
        let unitPriceResolved = unitPriceFromPrep

        let chargedFiat = partialChargeFiatFromOriginalOrder(ins: ins, effectiveUsdc6: amountBig)
        guard chargedFiat > 0 else {
            surfacePartialChargeRoutingFailure(message: "Invalid charge amount", stepId: "optimizingRoute")
            return
        }
        paymentPatchStep(id: "optimizingRoute", status: .success, detail: "Direct: NFC → Merchant")
        let split = BeamioPaymentRouting.computeChargeContainerSplit(
            amountBig: amountBig,
            chargeTotalInPayCurrency: chargedFiat,
            payCurrency: payCurrency,
            oracle: oracle,
            unitPriceUSDC6: unitPriceResolved,
            ccsaPoints6: unitPointsStr,
            infraPoints6: infraPointsStr,
            infraCardCurrency: oracleInfraCards.first?.cardCurrency,
            usdcBalance6: usdcBal
        )
        let amountUsdc6 = String(amountBig)
        var items = BeamioPaymentRouting.buildPayItems(amountUsdc6: amountUsdc6, split: split, infraCard: merchantInfraCard)
        items = BeamioPaymentRouting.mergeInfraKind1Items(items, infraCard: merchantInfraCard)
        let container: [String: Any] = [
            "account": accountAddr,
            "to": payeeAA,
            "items": items,
            "nonce": nonce,
            "deadline": deadline,
        ]
        let bill = scaledNfcBillForPartialCharge(ins: ins, chargedFiat: chargedFiat, payCurrency: payCurrency)
        paymentPatchStep(id: "sendTx", status: .loading)
        let pay = await api.payByNfcUidSignContainer(
            uid: uid,
            containerPayload: container,
            amountUsdc6: amountUsdc6,
            sun: sun,
            nfcBill: bill
        )
        guard pay.success else {
            let msg = pay.error ?? "Payment failed"
            paymentPatchStep(id: "sendTx", status: .error, detail: msg)
            paymentPatchStep(id: "waitTx", status: .error, detail: "")
            isNfcBusy = false
            paymentTerminalError = msg
            scanBanner = ""
            homeToast = msg
            return
        }
        paymentPatchStep(id: "sendTx", status: .success, detail: "Sent")
        paymentPatchStep(id: "waitTx", status: .success, detail: "Transaction complete")
        paymentPatchStep(id: "refreshBalance", status: .loading, detail: "Fetching latest balance")
        let useInfraPost = split.ccsaPointsWei + split.infraPointsWei > 0
        let mNo = assets.memberNoPrimaryFromSortedCards().nilIfEmpty
        let shortfall = max(0, ins.chargeTotalInPayCurrency - chargedFiat)
        await completePaymentSuccessUi(
            amountTotal: chargedFiat,
            payee: payeeAA,
            txHash: pay.txHash,
            subtotal: ins.subtotal,
            tip: ins.tip,
            payCurrency: payCurrency,
            memberNo: mNo,
            passCard: payCard,
            cardName: payCard?.cardName,
            tierName: payCard?.tierName,
            cardType: payCard?.cardType,
            settlementViaQr: false,
            taxPercent: ins.taxPercent,
            tierDiscountPercent: ins.tierDiscountPercent,
            useInfraCardPostBalance: useInfraPost,
            inlineInSheet: false,
            isPartialApproval: true,
            originalOrderTotal: ins.chargeTotalInPayCurrency,
            remainingShortfall: shortfall,
            fetchPostAssets: {
                await self.api.getUIDAssets(
                    uid: uid,
                    sun: sun,
                    merchantInfraCard: self.merchantInfraCard,
                    merchantInfraOnly: false
                )
            }
        )
    }

    private func executePartialMaxQrCharge(ins: ChargeInsufficientFundsState, payerAccount: String, basePayload: [String: Any]) async {
        homeToast = nil
        guard let payeeWallet = walletAddress else {
            surfacePartialChargeRoutingFailure(message: "Wallet not initialized", stepId: "membership")
            return
        }
        await refreshInfraCardFromDbIfPossible()
        let amountCandidate = ins.availableUsdc6
        guard amountCandidate > 0 else {
            surfacePartialChargeRoutingFailure(message: "No available balance", stepId: "analyzingAssets")
            return
        }
        var payload = basePayload
        let account = payerAccount
        let assets = await api.getWalletAssets(wallet: account, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false, forPostPayment: false)
        guard assets.ok else {
            surfacePartialChargeRoutingFailure(message: assets.error ?? "Unable to fetch customer assets", stepId: "membership")
            return
        }
        paymentPatchStep(id: "membership", status: .success, detail: "Cardholder")
        paymentPatchStep(id: "analyzingAssets", status: .loading)
        let oracle = await api.fetchOracle().toPaymentOracle()
        let payCard = assets.cards?.first
        let payCurrency = payCard?.cardCurrency ?? assets.cardCurrency ?? ins.payCurrency
        let unitPriceStr = assets.unitPriceUSDC6 ?? "0"
        let unitPrice = Int64(unitPriceStr) ?? 0
        let freshTotal = computeChargeableTotalUsdc6(
            assets: assets,
            oracle: oracle,
            unitPriceUSDC6: unitPrice,
            merchantInfraCard: merchantInfraCard
        )
        let amountPartial = min(amountCandidate, freshTotal)
        guard amountPartial > 0 else {
            surfacePartialChargeRoutingFailure(message: "No available balance", stepId: "analyzingAssets")
            return
        }
        let chargedFiat = partialChargeFiatFromOriginalOrder(ins: ins, effectiveUsdc6: amountPartial)
        guard chargedFiat > 0 else {
            surfacePartialChargeRoutingFailure(message: "Invalid charge amount", stepId: "optimizingRoute")
            return
        }
        paymentPatchStep(id: "analyzingAssets", status: .success, detail: "Card + USDC balance")
        paymentPatchStep(id: "optimizingRoute", status: .loading)
        let usdcBal = payerUsdcBalance6ForChargePolicy(assets: assets)
        let cards = BeamioPaymentRouting.chargeableCards(from: assets, infraCard: merchantInfraCard)
        let partQrPartial = BeamioPaymentRouting.partitionPointsForMerchantCharge(cards: cards, merchantInfraCard: merchantInfraCard)
        let unitPoints6Partial = partQrPartial.unitPricePoints6
        let oracleInfraPartial = partQrPartial.oracleInfraCards
        let infraPoints6 = oracleInfraPartial.reduce(0) { $0 + (Int64($1.points6) ?? 0) }
        let split = BeamioPaymentRouting.computeChargeContainerSplit(
            amountBig: amountPartial,
            chargeTotalInPayCurrency: chargedFiat,
            payCurrency: payCurrency,
            oracle: oracle,
            unitPriceUSDC6: unitPrice,
            ccsaPoints6: unitPoints6Partial,
            infraPoints6: infraPoints6,
            infraCardCurrency: oracleInfraPartial.first?.cardCurrency,
            usdcBalance6: usdcBal
        )
        var items = BeamioPaymentRouting.buildPayItems(amountUsdc6: String(amountPartial), split: split, infraCard: merchantInfraCard)
        items = BeamioPaymentRouting.mergeInfraKind1Items(items, infraCard: merchantInfraCard)
        let beamio1155Wei = mergedInfraKind1Amount(from: items, infraCard: merchantInfraCard)
        let usdcWei = firstUsdcAmount6(from: items)
        let routeDetail: String
        if beamio1155Wei > 0, usdcWei > 0 {
            routeDetail = "Hybrid: points + USDC"
        } else if beamio1155Wei > 0 {
            routeDetail = "Points only"
        } else {
            routeDetail = "USDC only"
        }
        paymentPatchStep(id: "optimizingRoute", status: .success, detail: routeDetail)
        payload["items"] = items
        if payload["maxAmount"] == nil { payload["maxAmount"] = "0" }
        if payload["deadline"] == nil, let vb = payload["validBefore"] { payload["deadline"] = vb }
        let terminalAssets = await api.getWalletAssets(wallet: payeeWallet, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false, forPostPayment: false)
        let toAA = terminalAssets.aaAddress?.nilIfEmpty ?? (payload["to"] as? String)
        guard let toAA, looksLikeAddress(toAA) else {
            paymentPatchStep(id: "sendTx", status: .error, detail: "Merchant AA not found")
            isNfcBusy = false
            scanBanner = ""
            paymentTerminalError = "Merchant AA not found. Please ensure terminal is configured."
            homeToast = paymentTerminalError
            return
        }
        payload["to"] = toAA
        let currencyAmountStr = String(format: "%.2f", chargedFiat)
        let bill = scaledNfcBillForPartialCharge(ins: ins, chargedFiat: chargedFiat, payCurrency: payCurrency)
        paymentPatchStep(id: "sendTx", status: .loading)
        let res = await api.postAAtoEOA(
            openContainerPayload: payload,
            currency: payCurrency,
            currencyAmount: currencyAmountStr,
            merchantInfraCard: merchantInfraCard,
            chargeBill: bill
        )
        guard res.success else {
            let msg = res.error ?? "Payment failed"
            paymentPatchStep(id: "sendTx", status: .error, detail: msg)
            paymentPatchStep(id: "waitTx", status: .error, detail: "")
            isNfcBusy = false
            scanBanner = ""
            paymentTerminalError = msg
            homeToast = msg
            return
        }
        paymentPatchStep(id: "sendTx", status: .success, detail: "Sent")
        paymentPatchStep(id: "waitTx", status: .success, detail: "Transaction complete")
        paymentPatchStep(id: "refreshBalance", status: .loading, detail: "Fetching latest balance")
        let useInfraPost = split.ccsaPointsWei + split.infraPointsWei > 0
        let mNo = assets.memberNoPrimaryFromSortedCards().nilIfEmpty
        let shortfall = max(0, ins.chargeTotalInPayCurrency - chargedFiat)
        await completePaymentSuccessUi(
            amountTotal: chargedFiat,
            payee: toAA,
            txHash: res.txHash,
            subtotal: ins.subtotal,
            tip: ins.tip,
            payCurrency: payCurrency,
            memberNo: mNo,
            passCard: payCard,
            cardName: payCard?.cardName,
            tierName: payCard?.tierName,
            cardType: payCard?.cardType,
            settlementViaQr: true,
            taxPercent: ins.taxPercent,
            tierDiscountPercent: ins.tierDiscountPercent,
            useInfraCardPostBalance: useInfraPost,
            inlineInSheet: false,
            isPartialApproval: true,
            originalOrderTotal: ins.chargeTotalInPayCurrency,
            remainingShortfall: shortfall,
            fetchPostAssets: {
                await self.api.getWalletAssets(
                    wallet: account,
                    merchantInfraCard: self.merchantInfraCard,
                    merchantInfraOnly: false,
                    forPostPayment: true
                )
            }
        )
    }
}

private extension POSViewModel {
    /// Match `readBalanceBalanceDetailsCardNameLine` (ContentView) — strip generic ` CARD` suffixes.
    static func cleanedProgramCardNameLine(_ raw: String) -> String {
        let rawTrim = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if rawTrim.isEmpty { return "" }
        let n = rawTrim.replacingOccurrences(of: " CARD", with: "").replacingOccurrences(of: " Card", with: "")
        return n.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Row for `merchantInfraCard` in `getWalletAssets` — `cardName` comes from BeamioUserCard JSON metadata `name`.
    static func merchantProgramMetadataDisplayName(from assets: UIDAssets, merchantInfraCard infra: String) -> String? {
        let key = infra.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let card = assets.cards?.first {
            $0.cardAddress.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(key) == .orderedSame
        }
        guard let card else { return nil }
        let line = cleanedProgramCardNameLine(card.cardName)
        guard !line.isEmpty else { return nil }
        if line.caseInsensitiveCompare("Infrastructure card") == .orderedSame { return nil }
        if line.caseInsensitiveCompare("Asset Card") == .orderedSame { return nil }
        if line.caseInsensitiveCompare("Card") == .orderedSame { return nil }
        return line
    }

    func looksLikeAddress(_ s: String) -> Bool {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("0x"), t.count == 42 else { return false }
        let hex = t.dropFirst(2)
        return hex.allSatisfy { ch in
            ch.isASCII && ((ch >= "0" && ch <= "9") || (ch >= "a" && ch <= "f") || (ch >= "A" && ch <= "F"))
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}
