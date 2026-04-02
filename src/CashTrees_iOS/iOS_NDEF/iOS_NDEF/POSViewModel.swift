import AVFoundation
import Combine
import Foundation
import SwiftUI
import UIKit

@MainActor
final class POSViewModel: ObservableObject {
    let api = BeamioAPIClient()

    @Published var showWelcome = false
    @Published var showOnboarding = false

    @Published private(set) var walletPrivateKeyHex: String?
    @Published private(set) var walletAddress: String?

    @Published var merchantInfraCard: String = BeamioConstants.defaultBeamioUserCard
    @Published var terminalProfile: TerminalProfile?
    @Published var adminProfile: TerminalProfile?

    /// `nil` = unknown (align Android); `false` = no AA / welcome panel
    @Published var hasAAAccount: Bool?
    /// Today dashboard (getAdminStatsFull); `nil` = not loaded or RPC failed
    @Published var cardChargeAmount: Double?
    @Published var cardTopUpAmount: Double?
    @Published private(set) var homeStatsLoaded = false
    /// Pull-to-refresh on home: true while `refreshHomeProfiles` runs from user gesture.
    @Published private(set) var homePullRefreshing = false
    @Published var infraRoutingTaxPercent: Double?
    @Published var infraRoutingDiscountSummary: String?

    @Published var homeToast: String?
    /// 注册成功后展示一次（与 web Recovery QR 秘密等价，勿记入日志）
    @Published var pendingRecoveryCode: String?

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
    @Published var chargeTipRateBps: Int = 0

    @Published var scanMethod: ScanMethod = .nfc
    @Published var pendingScanAction: ScanPendingAction = .read
    @Published var isNfcBusy = false
    @Published var scanBanner: String = ""

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

    private let nfc = BeamioNFCSession()

    /// Per-install sandbox marker. UserDefaults is wiped when the user deletes the app, but Keychain
    /// entries for the same bundle ID often survive reinstall on device; clear orphans so init flow runs.
    private static let installContainerMarkerKey = "iosndef.install.container.marker"

    init() {
        reconcileKeychainWithAppContainer()

        if let hex = BeamioKeychain.loadPrivateKeyHex() {
            walletPrivateKeyHex = hex
            walletAddress = try? BeamioEthWallet.address(fromPrivateKeyHex: hex)
            showWelcome = false
            showOnboarding = false
        } else {
            showWelcome = true
            showOnboarding = false
        }

        nfc.onMessage = { [weak self] result in
            Task { @MainActor in
                await self?.handleNfcResult(result)
            }
        }

        Task { await refreshInfraCardFromDbIfPossible() }
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
            pendingRecoveryCode = payload.recoveryCode
            showOnboarding = false
            showWelcome = false
            Task { await refreshInfraCardFromDbIfPossible() }
            Task { await refreshHomeProfiles() }
        } catch {
            homeToast = error.localizedDescription
        }
    }

    private static func passwordRuleChecks(_ password: String) -> (len8: Bool, mixed: Bool, numbers: Bool) {
        let len8 = password.count >= 8
        let mixed = password.range(of: "[a-z]", options: .regularExpression) != nil
            && password.range(of: "[A-Z]", options: .regularExpression) != nil
        let numbers = password.range(of: "[0-9]", options: .regularExpression) != nil
        return (len8, mixed, numbers)
    }

    func goCreateWallet() {
        showWelcome = false
        showOnboarding = true
    }

    func refreshHomeProfiles() async {
        guard let w = walletAddress else { return }
        await refreshInfraCardFromDbIfPossible()
        let infra = merchantInfraCard
        async let term = api.searchUsers(keyward: w)
        async let assetsForAA = api.getWalletAssets(wallet: w, merchantInfraCard: infra, merchantInfraOnly: false, forPostPayment: false)
        async let stats = api.fetchAdminStatsDayChargeAndTopUp(wallet: w, infraCard: infra)
        async let routing = api.fetchInfraRoutingSummary(wallet: w, infraCard: infra)

        let adminInfo = await api.fetchCardAdminInfo(cardAddress: infra, wallet: w)
        let adminAddr = adminInfo?.upperAdmin?.nilIfEmpty ?? adminInfo?.owner?.nilIfEmpty
        var adminProf: TerminalProfile?
        if let adminAddr { adminProf = await api.searchUsers(keyward: adminAddr) }
        terminalProfile = await term
        adminProfile = adminProf

        let ast = await assetsForAA
        if ast.ok {
            hasAAAccount = ast.aaAddress?.nilIfEmpty != nil
        } else {
            hasAAAccount = true
        }

        let st = await stats
        cardChargeAmount = st.charge
        cardTopUpAmount = st.topUp
        homeStatsLoaded = true

        if let r = await routing {
            infraRoutingTaxPercent = r.tax
            infraRoutingDiscountSummary = r.discountSummary
        }
    }

    /// Home scroll pull-to-refresh: sets `homePullRefreshing` for UI until refresh completes.
    func refreshHomeProfilesPullToRefresh() async {
        homePullRefreshing = true
        defer { homePullRefreshing = false }
        await refreshHomeProfiles()
    }

    /// Android: LaunchedEffect 15s `fetchInfraRoutingForTerminalWalletSync` while on home
    func pollInfraRoutingIfStillOnHome() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 15_000_000_000)
            if Task.isCancelled { break }
            guard let w = walletAddress else { break }
            await refreshInfraCardFromDbIfPossible()
            let infra = merchantInfraCard
            if let r = await api.fetchInfraRoutingSummary(wallet: w, infraCard: infra) {
                infraRoutingTaxPercent = r.tax
                infraRoutingDiscountSummary = r.discountSummary
            }
        }
    }

    func copyWalletToPasteboard() {
        guard let w = walletAddress else { return }
        UIPasteboard.general.string = w
    }

    func refreshInfraCardFromDbIfPossible() async {
        guard let w = walletAddress else { return }
        if let addr = await api.fetchMyPosAddress(wallet: w), looksLikeAddress(addr) {
            merchantInfraCard = addr
        }
    }

    func beginReadBalance() {
        pendingScanAction = .read
        scanMethod = .nfc
        sheet = .scan(.read)
        startNfcIfNeeded()
    }

    func beginTopUp() {
        pendingScanAction = .topup
        scanMethod = .nfc
        sheet = .scan(.topup)
        startNfcIfNeeded()
    }

    func beginCharge(amount: String, tipBps: Int) {
        amountString = amount
        chargeTipRateBps = tipBps
        pendingScanAction = .payment
        scanMethod = .nfc
        sheet = .scan(.payment)
        startNfcIfNeeded()
    }

    func beginLinkApp() {
        pendingScanAction = .linkApp
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
            scanBanner = "Use NFC to scan the customer card."
        }
    }

    enum QrReadMode { case read, topup }

    private func handleReadOrTopupQr(_ text: String, mode: QrReadMode) async {
        let url = URL(string: text)
        let beamio = url.flatMap { BeamioOpenContainerQR.parseBeamioTab(from: $0) }
        let wallet = url.flatMap { BeamioOpenContainerQR.parseBeamioWallet(from: $0) }
        guard beamio != nil || wallet != nil else {
            scanBanner = "Cannot parse URL. Please scan a beamio.app link"
            return
        }
        isNfcBusy = true
        scanBanner = "Loading..."
        await refreshInfraCardFromDbIfPossible()
        let assets: UIDAssets
        let rawJson: String?
        if let beamio {
            (assets, rawJson) = await api.getUIDAssetsWithRawJson(uid: beamio, sun: nil, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false)
        } else {
            (assets, rawJson) = await api.getWalletAssetsWithRawJson(wallet: wallet!, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false, forPostPayment: false)
        }
        isNfcBusy = false
        if mode == .read {
            if assets.ok {
                lastReadAssets = assets
                lastReadRawJson = rawJson
                lastReadViaQr = true
                lastReadError = nil
                sheet = .readResult
            } else {
                lastReadError = assets.error ?? "Query failed"
                scanBanner = lastReadError ?? "Error"
            }
        } else {
            guard let key = walletPrivateKeyHex else {
                scanBanner = "Wallet not initialized"
                return
            }
            if let beamio {
                await runTopup(beamioTag: beamio, wallet: nil, privateKeyHex: key)
            } else if let wallet {
                await runTopup(beamioTag: nil, wallet: wallet, privateKeyHex: key)
            }
        }
    }

    private func handlePaymentQr(_ text: String) async {
        let parsed = BeamioOpenContainerQR.parse(text)
        guard var payload = parsed.payload else {
            scanBanner = humanizeQrError(parsed.rejectReason ?? "unknown")
            return
        }
        guard let w = walletAddress else {
            scanBanner = "Wallet not initialized"
            return
        }
        let subtotal = Double(amountString) ?? 0
        guard subtotal > 0 else {
            scanBanner = "Please enter amount first"
            return
        }
        await refreshInfraCardFromDbIfPossible()
        let account = (payload["account"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !account.isEmpty else {
            scanBanner = "Invalid payment code"
            return
        }
        isNfcBusy = true
        scanBanner = "Routing payment..."
        let assets = await api.getWalletAssets(wallet: account, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false, forPostPayment: false)
        guard assets.ok else {
            isNfcBusy = false
            scanBanner = assets.error ?? "Unable to fetch customer assets"
            return
        }
        let oracle = await api.fetchOracle().toPaymentOracle()
        let payeeWallet = w
        let request = subtotal
        let tip = BeamioPaymentRouting.chargeTipFromRequestAndBps(requestAmount: request, tipRateBps: chargeTipRateBps)
        let taxP = 0.0
        let disc = 0
        let total = BeamioPaymentRouting.chargeTotalInCurrency(requestAmount: request, taxPercent: taxP, tierDiscountPercent: disc, tipAmount: tip)
        let payCard = assets.cards?.first
        let payCurrency = payCard?.cardCurrency ?? assets.cardCurrency ?? "CAD"
        let amountUsdc6 = BeamioPaymentRouting.currencyToUsdc6(amount: total, currency: payCurrency, oracle: oracle)
        guard amountUsdc6 != "0", let entered = Int64(amountUsdc6), entered > 0 else {
            isNfcBusy = false
            scanBanner = "Amount conversion failed"
            return
        }
        let unitPriceStr = assets.unitPriceUSDC6 ?? "0"
        let unitPrice = Int64(unitPriceStr) ?? 0
        let cards = BeamioPaymentRouting.chargeableCards(from: assets, infraCard: merchantInfraCard)
        let ccsaCards = cards.filter { $0.cardType == "ccsa" || $0.cardAddress.caseInsensitiveCompare(merchantInfraCard) == .orderedSame }
        let infraCards = cards.filter { $0.cardType == "infrastructure" || $0.cardAddress.caseInsensitiveCompare(merchantInfraCard) == .orderedSame }
        let ccsaPoints6 = ccsaCards.reduce(0) { $0 + (Int64($1.points6) ?? 0) }
        let infraPoints6 = infraCards.reduce(0) { $0 + (Int64($1.points6) ?? 0) }
        let usdcBal = Int64(((Double(assets.usdcBalance ?? "0") ?? 0) * 1_000_000.0).rounded())
        let ccsaValue = (ccsaPoints6 > 0 && unitPrice > 0) ? (ccsaPoints6 * unitPrice) / 1_000_000 : 0
        let infraValue = infraCards.reduce(0) { partial, c in
            partial + BeamioPaymentRouting.points6ToUsdc6(points6: Int64(c.points6) ?? 0, cardCurrency: c.cardCurrency, oracle: oracle)
        }
        let totalBal = ccsaValue + infraValue + usdcBal
        guard totalBal >= entered else {
            isNfcBusy = false
            scanBanner = "Insufficient customer balance"
            return
        }
        let split = BeamioPaymentRouting.computeChargeContainerSplit(
            amountBig: entered,
            chargeTotalInPayCurrency: total,
            payCurrency: payCurrency,
            oracle: oracle,
            unitPriceUSDC6: unitPrice,
            ccsaPoints6: ccsaPoints6,
            infraPoints6: infraPoints6,
            infraCardCurrency: infraCards.first?.cardCurrency,
            usdcBalance6: usdcBal
        )
        var items = BeamioPaymentRouting.buildPayItems(amountUsdc6: amountUsdc6, split: split, infraCard: merchantInfraCard)
        items = BeamioPaymentRouting.mergeInfraKind1Items(items, infraCard: merchantInfraCard)
        payload["items"] = items
        if payload["maxAmount"] == nil { payload["maxAmount"] = "0" }
        if payload["deadline"] == nil, let vb = payload["validBefore"] { payload["deadline"] = vb }
        let terminalAssets = await api.getWalletAssets(wallet: payeeWallet, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false, forPostPayment: false)
        let toAA = terminalAssets.aaAddress?.nilIfEmpty ?? (payload["to"] as? String)
        guard let toAA, looksLikeAddress(toAA) else {
            isNfcBusy = false
            scanBanner = "Merchant AA not found"
            return
        }
        payload["to"] = toAA
        let currencyAmountStr = String(format: "%.2f", total)
        let bill: [String: Any] = [
            "nfcSubtotalCurrencyAmount": String(format: "%.2f", request),
            "nfcRequestCurrency": payCurrency,
            "nfcTaxAmountFiat6": "0",
            "nfcTaxRateBps": 0,
            "nfcDiscountAmountFiat6": "0",
            "nfcDiscountRateBps": 0,
        ].merging(
            tip > 0
                ? [
                    "nfcTipCurrencyAmount": String(format: "%.2f", tip),
                    "nfcTipRateBps": chargeTipRateBps,
                ]
                : [:],
            uniquingKeysWith: { $1 }
        )
        let res = await api.postAAtoEOA(
            openContainerPayload: payload,
            currency: payCurrency,
            currencyAmount: currencyAmountStr,
            merchantInfraCard: merchantInfraCard,
            chargeBill: bill
        )
        guard res.success else {
            isNfcBusy = false
            let msg = res.error ?? "Payment failed"
            scanBanner = msg
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

    private func humanizeQrError(_ r: String) -> String {
        if r.hasPrefix("not a JSON") { return "Invalid QR: data is not valid JSON." }
        if r.contains("missing or empty account") { return "Invalid QR: missing customer account." }
        if r.contains("missing or empty signature") { return "Invalid QR: missing payment signature." }
        if r.contains("neither open relay") { return "Invalid QR: unrecognized payment format." }
        return "Could not read payment code."
    }

    private func handleNfcResult(_ result: Result<(url: URL, raw: String), Error>) async {
        switch result {
        case let .failure(err):
            scanBanner = err.localizedDescription
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
        let sun = BeamioSunParser.sunParams(from: url)
        let uid =
            sun?.uid
            ?? BeamioSunParser.uidHexPreview(from: url)
            ?? ""
        guard !uid.isEmpty else {
            scanBanner = "Cannot read UID from NDEF URL"
            return
        }
        isNfcBusy = true
        scanBanner = "Querying..."
        let (assets, rawJson) = await api.getUIDAssetsWithRawJson(uid: uid, sun: sun, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false)
        isNfcBusy = false
        if assets.ok {
            lastReadAssets = assets
            lastReadRawJson = rawJson
            lastReadViaQr = false
            lastReadError = nil
            sheet = .readResult
        } else {
            lastReadError = assets.error ?? "Query failed"
            scanBanner = lastReadError ?? "Error"
        }
    }

    private func handleNfcTopup(url: URL) async {
        guard let key = walletPrivateKeyHex else {
            scanBanner = "Wallet not initialized"
            return
        }
        let sun = BeamioSunParser.sunParams(from: url)
        let uid =
            sun?.uid
            ?? BeamioSunParser.uidHexPreview(from: url)
            ?? ""
        guard let sun else {
            scanBanner = "Card does not support SUN. Cannot top up."
            return
        }
        guard !uid.isEmpty else {
            scanBanner = "Cannot read UID"
            return
        }
        await runTopup(beamioTag: nil, wallet: nil, uid: uid, sun: sun, privateKeyHex: key)
    }

    private func runTopup(beamioTag: String?, wallet: String?, uid: String? = nil, sun: SunParams? = nil, privateKeyHex: String) async {
        let amt = amountString
        guard Double(amt) ?? 0 > 0 else {
            scanBanner = "Invalid amount"
            return
        }
        isNfcBusy = true
        scanBanner = "Sign & execute…"
        await refreshInfraCardFromDbIfPossible()
        let infra = merchantInfraCard

        if let beamioTag {
            let tagPrep = await api.nfcTopupPrepare(
                uid: nil,
                wallet: nil,
                beamioTag: beamioTag,
                amount: amt,
                sun: nil,
                infraCard: infra
            )
            if let err = tagPrep.error {
                isNfcBusy = false
                scanBanner = err
                return
            }
            guard let resolvedWallet = tagPrep.wallet else {
                isNfcBusy = false
                scanBanner = "Server did not return wallet. Please retry"
                return
            }
            guard let cardAddr = tagPrep.cardAddr, let data = tagPrep.data,
                  let deadline = tagPrep.deadline, let nonce = tagPrep.nonce
            else {
                isNfcBusy = false
                scanBanner = "Prepare failed"
                return
            }

            let preAssets = await api.getWalletAssets(
                wallet: resolvedWallet,
                merchantInfraCard: infra,
                merchantInfraOnly: false,
                forPostPayment: false
            )
            guard preAssets.ok else {
                isNfcBusy = false
                scanBanner = preAssets.error ?? "Query failed"
                return
            }
            let preCard = preAssets.cards?.first { $0.cardAddress.caseInsensitiveCompare(cardAddr) == .orderedSame }
            let preBal = preCard?.points ?? preAssets.points ?? "0"
            let cur = preCard?.cardCurrency ?? preAssets.cardCurrency ?? "CAD"
            let custAddr = preAssets.address

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
                isNfcBusy = false
                scanBanner = error.localizedDescription
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
                sun: nil
            )
            guard payBeamio.success else {
                isNfcBusy = false
                scanBanner = payBeamio.error ?? "Top-up failed"
                homeToast = scanBanner
                return
            }

            await completeTopupSuccessUi(
                amount: amt,
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
                amount: amt,
                sun: nil,
                infraCard: infra
            )
            if prep.error != nil {
                _ = await api.ensureAAForEOA(eoa: wallet)
                prep = await api.nfcTopupPrepare(
                    uid: nil,
                    wallet: wallet,
                    beamioTag: nil,
                    amount: amt,
                    sun: nil,
                    infraCard: infra
                )
            }
            guard prep.error == nil, let cardAddr = prep.cardAddr, let data = prep.data,
                  let deadline = prep.deadline, let nonce = prep.nonce
            else {
                isNfcBusy = false
                scanBanner = prep.error ?? "Prepare failed"
                return
            }

            let preWalletAssets = await api.getWalletAssets(
                wallet: wallet,
                merchantInfraCard: infra,
                merchantInfraOnly: false,
                forPostPayment: false
            )
            guard preWalletAssets.ok else {
                isNfcBusy = false
                scanBanner = preWalletAssets.error ?? "Query failed"
                return
            }
            let preCardW = preWalletAssets.cards?.first { $0.cardAddress.caseInsensitiveCompare(cardAddr) == .orderedSame }
            let preBalW = preCardW?.points ?? preWalletAssets.points ?? "0"
            let curW = preCardW?.cardCurrency ?? preWalletAssets.cardCurrency ?? "CAD"
            let custAddrW = preWalletAssets.address

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
                isNfcBusy = false
                scanBanner = error.localizedDescription
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
                sun: nil
            )
            guard payW.success else {
                isNfcBusy = false
                scanBanner = payW.error ?? "Top-up failed"
                homeToast = scanBanner
                return
            }
            await completeTopupSuccessUi(
                amount: amt,
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
            isNfcBusy = false
            scanBanner = "Cannot read UID"
            return
        }

        prep = await api.nfcTopupPrepare(
            uid: uidN,
            wallet: nil,
            beamioTag: nil,
            amount: amt,
            sun: sunN,
            infraCard: infra
        )

        guard prep.error == nil, let cardAddr = prep.cardAddr, let data = prep.data,
              let deadline = prep.deadline, let nonce = prep.nonce
        else {
            isNfcBusy = false
            scanBanner = prep.error ?? "Prepare failed"
            return
        }

        let preUidAssets = await api.getUIDAssets(
            uid: uidN,
            sun: sunN,
            merchantInfraCard: infra,
            merchantInfraOnly: false
        )
        guard preUidAssets.ok else {
            isNfcBusy = false
            scanBanner = preUidAssets.error ?? "Query failed"
            return
        }
        let preCardN = preUidAssets.cards?.first { $0.cardAddress.caseInsensitiveCompare(cardAddr) == .orderedSame }
        let preBalN = preCardN?.points ?? preUidAssets.points ?? "0"
        let curN = preCardN?.cardCurrency ?? preUidAssets.cardCurrency ?? "CAD"
        let custAddrN = preUidAssets.address

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
            isNfcBusy = false
            scanBanner = error.localizedDescription
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
            sun: sunN
        )
        guard payN.success else {
            isNfcBusy = false
            scanBanner = payN.error ?? "Top-up failed"
            homeToast = scanBanner
            return
        }

        await completeTopupSuccessUi(
            amount: amt,
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
        let memberNo = postCard?.formattedMemberNumber() ?? ""
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
            settlementViaQr: settlementViaQr
        )
        isNfcBusy = false
        scanBanner = ""
        nfc.invalidate()
        sheet = nil
        topupSuccess = state
    }

    private func handleNfcPayment(url: URL) async {
        guard walletPrivateKeyHex != nil else {
            scanBanner = "Wallet not initialized"
            return
        }
        let sun = BeamioSunParser.sunParams(from: url)
        let uid =
            sun?.uid
            ?? BeamioSunParser.uidHexPreview(from: url)
            ?? ""
        guard !uid.isEmpty else {
            scanBanner = "Cannot read UID"
            return
        }
        let subtotal = Double(amountString) ?? 0
        guard subtotal > 0 else {
            scanBanner = "Invalid amount"
            return
        }
        isNfcBusy = true
        scanBanner = "Paying…"
        await refreshInfraCardFromDbIfPossible()
        let assets = await api.getUIDAssets(uid: uid, sun: sun, merchantInfraCard: merchantInfraCard, merchantInfraOnly: false)
        guard assets.ok else {
            isNfcBusy = false
            scanBanner = assets.error ?? "Card not registered"
            return
        }
        let oracle = await api.fetchOracle().toPaymentOracle()
        let payee = walletAddress ?? ""
        let payCard = assets.cards?.first
        let payCurrency = payCard?.cardCurrency ?? assets.cardCurrency ?? "CAD"
        let tip = BeamioPaymentRouting.chargeTipFromRequestAndBps(requestAmount: subtotal, tipRateBps: chargeTipRateBps)
        let taxP = 0.0
        let disc = 0
        let total = BeamioPaymentRouting.chargeTotalInCurrency(requestAmount: subtotal, taxPercent: taxP, tierDiscountPercent: disc, tipAmount: tip)
        let amountUsdc6 = BeamioPaymentRouting.currencyToUsdc6(amount: total, currency: payCurrency, oracle: oracle)
        guard let amountBig = Int64(amountUsdc6), amountBig > 0 else {
            isNfcBusy = false
            scanBanner = "Amount conversion failed"
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
            isNfcBusy = false
            scanBanner = (prep["error"] as? String) ?? "Prepare failed"
            return
        }
        let usdcBal = Int64(((Double(assets.usdcBalance ?? "0") ?? 0) * 1_000_000.0).rounded())
        let cards = BeamioPaymentRouting.chargeableCards(from: assets, infraCard: merchantInfraCard)
        let ccsaCards = cards.filter { $0.cardType == "ccsa" || $0.cardAddress.caseInsensitiveCompare(merchantInfraCard) == .orderedSame }
        let infraCards = cards.filter { $0.cardType == "infrastructure" || $0.cardAddress.caseInsensitiveCompare(merchantInfraCard) == .orderedSame }
        let ccsaPointsStr = ccsaCards.reduce(0) { $0 + (Int64($1.points6) ?? 0) }
        let infraPointsStr = infraCards.reduce(0) { $0 + (Int64($1.points6) ?? 0) }
        let ccsaValue = (ccsaPointsStr > 0 && unitPrice > 0) ? (ccsaPointsStr * unitPrice) / 1_000_000 : 0
        let infraValue = infraCards.reduce(0) { partial, c in
            partial + BeamioPaymentRouting.points6ToUsdc6(points6: Int64(c.points6) ?? 0, cardCurrency: c.cardCurrency, oracle: oracle)
        }
        let totalBal = ccsaValue + infraValue + usdcBal
        guard totalBal >= amountBig else {
            isNfcBusy = false
            scanBanner = "Insufficient balance"
            return
        }
        let split = BeamioPaymentRouting.computeChargeContainerSplit(
            amountBig: amountBig,
            chargeTotalInPayCurrency: total,
            payCurrency: payCurrency,
            oracle: oracle,
            unitPriceUSDC6: unitPrice,
            ccsaPoints6: ccsaPointsStr,
            infraPoints6: infraPointsStr,
            infraCardCurrency: infraCards.first?.cardCurrency,
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
        let discFiat6 = Int64((subtotal * Double(disc) / 100.0 * 1_000_000.0).rounded())
        var bill: [String: Any] = [
            "nfcSubtotalCurrencyAmount": String(format: "%.2f", subtotal),
            "nfcRequestCurrency": payCurrency,
            "nfcTaxAmountFiat6": String(taxFiat6),
            "nfcTaxRateBps": Int((taxP * 100.0).rounded()),
            "nfcDiscountAmountFiat6": String(discFiat6),
            "nfcDiscountRateBps": disc * 100,
        ]
        if tip > 0 {
            bill["nfcTipCurrencyAmount"] = String(format: "%.2f", tip)
            if chargeTipRateBps > 0 { bill["nfcTipRateBps"] = chargeTipRateBps }
        }
        let pay = await api.payByNfcUidSignContainer(
            uid: uid,
            containerPayload: container,
            amountUsdc6: amountUsdc6,
            sun: sun,
            nfcBill: bill
        )
        guard pay.success else {
            isNfcBusy = false
            let msg = pay.error ?? "Payment failed"
            scanBanner = msg
            homeToast = msg
            return
        }
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

    /// Android: NFC sleep 3s, QR sleep 5s — 再拉余额并推出 `PaymentSuccessContent`。
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
        tierDiscountPercent: Int,
        useInfraCardPostBalance: Bool,
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
            tableNumber: nil
        )
        isNfcBusy = false
        scanBanner = ""
        nfc.invalidate()
        sheet = nil
        chargeSuccess = state
    }

    private func handleNfcLinkApp(url: URL) async {
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
            scanBanner = "Cancelled. Tap NFC again."
            homeToast = "Link lock cancelled"
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
    }

    func dismissTopupSuccess() {
        topupSuccess = nil
    }

    func dismissChargeSuccess() {
        chargeSuccess = nil
    }

    /// Switch between Tap Card and Scan QR while sheet is open.
    func setScanMethod(_ m: ScanMethod) {
        scanMethod = m
        if m == .nfc {
            scanBanner = "Hold the customer's NTAG 424 DNA card near the NFC sensor."
            nfc.begin()
        } else {
            nfc.invalidate()
            scanBanner = "Point the camera at the QR code."
        }
    }
}

private extension POSViewModel {
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
