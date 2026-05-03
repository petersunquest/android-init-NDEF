//
//  ContentView.swift
//  iOS_NDEF
//
//  Beamio POS: welcome / onboarding / home / amount / tip / NFC+QR scan (aligns with Android MainActivity flows).
//

import SwiftUI
import UIKit
import CoreImage
import PhotosUI
import Vision

// MARK: - Haptics (UIImpactFeedbackGenerator)

/// Link App success QR (align Android `encodeLinkAppQrBitmap`).
private enum BeamioLinkAppQr {
    /// `scale`: device pixel density from `Environment(\.displayScale)` (avoid deprecated `UIScreen.main` on iOS 26+).
    static func image(from string: String, pointSize: CGFloat, scale: CGFloat) -> UIImage? {
        guard let data = string.data(using: .utf8),
              let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard var output = filter.outputImage else { return nil }
        let pixelScale = (pointSize * scale) / output.extent.width
        output = output.transformed(by: CGAffineTransform(scaleX: pixelScale, y: pixelScale))
        let ctx = CIContext()
        guard let cg = ctx.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cg, scale: scale, orientation: .up)
    }
}

/// Reuses one `UIImpactFeedbackGenerator` per style (Apple recommends this for reliable feedback).
/// iPhone SE uses a smaller Taptic subsystem than Pro models — still weaker even with full intensity.
private enum BeamioHaptic {
    private static let lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private static let mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private static let heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)

    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let generator: UIImpactFeedbackGenerator = {
            switch style {
            case .light: return lightGenerator
            case .medium: return mediumGenerator
            case .heavy: return heavyGenerator
            case .soft, .rigid:
                return UIImpactFeedbackGenerator(style: style)
            @unknown default:
                return mediumGenerator
            }
        }()
        generator.prepare()
        generator.impactOccurred(intensity: 1.0)
    }

    static func light() { impact(.light) }
    static func medium() { impact(.medium) }
}

/// Plain button appearance with tactile feedback on press (SwiftUI fires action on release; haptic tracks `isPressed`).
private struct BeamioHapticPlainButtonStyle: ButtonStyle {
    var impact: UIImpactFeedbackGenerator.FeedbackStyle = .medium

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .onChange(of: configuration.isPressed) { _, pressed in
                guard pressed else { return }
                BeamioHaptic.impact(impact)
            }
    }
}

struct ContentView: View {
    @StateObject private var vm = POSViewModel()
    @State private var amountFlow: AmountFlow?
    @State private var toastPresented = false
    @State private var primarySurfaceDidAppear = false
    @State private var launchContentVisible = false
    @State private var postLaunchSurfacesAllowed = false
    @State private var launchSurfaceUnlockCycle = 0
    private let postLaunchSurfaceHoldDelay: Double = 0.0

    var body: some View {
        ZStack {
            Color(red: 0 / 255, green: 4 / 255, blue: 20 / 255)
                .ignoresSafeArea()

            Group {
                if vm.showWelcome {
                    VerraEntrySplashView(
                        vm: vm,
                        onGetStarted: { prefill in
                            vm.goCreateWallet(prefillNormalizedHandle: prefill.isEmpty ? nil : prefill)
                        }
                    )
                    .onAppear {
                        primarySurfaceDidAppear = true
                    }
                } else if vm.showOnboarding {
                    ZStack {
                        OnboardingView(
                            vm: vm,
                            onBack: {
                                vm.showVerraWorkspaceGateway = false
                                vm.clearSplashParentForTerminalSetup()
                                vm.showWelcome = true
                                vm.showOnboarding = false
                            }
                        )
                        .onAppear {
                            primarySurfaceDidAppear = true
                        }
                        if vm.showVerraWorkspaceGateway {
                            VerraBizWorkspaceGatewayView(vm: vm) {
                                vm.showVerraWorkspaceGateway = false
                            }
                            .transition(.opacity)
                            .zIndex(1)
                        }
                    }
                } else if !vm.showAwaitingParentPermissionGate {
                    HomeRootView(vm: vm, amountFlow: $amountFlow)
                        .onAppear {
                            primarySurfaceDidAppear = true
                        }
                } else {
                    Color(uiColor: .systemBackground)
                        .ignoresSafeArea()
                        .accessibilityHidden(true)
                }
            }
            .opacity(launchContentVisible ? 1 : 0)

            LaunchBrandSplashOverlay(
                shouldParticipate: true,
                isVisible: vm.showLaunchSplash,
                primaryContentReady: primarySurfaceDidAppear,
                onDismissCompleted: {
                    let cycle = launchSurfaceUnlockCycle
                    DispatchQueue.main.asyncAfter(deadline: .now() + postLaunchSurfaceHoldDelay) {
                        guard cycle == launchSurfaceUnlockCycle else { return }
                        guard !vm.showLaunchSplash else { return }
                        postLaunchSurfacesAllowed = true
                        withAnimation(.easeIn(duration: 0.22)) {
                            launchContentVisible = true
                        }
                    }
                }
            )
                .zIndex(0.9)

            if vm.showAwaitingParentPermissionGate && postLaunchSurfacesAllowed {
                AwaitingParentWorkspacePermissionOverlay(vm: vm)
                    .transition(.opacity)
                    .zIndex(0.95)
            }

            if let s = vm.sheet {
                SheetHost(vm: vm, sheet: s, amountFlow: $amountFlow)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }

            if case .some(.topup) = amountFlow {
                TopupAmountPadFullPage(
                    topupPolicy: vm.posTerminalPolicy,
                    onCancel: { amountFlow = nil },
                    onContinue: { method, bonusExpanded, bonusRate, keypadAmount in
                        amountFlow = nil
                        guard let split = BeamioAPIClient.nfcTopupCurrencySplitFromPosKeypad(
                            keypadAmount: keypadAmount,
                            methodRaw: method.rawValue,
                            bonusExpanded: bonusExpanded,
                            selectedBonusRate: bonusRate
                        ) else { return }
                        vm.amountString = split.currencyAmount
                        vm.topupPaymentMethodTitle = method.title
                        vm.pendingTopupMethodRaw = method.rawValue
                        vm.pendingTopupBonusExpanded = bonusExpanded
                        vm.pendingTopupBonusRatePercent = bonusRate
                        vm.pendingTopupKeypadAmount = keypadAmount
                        vm.beginTopUp()
                    }
                )
                .transition(.move(edge: .trailing))
                .zIndex(2)
            }

            if case .some(.charge) = amountFlow {
                ChargeAmountTipNavigationSheet(
                    chargePolicy: vm.posTerminalPolicy,
                    onCancel: { amountFlow = nil },
                    onChargeComplete: { amount, tipBps, methodRaw in
                        amountFlow = nil
                        vm.beginCharge(amount: amount, tipBps: tipBps, methodRaw: methodRaw)
                    }
                )
                .transition(.move(edge: .trailing))
                .zIndex(2)
            }

            if case .some(.transactions) = amountFlow {
                POSTransactionsScreen(
                    vm: vm,
                    onClose: { amountFlow = nil }
                )
                .transition(.move(edge: .trailing))
                .zIndex(2)
            }
        }
        .animation(.easeOut(duration: 0.22), value: vm.showAwaitingParentPermissionGate)
        .animation(.easeInOut(duration: 0.32), value: vm.sheet?.id)
        .animation(.easeInOut(duration: 0.32), value: amountFlow?.id)
        .fullScreenCover(item: Binding(
            get: { vm.topupSuccess },
            set: { vm.topupSuccess = $0 }
        )) { state in
            TopupSuccessView(state: state) {
                vm.dismissTopupSuccess()
                Task { @MainActor in
                    await vm.refreshHomeProfiles()
                }
            }
        }
        .fullScreenCover(item: Binding(
            get: { vm.chargeSuccess },
            set: { vm.chargeSuccess = $0 }
        )) { state in
            PaymentSuccessView(
                state: state,
                onDone: {
                    vm.dismissChargeSuccess()
                    Task { @MainActor in
                        await vm.refreshHomeProfiles()
                    }
                },
                onContinueRemainingCharge: state.isPartialApproval
                    ? {
                        vm.dismissChargeSuccess()
                        vm.continueChargeAfterPartialApproval()
                    }
                    : nil
            )
        }
        .fullScreenCover(item: Binding(
            get: { vm.chargeInsufficientFunds },
            set: { vm.chargeInsufficientFunds = $0 }
        )) { state in
            ChargeInsufficientFundsView(
                state: state,
                onClose: { vm.dismissChargeInsufficientFunds() },
                onTopUp: { vm.topUpAfterInsufficientFunds() },
                onChargeAvailable: { vm.chargeAvailableBalanceAfterInsufficientFunds() }
            )
        }
        .onChange(of: vm.homeToast) { _, new in
            toastPresented = new != nil
        }
        .alert("Notice", isPresented: $toastPresented) {
            Button("OK", role: .cancel) {
                BeamioHaptic.light()
                vm.homeToast = nil
            }
        } message: {
            Text(vm.homeToast ?? "")
        }
        .fullScreenCover(isPresented: Binding(
            get: { vm.pendingRecoveryCode != nil },
            set: { if !$0 { vm.pendingRecoveryCode = nil } }
        )) {
            RecoveryKeySheet(code: vm.pendingRecoveryCode ?? "")
        }
        .sheet(isPresented: $vm.changeParentWorkspaceAdminSheetPresented) {
            NavigationStack {
                ChangeParentWorkspaceAdminSheet(vm: vm)
            }
            .presentationDetents([.large])
        }
        .onAppear {
            launchSurfaceUnlockCycle += 1
            launchContentVisible = false
            postLaunchSurfacesAllowed = false
        }
        .onChange(of: vm.showLaunchSplash) { _, newValue in
            if newValue {
                launchSurfaceUnlockCycle += 1
                launchContentVisible = false
                postLaunchSurfacesAllowed = false
            }
        }
        .onChange(of: vm.showWelcome) { _, newValue in
            if newValue {
                primarySurfaceDidAppear = false
            }
        }
        .onChange(of: vm.showOnboarding) { _, newValue in
            if newValue {
                primarySurfaceDidAppear = false
            }
        }
    }
}

/// Matches `LaunchScreen.storyboard`: centered brand mark until Home is ready.
/// Background must match the dark-navy fill in `LaunchBrandLogo` artwork
/// so the storyboard → SwiftUI handoff is a seamless single image.
///
/// Dismissal is a two-phase handoff:
/// 1. While loading, render a full-screen dark backdrop + centered brand logo.
/// 2. After the first real surface is on screen, keep that full-screen launch
///    layer mounted, then scale the logo up while fading the ENTIRE launch
///    layer away so the underlying app appears as a true fade-in.
///
/// Keep this active for welcome/onboarding/home alike. The earlier bug was not
/// animation timing; it was that the splash layer was incorrectly excluded when
/// startup landed on the welcome flow during debug installs.
private struct LaunchBrandSplashOverlay: View {
    let shouldParticipate: Bool
    let isVisible: Bool
    let primaryContentReady: Bool
    let onDismissCompleted: () -> Void

    private let brandBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)
    private let launchBackground = Color(red: 0 / 255, green: 4 / 255, blue: 20 / 255)

    /// Observation mode: faster handoff timing to evaluate the logo motion
    /// itself against the black launch background.
    private let burstDelayAfterPrimaryContentReady: Double = 0.27
    private let burstTargetScale: CGFloat = 2.7
    private let burstDuration: Double = 0.51

    private enum Phase {
        case hidden
        case fullScreen
        case dismissing
    }

    @State private var phase: Phase = .hidden
    @State private var logoScale: CGFloat = 1.0
    @State private var overlayOpacity: CGFloat = 1.0
    @State private var didSatisfyVisibleBeat = false
    @State private var pendingDismissAfterVisibleBeat = false
    @State private var presentationCycle = 0

    var body: some View {
        Group {
            switch phase {
            case .hidden:
                EmptyView()
            case .fullScreen:
                splashBody(showSpinner: true)
                    .allowsHitTesting(true)
            case .dismissing:
                splashBody(showSpinner: false)
                    .opacity(overlayOpacity)
                    .allowsHitTesting(true)
            }
        }
        .onAppear {
            syncLaunchSplashPhase()
        }
        .onChange(of: shouldParticipate) { _, _ in
            syncLaunchSplashPhase()
        }
        .onChange(of: isVisible) { _, _ in
            syncLaunchSplashPhase()
        }
        .onChange(of: primaryContentReady) { _, _ in
            syncLaunchSplashPhase()
        }
    }

    @ViewBuilder
    private func splashBody(showSpinner: Bool) -> some View {
        ZStack {
            launchBackground
                .ignoresSafeArea()
            launchLogo
                .scaleEffect(logoScale, anchor: .center)
            if showSpinner {
                ProgressView()
                    .controlSize(.large)
                    .tint(brandBlue)
                    .offset(y: 96)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading")
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var launchLogo: some View {
        Image("LaunchBrandLogo")
            .resizable()
            .scaledToFit()
            .frame(width: 120, height: 120)
    }

    private func syncLaunchSplashPhase() {
        guard shouldParticipate else {
            resetToHidden()
            return
        }

        if phase == .hidden {
            presentFullScreenPhase()
        }

        if isVisible {
            if phase != .fullScreen {
                presentFullScreenPhase()
            } else {
                pendingDismissAfterVisibleBeat = false
            }
            return
        }

        guard phase == .fullScreen else { return }
        if didSatisfyVisibleBeat {
            startDismissPhase()
        } else {
            pendingDismissAfterVisibleBeat = true
            armBurstTimerIfNeeded()
        }
    }

    private func presentFullScreenPhase() {
        presentationCycle += 1
        phase = .fullScreen
        logoScale = 1.0
        overlayOpacity = 1.0
        didSatisfyVisibleBeat = false
        pendingDismissAfterVisibleBeat = false
        armBurstTimerIfNeeded()
    }

    private func armBurstTimerIfNeeded() {
        guard primaryContentReady, phase == .fullScreen, !didSatisfyVisibleBeat else { return }
        let cycle = presentationCycle
        DispatchQueue.main.asyncAfter(deadline: .now() + burstDelayAfterPrimaryContentReady) {
            guard cycle == presentationCycle, phase == .fullScreen else { return }
            didSatisfyVisibleBeat = true
            if pendingDismissAfterVisibleBeat || !isVisible {
                startDismissPhase()
            }
        }
    }

    private func startDismissPhase() {
        guard phase == .fullScreen else { return }
        pendingDismissAfterVisibleBeat = false
        phase = .dismissing
        logoScale = 1.0
        overlayOpacity = 1.0
        let cycle = presentationCycle
        withAnimation(.easeInOut(duration: burstDuration)) {
            logoScale = burstTargetScale
            overlayOpacity = 0.0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + burstDuration + 0.05) {
            guard cycle == presentationCycle else { return }
            resetToHidden()
            onDismissCompleted()
        }
    }

    private func resetToHidden() {
        presentationCycle += 1
        phase = .hidden
        logoScale = 1.0
        overlayOpacity = 1.0
        didSatisfyVisibleBeat = false
        pendingDismissAfterVisibleBeat = false
    }
}

/// After onboarding: full-screen until infra owner/upperAdmin; optional resend with 120s cooldown.
private struct AwaitingParentWorkspacePermissionOverlay: View {
    @ObservedObject var vm: POSViewModel
    private let brandBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 28) {
                Spacer(minLength: 48)
                Image("LaunchBrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 96, height: 96)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .padding(.bottom, 8)
                ProgressView()
                    .controlSize(.large)
                    .tint(brandBlue)
                VStack(spacing: 10) {
                    Text("Waiting for workspace authorization")
                        .font(.system(size: 20, weight: .bold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 32)
                    if !vm.permissionGateParentTagLine.isEmpty {
                        Text("Requesting approval from parent @\(vm.permissionGateParentTagLine)")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 36)
                    }
                    Text(
                        vm.permissionGateParentTagLine.isEmpty
                            ? "This wallet is not yet on this terminal’s Beamio card admin list. The app checks for access automatically."
                            : "Sending a secure CoNET message to your workspace parent. You can use this terminal when they approve."
                    )
                        .font(.system(size: 14, weight: .regular))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 40)
                        .padding(.top, 4)
                }
                if !vm.permissionGateParentTagLine.isEmpty {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let remaining = resendCooldownRemainingSeconds(at: context.date)
                        Button {
                            Task { @MainActor in
                                await vm.resendTerminalParentPermissionRequest()
                            }
                        } label: {
                            if remaining > 0 {
                                Text("Resend approval request (\(formatResendCooldown(remaining)))")
                                    .font(.system(size: 16, weight: .semibold))
                                    .multilineTextAlignment(.center)
                            } else {
                                Text("Resend approval request")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(brandBlue)
                        .disabled(remaining > 0)
                        .padding(.horizontal, 40)
                        .padding(.top, 8)
                    }
                }
                Button {
                    BeamioHaptic.light()
                    vm.openChangeParentWorkspaceAdminPicker()
                } label: {
                    Text("Change workspace parent")
                        .font(.system(size: 16, weight: .semibold))
                }
                .buttonStyle(.bordered)
                .tint(brandBlue)
                .padding(.horizontal, 40)
                .padding(.top, 6)
                Spacer(minLength: 56)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Waiting for parent workspace authorization")
        }
    }

    private func resendCooldownRemainingSeconds(at date: Date) -> Int {
        guard let until = vm.terminalPermissionResendCooldownUntil else { return 0 }
        let s = Int(ceil(until.timeIntervalSince(date)))
        return max(0, s)
    }

    private func formatResendCooldown(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}

/// Search dropdown row: capsule layout with **@BeamioTag** as primary line and **short address** as secondary (align `homeHeaderWalletShortLine`).
private struct ParentWorkspaceSearchResultCapsuleRow: View {
    let profile: TerminalProfile

    private var beamioTagTitle: String {
        let raw = profile.accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty || raw.lowercased() == "null" { return "—" }
        var s = raw
        while s.hasPrefix("@") { s.removeFirst() }
        s = s.replacingOccurrences(of: "@", with: "")
        return s.isEmpty ? "—" : "@\(s)"
    }

    private var shortAddressSubtitle: String {
        guard let a = profile.address?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else { return "—" }
        let t = a
        guard t.count >= 10 else { return t }
        return "\(t.prefix(6))…\(t.suffix(4))"
    }

    var body: some View {
        let tagRaw = profile.accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let tagSeed = tagRaw.isEmpty ? "Beamio" : tagRaw
        let enc = tagSeed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? tagSeed
        let avatarUrl = URL(string: "https://api.dicebear.com/8.x/fun-emoji/png?seed=\(enc)")

        HStack(alignment: .center, spacing: 8) {
            searchRowAvatar(image: profile.image, fallbackUrl: avatarUrl)
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(beamioTagTitle)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(shortAddressSubtitle)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.black.opacity(0.06)))
    }

    @ViewBuilder
    private func searchRowAvatar(image: String?, fallbackUrl: URL?) -> some View {
        let trimmed = image?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            BeamioCardRasterOrSvgImage(urlString: trimmed, rasterContentMode: .fill) {
                searchRowDiceFallback(fallbackUrl)
            }
        } else {
            searchRowDiceFallback(fallbackUrl)
        }
    }

    private func searchRowDiceFallback(_ url: URL?) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            case .failure: Color.gray.opacity(0.3)
            case .empty: Color.gray.opacity(0.2)
            @unknown default: Color.gray.opacity(0.3)
            }
        }
    }
}

/// Retarget CoNET approval: `GET /api/search-users-by-card-owner-or-admin` (POS server-side owner/admin filter).
private struct ChangeParentWorkspaceAdminSheet: View {
    @ObservedObject var vm: POSViewModel
    @State private var tagQuery = ""
    @State private var searchResults: [TerminalProfile] = []
    @State private var searchLoading = false
    @State private var showSearchDropdown = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchRequestId = 0
    @State private var selectedProfile: TerminalProfile?
    @State private var continueBusy = false
    @FocusState private var tagFieldFocused: Bool

    private var normalizedTagQuery: String {
        var s = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("@") { s.removeFirst() }
        return s
    }

    private var keywordForSearch: String { normalizedTagQuery.lowercased() }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Search the @BeamioTag of the workspace admin who should receive the approval request. Results are limited to card issuers and admins linked to this terminal.")
                .font(.system(size: 15, weight: .regular))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 16)

            if let picked = selectedProfile {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Selected parent")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 20)
                    HStack(spacing: 12) {
                        HomeBeamioCapsuleCompact(profile: picked, fallbackAddress: picked.address)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 20)
                    Button {
                        BeamioHaptic.light()
                        selectedProfile = nil
                        showSearchDropdown = false
                        searchResults = []
                    } label: {
                        Text("Clear selection")
                            .font(.system(size: 15, weight: .semibold))
                    }
                    .padding(.horizontal, 20)
                }
            } else {
                parentSearchFieldBlock
            }

            Spacer(minLength: 16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Change workspace parent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button {
                    BeamioHaptic.light()
                    vm.cancelChangeParentWorkspaceAdminPicker()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 15, weight: .semibold))
                }
                .disabled(continueBusy)
                .accessibilityLabel("Cancel")
            }
            ToolbarItem(placement: .confirmationAction) {
                Button {
                    guard let tag = normalizedBeamioTagFromProfile(selectedProfile) else {
                        vm.homeToast = "Select a profile that has a @BeamioTag."
                        return
                    }
                    BeamioHaptic.medium()
                    continueBusy = true
                    Task { @MainActor in
                        await vm.confirmChangeParentWorkspaceAdmin(normalizedParentTag: tag)
                        continueBusy = false
                    }
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                }
                .disabled(continueBusy || normalizedBeamioTagFromProfile(selectedProfile) == nil)
                .accessibilityLabel("Continue")
            }
        }
        .onChange(of: tagQuery) { _, new in
            let stripped = new.replacingOccurrences(of: "@", with: "")
            if stripped != new {
                tagQuery = stripped
                return
            }
            let norm = stripped.lowercased()
            if let sel = selectedProfile,
               let u = sel.accountName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !u.isEmpty,
               norm == u {
                return
            }
            selectedProfile = nil
            scheduleSearchDebounced()
        }
    }

    private var parentSearchFieldBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("@BeamioTag")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    TextField("e.g. coffee_house_ny", text: $tagQuery)
                        .focused($tagFieldFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .submitLabel(.search)
                        .font(.system(size: 17, weight: .medium))
                        .padding(.leading, 16)
                        .onSubmit {
                            searchDebounceTask?.cancel()
                            startSearch(keyword: keywordForSearch)
                        }
                    Button {
                        BeamioHaptic.light()
                        searchDebounceTask?.cancel()
                        startSearch(keyword: keywordForSearch)
                    } label: {
                        Group {
                            if searchLoading {
                                ProgressView()
                                    .scaleEffect(0.9)
                            } else {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 18, weight: .medium))
                            }
                        }
                        .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(keywordForSearch.count < 2 || searchLoading)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                }
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: .secondarySystemGroupedBackground)))

                if showSearchDropdown, keywordForSearch.count >= 2 {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(Array(searchResults.enumerated()), id: \.offset) { _, row in
                                Button {
                                    selectProfile(row)
                                } label: {
                                    ParentWorkspaceSearchResultCapsuleRow(profile: row)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 10)
                                        .padding(.horizontal, 12)
                                }
                                .buttonStyle(.plain)
                                Divider()
                            }
                        }
                    }
                    .frame(maxHeight: 280)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(uiColor: .systemBackground)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Color(uiColor: .separator), lineWidth: 0.5)
                    )
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private func normalizedBeamioTagFromProfile(_ p: TerminalProfile?) -> String? {
        guard let p else { return nil }
        guard let t = p.accountName?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        var s = t
        while s.hasPrefix("@") { s.removeFirst() }
        s = s.replacingOccurrences(of: "@", with: "")
        guard s.range(of: "^[a-zA-Z0-9_.]{3,20}$", options: .regularExpression) != nil else { return nil }
        return s
    }

    private func selectProfile(_ profile: TerminalProfile) {
        BeamioHaptic.medium()
        if let t = profile.accountName?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            var display = t
            while display.hasPrefix("@") { display.removeFirst() }
            tagQuery = display
        }
        selectedProfile = profile
        showSearchDropdown = false
        searchResults = []
        tagFieldFocused = false
    }

    private func scheduleSearchDebounced() {
        searchDebounceTask?.cancel()
        let key = keywordForSearch
        if key.count < 2 {
            searchResults = []
            showSearchDropdown = false
            searchLoading = false
            return
        }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            startSearch(keyword: key)
        }
    }

    private func startSearch(keyword: String) {
        guard keyword.count >= 2 else {
            searchResults = []
            showSearchDropdown = false
            searchLoading = false
            return
        }
        searchRequestId += 1
        let id = searchRequestId
        searchLoading = true
        Task { @MainActor in
            let list = await vm.searchUsersListForPOSTerminal(keyward: keyword)
            guard id == searchRequestId else { return }
            searchLoading = false
            searchResults = list
            showSearchDropdown = true
        }
    }
}

/// iOS-style circular glass back control (top-leading in scan / balance full-screen flows).
private struct SheetCircularBackButton: View {
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "chevron.backward")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 36, height: 36)
                .background {
                    Circle()
                        .fill(.ultraThinMaterial)
                        .shadow(color: .black.opacity(0.12), radius: 3, x: 0, y: 1)
                }
        }
        .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
        .accessibilityLabel("Back")
    }
}

// MARK: - Amount flow

enum AmountFlow: String, Identifiable {
    case charge
    case topup
    case transactions
    var id: String { rawValue }
}

// MARK: - Welcome / Onboarding (align bizSite `marketExample.html` Terminal Setup)

/// Tailwind theme tokens from `marketExample.html` (M3-style extend colors).
private enum MarketExampleTerminalTheme {
    static let background = Color(red: 0xf5 / 255, green: 0xf7 / 255, blue: 0xf9 / 255)
    static let primary = Color(red: 0, green: 0x51 / 255, blue: 0xd1 / 255)
    static let primaryDim = Color(red: 0, green: 0x47 / 255, blue: 0xb8 / 255)
    static let onSurface = Color(red: 0x2c / 255, green: 0x2f / 255, blue: 0x31 / 255)
    static let onSurfaceVariant = Color(red: 0x59 / 255, green: 0x5c / 255, blue: 0x5e / 255)
    static let surfaceContainerLow = Color(red: 0xee / 255, green: 0xf1 / 255, blue: 0xf3 / 255)
    static let surfaceContainerLowest = Color.white
    static let outlineVariant = Color(red: 0xab / 255, green: 0xad / 255, blue: 0xaf / 255)
    static let primaryFixed = Color(red: 0x7a / 255, green: 0x9d / 255, blue: 0xff / 255)
}

/// Same hero image as `marketExample.html` (POS terminal illustration).
private let marketExampleTerminalHeroImageURL = URL(string: "https://lh3.googleusercontent.com/aida-public/AB6AXuC81jazJ6aagCDIf-YFpCeIgCrQ6ESZEbBv5Wlhpz-yY0JbCRJOXX5EILx6F4d2awTUwfnt3HKK36PRL2-GizaBHdbdkdBmcA0J_5PahS-Wrn3tsths3Vew2IgALnwxo2V2EalIIlIAD1IEyJnKUzntUt7dL2FNyxnUOaa4r2ANMFEWFWf0Mc3lg8C16tIZQMn7naGD0XpVDdT_IXlsL_svhLL1VnmWPAnO7Y2c54AnYUCUvDpbujAbOYd_lgCgp5g0Q1Ea9nLjb8I")!

// MARK: - Verra Gateway (bizHome.tsx parity)

/// First QR payload in an image — `RestoreAccessPage` / jsQR parity (PNG, JPG).
private func verraDecodeFirstQrPayload(from image: UIImage) -> String? {
    let cg: CGImage?
    if let c = image.cgImage {
        cg = c
    } else if let ci = image.ciImage {
        cg = CIContext().createCGImage(ci, from: ci.extent)
    } else {
        cg = nil
    }
    guard let cgImage = cg else { return nil }
    let request = VNDetectBarcodesRequest()
    request.symbologies = [.qr]
    let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    do {
        try handler.perform([request])
        let payloads = (request.results ?? []).compactMap(\.payloadStringValue)
        return payloads.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return nil
    }
}

/// `bizSite` `RestoreAccessPage.tsx`: Recovery QR → `restoreWithRedeem` (no password).
private struct VerraRecoveryQrRestoreView: View {
    @ObservedObject var vm: POSViewModel
    var onBack: () -> Void

    @Environment(\.openURL) private var openURL

    @State private var recoveryCode = ""
    @State private var selectedImageName = ""
    @State private var isParsingImage = false
    @State private var isRestoring = false
    @State private var pageError = ""
    @State private var photoPickerItem: PhotosPickerItem?
    @State private var showQrScanner = false

    private let bgPage = Color(red: 245 / 255, green: 247 / 255, blue: 249 / 255)
    private let textPrimary = Color(red: 44 / 255, green: 47 / 255, blue: 49 / 255)
    private let textSecondary = Color(red: 89 / 255, green: 92 / 255, blue: 94 / 255)
    private let brandBlue = Color(red: 0, green: 81 / 255, blue: 209 / 255)
    private let inputBg = Color(red: 238 / 255, green: 241 / 255, blue: 243 / 255)

    var body: some View {
        VStack(spacing: 0) {
            recoveryHeader
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    VStack(spacing: 16) {
                        Text("Restore Access")
                            .font(.system(size: 34, weight: .heavy))
                            .foregroundStyle(textPrimary)
                            .multilineTextAlignment(.center)
                        Text("Use your Recovery QR code to regain access to your workspace without a password.")
                            .font(.system(size: 17))
                            .foregroundStyle(textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                    .padding(.bottom, 32)

                    VStack(spacing: 16) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(Color.white)
                                .shadow(color: Color.black.opacity(0.08), radius: 20, x: 0, y: 10)
                            VStack(spacing: 16) {
                                ZStack {
                                    Circle()
                                        .fill(Color(red: 122 / 255, green: 157 / 255, blue: 1).opacity(0.2))
                                        .frame(width: 80, height: 80)
                                    Image(systemName: "qrcode")
                                        .font(.system(size: 36))
                                        .foregroundStyle(brandBlue)
                                }
                                .padding(.top, 8)
                                Text("Upload or scan your Recovery QR code image")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(textPrimary)
                                    .multilineTextAlignment(.center)
                                Text("Supports PNG or JPG")
                                    .font(.system(size: 11, weight: .semibold))
                                    .tracking(1.2)
                                    .foregroundStyle(textSecondary)
                                if !selectedImageName.isEmpty {
                                    Text(selectedImageName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(brandBlue)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                PhotosPicker(selection: $photoPickerItem, matching: .images, photoLibrary: .shared()) {
                                    Text(isParsingImage ? "Reading File…" : "Select File")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundStyle(textPrimary)
                                        .padding(.horizontal, 22)
                                        .padding(.vertical, 10)
                                        .background(Capsule().fill(Color(red: 223 / 255, green: 227 / 255, blue: 230 / 255)))
                                }
                                .disabled(isParsingImage || isRestoring)
                                .padding(.top, 8)

                                Button {
                                    showQrScanner = true
                                } label: {
                                    Text("Scan with Camera")
                                        .font(.system(size: 14, weight: .semibold))
                                        .foregroundStyle(brandBlue)
                                }
                                .disabled(isRestoring)
                                .padding(.bottom, 8)
                            }
                            .padding(24)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("Or paste recovery secret")
                                .font(.system(size: 11, weight: .bold))
                                .tracking(1.5)
                                .foregroundStyle(brandBlue)
                            TextField("Decoded QR payload", text: $recoveryCode, axis: .vertical)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .lineLimit(4, reservesSpace: true)
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(textPrimary)
                                .padding(14)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(inputBg))
                        }
                    }
                    .padding(.horizontal, 4)

                    Button {
                        pageError = ""
                        Task {
                            isRestoring = true
                            let err = await vm.restoreWorkspaceFromRecoveryCode(recoveryCode)
                            isRestoring = false
                            if let err {
                                pageError = err
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if isRestoring {
                                ProgressView()
                                    .tint(.white)
                                Text("Restoring…")
                            } else {
                                Text("Validate & Restore")
                                Image(systemName: "arrow.right")
                                    .font(.system(size: 16, weight: .semibold))
                            }
                        }
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Capsule().fill(brandBlue))
                        .shadow(color: brandBlue.opacity(0.22), radius: 12, x: 0, y: 6)
                    }
                    .buttonStyle(BeamioHapticPlainButtonStyle())
                    .disabled(recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRestoring || isParsingImage)
                    .opacity(recoveryCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isRestoring || isParsingImage ? 0.55 : 1)
                    .padding(.top, 28)

                    if !pageError.isEmpty {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 16))
                                .foregroundStyle(Color(red: 0.85, green: 0.55, blue: 0.1))
                            Text(pageError)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(Color(red: 0.55, green: 0.35, blue: 0.05))
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color(red: 1, green: 0.97, blue: 0.9))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(Color(red: 1, green: 0.9, blue: 0.7), lineWidth: 1)
                        )
                        .padding(.top, 16)
                    }

                    Button {
                        if let u = URL(string: "https://verra.network/contact") {
                            openURL(u)
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "questionmark.circle")
                            Text("Where can I find my Recovery QR code?")
                        }
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(brandBlue)
                    }
                    .padding(.top, 20)

                    HStack(alignment: .top, spacing: 12) {
                        recoveryInfoTile(
                            icon: "lock.fill",
                            title: "Encrypted Recovery",
                            body: "Your recovery data is decrypted on this device using the same cryptography as Verra Business on the web."
                        )
                        recoveryInfoTile(
                            icon: "checkmark.shield.fill",
                            title: "Workspace Safety",
                            body: "Use a recovery code only from a trusted backup you created during onboarding."
                        )
                    }
                    .padding(.top, 28)

                    Text("Powered by Verra Cryptographic Infrastructure")
                        .font(.system(size: 10, weight: .medium))
                        .tracking(2)
                        .foregroundStyle(textSecondary.opacity(0.65))
                        .padding(.top, 32)
                        .padding(.bottom, 28)
                }
                .padding(.horizontal, 24)
            }
        }
        .background(bgPage.ignoresSafeArea())
        .onChange(of: photoPickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                isParsingImage = true
                pageError = ""
                defer { isParsingImage = false }
                do {
                    guard let data = try await newItem.loadTransferable(type: Data.self),
                          let ui = UIImage(data: data)
                    else {
                        pageError = "Unable to read the selected image."
                        return
                    }
                    selectedImageName = "Selected image"
                    if let payload = verraDecodeFirstQrPayload(from: ui) {
                        recoveryCode = payload
                        pageError = ""
                    } else {
                        recoveryCode = ""
                        pageError = "No recovery QR code was found in that image."
                    }
                } catch {
                    pageError = "Unable to read the selected image."
                }
                photoPickerItem = nil
            }
        }
        .fullScreenCover(isPresented: $showQrScanner) {
            ZStack(alignment: .topTrailing) {
                BeamioQRScannerView { code in
                    recoveryCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
                    showQrScanner = false
                }
                .ignoresSafeArea()
                Button {
                    showQrScanner = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.black.opacity(0.45))
                        .padding(16)
                }
                .accessibilityLabel("Close scanner")
            }
            .background(Color.black)
        }
    }

    private var recoveryHeader: some View {
        HStack {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(brandBlue)
            }
            .accessibilityLabel("Back")
            Text("Recovery")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(textPrimary)
            Spacer()
            Text("Verra")
                .font(.system(size: 20, weight: .black))
                .tracking(-0.5)
                .foregroundStyle(brandBlue)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .padding(.top, 4)
        .background {
            ZStack {
                Color.white.opacity(0.72)
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1)
        }
    }

    private func recoveryInfoTile(icon: String, title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(Color(red: 0.4, green: 0.55, blue: 1))
            Text(title)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(textPrimary)
            Text(body)
                .font(.system(size: 11))
                .foregroundStyle(textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(inputBg.opacity(0.65))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.white.opacity(0.45), lineWidth: 1)
        )
    }
}

/// `bizSite` `bizHome.tsx` gateway: Access your business workspace — BeamioTag + access password → `restoreWithUserPin`.
private struct VerraBizWorkspaceGatewayView: View {
    @ObservedObject var vm: POSViewModel
    var onBack: () -> Void

    @Environment(\.openURL) private var openURL

    @State private var showRecoveryQr = false
    @State private var merchantTag = ""
    @State private var password = ""
    @State private var showPassword = false
    @State private var isLoading = false
    @State private var loginError = ""

    private let bgPage = Color(red: 245 / 255, green: 247 / 255, blue: 249 / 255)
    private let textPrimary = Color(red: 44 / 255, green: 47 / 255, blue: 49 / 255)
    private let textSecondary = Color(red: 89 / 255, green: 92 / 255, blue: 94 / 255)
    private let brandBlue = Color(red: 0, green: 81 / 255, blue: 209 / 255)
    private let inputBg = Color(red: 238 / 255, green: 241 / 255, blue: 243 / 255)
    private let placeholderMuted = Color(red: 171 / 255, green: 173 / 255, blue: 175 / 255).opacity(0.7)

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }

    private func normalizeBizGatewayTagInput(_ raw: String) -> String {
        raw.replacingOccurrences(of: "@", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        Group {
            if showRecoveryQr {
                VerraRecoveryQrRestoreView(vm: vm) {
                    showRecoveryQr = false
                }
            } else {
                gatewayMainScroll
            }
        }
    }

    private var gatewayMainScroll: some View {
        VStack(spacing: 0) {
            gatewayHeader
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Access your business workspace")
                            .font(.system(size: 28, weight: .heavy))
                            .foregroundStyle(textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Use your BeamioTag and password to continue to Verra Business OS.")
                            .font(.system(size: 16))
                            .foregroundStyle(textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 24)
                    .padding(.bottom, 32)

                    RoundedRectangle(cornerRadius: 999, style: .continuous)
                        .fill(brandBlue.opacity(0.2))
                        .frame(width: 96, height: 4)
                        .padding(.bottom, 32)

                    VStack(alignment: .leading, spacing: 24) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Continue with your business identity")
                                .font(.system(size: 20, weight: .bold))
                                .foregroundStyle(textPrimary)
                            Text("Enter the business identity you created to access your Verra workspace.")
                                .font(.system(size: 14))
                                .foregroundStyle(textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("@BEAMIOTAG")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(2.4)
                                .foregroundStyle(brandBlue)
                                .padding(.leading, 4)
                            TextField("e.g. global_ventures", text: $merchantTag)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textContentType(.username)
                                .submitLabel(.next)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(textPrimary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(inputBg))
                                .onChange(of: merchantTag) { _, new in
                                    let n = normalizeBizGatewayTagInput(new)
                                    if n != new { merchantTag = n }
                                }
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .font(.system(size: 14))
                                    .foregroundStyle(brandBlue)
                                    .padding(.top, 2)
                                Text("Your BeamioTag is your business identity on Verra.")
                                    .font(.system(size: 11))
                                    .foregroundStyle(textSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 4)
                            .padding(.top, 4)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            Text("ACCESS PASSWORD")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(2.4)
                                .foregroundStyle(brandBlue)
                                .padding(.leading, 4)
                            ZStack(alignment: .trailing) {
                                Group {
                                    if showPassword {
                                        TextField("Password", text: $password)
                                    } else {
                                        SecureField("••••••••", text: $password)
                                    }
                                }
                                .textContentType(.password)
                                .submitLabel(.done)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(textPrimary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 16)
                                .padding(.trailing, 44)
                                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(inputBg))

                                Button {
                                    showPassword.toggle()
                                } label: {
                                    Image(systemName: showPassword ? "eye.slash" : "eye")
                                        .font(.system(size: 18))
                                        .foregroundStyle(textSecondary)
                                }
                                .padding(.trailing, 16)
                                .accessibilityLabel(showPassword ? "Hide password" : "Show password")
                            }
                        }

                        if !loginError.isEmpty {
                            Text(loginError)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(Color(red: 225 / 255, green: 29 / 255, blue: 72 / 255))
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color(red: 1, green: 0.95, blue: 0.96))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .strokeBorder(Color(red: 1, green: 0.88, blue: 0.9), lineWidth: 1)
                                )
                        }

                        Button {
                            loginError = ""
                            Task {
                                isLoading = true
                                let err = await vm.restoreWorkspaceFromPin(
                                    beamioTag: normalizeBizGatewayTagInput(merchantTag),
                                    accessPassword: password
                                )
                                isLoading = false
                                if let err {
                                    loginError = err
                                }
                            }
                        } label: {
                            HStack(spacing: 8) {
                                if isLoading {
                                    ProgressView()
                                        .tint(.white)
                                    Text("Signing in…")
                                } else {
                                    Text("Continue to Verra Business OS")
                                    Image(systemName: "arrow.right")
                                        .font(.system(size: 17, weight: .semibold))
                                }
                            }
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(Capsule().fill(brandBlue))
                            .shadow(color: brandBlue.opacity(0.25), radius: 10, x: 0, y: 6)
                        }
                        .buttonStyle(BeamioHapticPlainButtonStyle())
                        .disabled(isLoading || normalizeBizGatewayTagInput(merchantTag).isEmpty || password.isEmpty)
                        .opacity(isLoading || normalizeBizGatewayTagInput(merchantTag).isEmpty || password.isEmpty ? 0.55 : 1)
                    }
                    .padding(28)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(Color.white)
                            .shadow(color: Color.black.opacity(0.06), radius: 20, x: 0, y: 12)
                    )

                    Button {
                        showRecoveryQr = true
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: "briefcase.fill")
                                .font(.system(size: 15))
                                .foregroundStyle(brandBlue)
                            HStack(spacing: 0) {
                                Text("Already have a workspace? ")
                                    .foregroundStyle(textSecondary)
                                Text("Restore Account")
                                    .underline()
                                    .foregroundStyle(brandBlue)
                            }
                            .font(.system(size: 14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
                    .padding(.top, 20)

                    VStack(spacing: 16) {
                        Button {
                            if let u = URL(string: "https://verra.network/contact") {
                                openURL(u)
                            }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: "questionmark.circle")
                                    .font(.system(size: 18))
                                Text("Need help accessing your workspace?")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .foregroundStyle(brandBlue)
                        }
                        .padding(.top, 28)

                        VStack(spacing: 8) {
                            Text("Securely hosted by Beamio Infrastructure © 2026")
                                .font(.system(size: 10, weight: .bold))
                                .tracking(2.4)
                                .foregroundStyle(Color(red: 116 / 255, green: 119 / 255, blue: 121 / 255))
                            Text("v\(appVersion)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(placeholderMuted)
                        }
                        .padding(.top, 12)
                        .padding(.bottom, 32)
                    }
                    .frame(maxWidth: .infinity)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
        }
        .background(bgPage.ignoresSafeArea())
    }

    private var gatewayHeader: some View {
        ZStack {
            HStack {
                Button {
                    onBack()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(brandBlue)
                        .frame(width: 44, height: 44, alignment: .leading)
                }
                .accessibilityLabel("Back")
                Spacer()
            }
            HStack(spacing: 8) {
                Image(systemName: "touchid")
                    .font(.system(size: 18, weight: .medium))
                Text("VERRA GATEWAY")
                    .font(.system(size: 17, weight: .black))
                    .tracking(-0.3)
            }
            .foregroundStyle(brandBlue)
            HStack {
                Spacer()
                ZStack {
                    Circle()
                        .fill(Color(red: 223 / 255, green: 227 / 255, blue: 230 / 255))
                        .frame(width: 32, height: 32)
                    Image(systemName: "briefcase.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(textSecondary)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background {
            ZStack {
                Color.white.opacity(0.72)
                Rectangle().fill(.ultraThinMaterial)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.08))
                .frame(height: 1)
        }
    }
}

/// New user / no local wallet: Terminal Setup cover (`marketExample.html`).
/// `@BeamioTag` search: `GET /api/search-users-by-card-owner-or-admin` (program card + registered issuers; no device wallet yet).
private struct VerraEntrySplashView: View {
    @ObservedObject var vm: POSViewModel
    /// Pass normalized handle (no `@`, trimmed) for onboarding prefill; may be empty.
    var onGetStarted: (_ prefillNormalizedHandle: String) -> Void

    @State private var tagQuery = ""
    @State private var searchResults: [TerminalProfile] = []
    @State private var searchLoading = false
    @State private var showSearchDropdown = false
    @State private var searchDebounceTask: Task<Void, Never>?
    @State private var searchRequestId = 0
    @State private var selectedLookup: TerminalProfile?
    @FocusState private var tagFieldFocused: Bool

    private var appVersion: String? {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }

    private var buildVersionLine: String {
        let v = appVersion ?? "1.0"
        return "v\(v) Build Stable"
    }

    /// Normalized handle for onboarding prefill (preserve casing as typed; strip leading `@`).
    private var normalizedTagQuery: String {
        var s = tagQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("@") { s.removeFirst() }
        return s
    }

    /// Lowercased keyword for Beamio user search.
    private var keywordForSearch: String {
        normalizedTagQuery.lowercased()
    }

    /// Single `Text(AttributedString)` avoids `Text`+`Text` deprecated on iOS 26+.
    private func linkTerminalWorkspaceTitleText(compactH: Bool) -> Text {
        let fSize = CGFloat(compactH ? 28 : 34)
        let heavy = UIFont.systemFont(ofSize: fSize, weight: .heavy)
        var p1 = AttributedString("Link Terminal to ")
        p1.uiKit.font = heavy
        p1.uiKit.foregroundColor = UIColor(MarketExampleTerminalTheme.onSurface)
        var p2 = AttributedString("Workspace")
        p2.uiKit.font = heavy
        p2.uiKit.foregroundColor = UIColor(MarketExampleTerminalTheme.primary)
        return Text(p1 + p2)
    }

    private func enterBeamioTagExplainerText(compactH: Bool) -> Text {
        let fSize = CGFloat(compactH ? 15 : 16)
        let regular = UIFont.systemFont(ofSize: fSize, weight: .regular)
        let semibold = UIFont.systemFont(ofSize: fSize, weight: .semibold)
        var p1 = AttributedString("Enter your business ")
        p1.uiKit.font = regular
        p1.uiKit.foregroundColor = UIColor(MarketExampleTerminalTheme.onSurfaceVariant)
        var p2 = AttributedString("@BeamioTag")
        p2.uiKit.font = semibold
        p2.uiKit.foregroundColor = UIColor(MarketExampleTerminalTheme.onSurface)
        var p3 = AttributedString(" to authorize this device. This secures your transactions and syncs your inventory.")
        p3.uiKit.font = regular
        p3.uiKit.foregroundColor = UIColor(MarketExampleTerminalTheme.onSurfaceVariant)
        return Text(p1 + p2 + p3)
    }

    var body: some View {
        terminalSetupSplashBody
    }

    private var terminalSetupSplashBody: some View {
        GeometryReader { geo in
            let compactH = geo.size.height < 700
            let heroH: CGFloat = compactH ? 200 : 256
            let maxContent = min(geo.size.width, 576)

            ZStack(alignment: .bottom) {
                MarketExampleTerminalTheme.background
                    .ignoresSafeArea()

                VStack(spacing: 0) {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 0) {
                            marketExampleHeroBlock(height: heroH)
                                .padding(.top, max(16, geo.safeAreaInsets.top + 8))
                                .padding(.bottom, compactH ? 28 : 36)

                            VStack(alignment: .leading, spacing: compactH ? 18 : 22) {
                                VStack(alignment: .leading, spacing: 10) {
                                    linkTerminalWorkspaceTitleText(compactH: compactH)
                                        .fixedSize(horizontal: false, vertical: true)

                                    enterBeamioTagExplainerText(compactH: compactH)
                                        .fixedSize(horizontal: false, vertical: true)
                                }

                                Text("Search an existing @BeamioTag below (workspace-linked results). After you pick a profile, continue with Next Phase or remove the selection to search again.")
                                    .font(.system(size: compactH ? 14 : 15))
                                    .foregroundStyle(MarketExampleTerminalTheme.onSurfaceVariant)
                                    .fixedSize(horizontal: false, vertical: true)

                                if selectedLookup == nil {
                                    marketExampleBeamioTagSearchField
                                } else if let picked = selectedLookup {
                                    marketExampleSelectedProfileBlock(profile: picked)
                                }

                                marketExampleInfoStatusCard(selected: selectedLookup)
                            }
                            .frame(maxWidth: maxContent, alignment: .leading)
                            .padding(.horizontal, 24)

                            .padding(.bottom, max(28, geo.safeAreaInsets.bottom + 16))
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .onChange(of: tagQuery) { _, new in
                let stripped = new.replacingOccurrences(of: "@", with: "")
                if stripped != new {
                    tagQuery = stripped
                    return
                }
                let norm = stripped.lowercased()
                if let sel = selectedLookup,
                   let u = sel.accountName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                   !u.isEmpty,
                   norm == u {
                    return
                }
                selectedLookup = nil
                scheduleTerminalTagSearchDebounced()
            }
        }
    }

    private func marketExampleHeroBlock(height: CGFloat) -> some View {
        let corner: CGFloat = 14
        return ZStack(alignment: .bottom) {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(MarketExampleTerminalTheme.background)
                .shadow(color: Color.black.opacity(0.18), radius: 18, x: 0, y: 10)
                .frame(height: height)

            ZStack {
                marketExampleMeshGradient.opacity(0.2)
                AsyncImage(url: marketExampleTerminalHeroImageURL, transaction: Transaction(animation: .default)) { phase in
                    switch phase {
                    case .success(let img):
                        img
                            .resizable()
                            .scaledToFill()
                            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
                            .clipped()
                            .blendMode(.overlay)
                    case .failure, .empty:
                        LinearGradient(
                            colors: [
                                MarketExampleTerminalTheme.surfaceContainerLow,
                                MarketExampleTerminalTheme.primary.opacity(0.15),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    @unknown default:
                        Color.clear
                    }
                }
                LinearGradient(
                    colors: [
                        MarketExampleTerminalTheme.background,
                        Color.clear,
                        Color.clear,
                    ],
                    startPoint: .bottom,
                    endPoint: .top
                )
            }
            .frame(height: height)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(MarketExampleTerminalTheme.primary)
                        .frame(width: 48, height: 48)
                    Image(systemName: "terminal.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("SoftPOS Native")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(MarketExampleTerminalTheme.onSurface)
                    Text(buildVersionLine)
                        .font(.system(size: 12))
                        .foregroundStyle(MarketExampleTerminalTheme.onSurfaceVariant)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(MarketExampleTerminalTheme.surfaceContainerLowest.opacity(0.4))
                    .background(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.2), lineWidth: 1)
                    )
            }
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
        }
        .frame(height: height)
        .padding(.horizontal, 24)
    }

    private var marketExampleMeshGradient: some View {
        ZStack {
            RadialGradient(
                colors: [MarketExampleTerminalTheme.primary, Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: 280
            )
            RadialGradient(
                colors: [MarketExampleTerminalTheme.primaryFixed, Color.clear],
                center: .topTrailing,
                startRadius: 0,
                endRadius: 260
            )
            RadialGradient(
                colors: [MarketExampleTerminalTheme.surfaceContainerLow, Color.clear],
                center: .bottom,
                startRadius: 0,
                endRadius: 240
            )
        }
    }

    private func scheduleTerminalTagSearchDebounced() {
        searchDebounceTask?.cancel()
        let key = keywordForSearch
        if key.count < 2 {
            searchResults = []
            showSearchDropdown = false
            searchLoading = false
            return
        }
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            startTerminalTagSearch(keyword: key)
        }
    }

    private func startTerminalTagSearch(keyword: String) {
        guard keyword.count >= 2 else {
            searchResults = []
            showSearchDropdown = false
            searchLoading = false
            return
        }
        searchRequestId += 1
        let id = searchRequestId
        searchLoading = true
        Task { @MainActor in
            let list = await vm.searchUsersListForPOSTerminal(keyward: keyword)
            guard id == searchRequestId else { return }
            searchLoading = false
            searchResults = list
            showSearchDropdown = true
        }
    }

    /// `TextField` + search button; results list like global search dropdown (`SearchBarWithResults`).
    private var marketExampleBeamioTagSearchField: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("@BeamioTag")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(MarketExampleTerminalTheme.onSurfaceVariant)
                .padding(.leading, 4)
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    TextField("e.g. coffee_house_ny", text: $tagQuery)
                        .focused($tagFieldFocused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .submitLabel(.search)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(MarketExampleTerminalTheme.onSurface)
                        .padding(.leading, 18)
                        .onSubmit {
                            searchDebounceTask?.cancel()
                            startTerminalTagSearch(keyword: keywordForSearch)
                        }
                    Button {
                        BeamioHaptic.light()
                        searchDebounceTask?.cancel()
                        startTerminalTagSearch(keyword: keywordForSearch)
                    } label: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(MarketExampleTerminalTheme.primary)
                                .frame(width: 48, height: 48)
                                .shadow(color: MarketExampleTerminalTheme.primary.opacity(0.35), radius: 8, x: 0, y: 4)
                            if searchLoading {
                                ProgressView()
                                    .tint(.white)
                                    .scaleEffect(0.9)
                            } else {
                                Image(systemName: "magnifyingglass")
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.white)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(keywordForSearch.count < 2 || searchLoading)
                    .opacity(keywordForSearch.count < 2 ? 0.45 : 1)
                    .padding(.trailing, 8)
                    .padding(.vertical, 8)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: 62)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(MarketExampleTerminalTheme.surfaceContainerLow))

                if showSearchDropdown, keywordForSearch.count >= 2 {
                    VStack(alignment: .leading, spacing: 0) {
                        if searchLoading, searchResults.isEmpty {
                            HStack {
                                Spacer()
                                ProgressView()
                                    .padding(.vertical, 20)
                                Spacer()
                            }
                        } else if searchResults.isEmpty {
                            Text("No matches")
                                .font(.system(size: 14))
                                .foregroundStyle(MarketExampleTerminalTheme.onSurfaceVariant)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 16)
                        } else {
                            ScrollView {
                                VStack(spacing: 0) {
                                    ForEach(Array(searchResults.enumerated()), id: \.offset) { _, profile in
                                        Button {
                                            selectTerminalSearchProfile(profile)
                                        } label: {
                                            marketExampleSearchResultRow(profile: profile)
                                        }
                                        .buttonStyle(.plain)
                                        Divider()
                                            .background(MarketExampleTerminalTheme.outlineVariant.opacity(0.2))
                                    }
                                }
                            }
                            .frame(maxHeight: 220)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(MarketExampleTerminalTheme.surfaceContainerLowest)
                            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(MarketExampleTerminalTheme.outlineVariant.opacity(0.15), lineWidth: 1)
                    )
                    .padding(.top, 6)
                }
            }
        }
    }

    private func selectTerminalSearchProfile(_ profile: TerminalProfile) {
        BeamioHaptic.medium()
        if let t = profile.accountName?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            tagQuery = t
        } else if let a = profile.address?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
            tagQuery = marketExampleShortAddr(a)
        }
        selectedLookup = profile
        showSearchDropdown = false
        searchResults = []
        tagFieldFocused = false
    }

    /// SilentPassUI `Home.tsx` wallet capsule: pill + 40pt avatar + `homeBeamioTagLabel` (`@` + normalized tag); remove control on the right.
    private func marketExampleSelectedProfileBlock(profile: TerminalProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 12) {
                HStack(spacing: 10) {
                    marketExampleSearchRowAvatar(profile: profile, size: 40)
                    Text(marketExampleHomeStyleBeamioTagLabel(profile))
                        .font(.system(size: 15, weight: .bold))
                        .tracking(-0.2)
                        .foregroundStyle(MarketExampleTerminalTheme.onSurface)
                        .lineLimit(1)
                }
                .padding(.leading, 8)
                .padding(.trailing, 16)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(MarketExampleTerminalTheme.surfaceContainerLowest)
                        .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(MarketExampleTerminalTheme.outlineVariant.opacity(0.18), lineWidth: 1)
                )

                Button {
                    clearTerminalSearchSelection()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 28))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(
                            MarketExampleTerminalTheme.onSurfaceVariant.opacity(0.5),
                            MarketExampleTerminalTheme.surfaceContainerLow
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove selection")
            }

            Button {
                onGetStarted(normalizedTagQuery)
            } label: {
                HStack {
                    Text("Next Phase")
                        .font(.system(size: 18, weight: .bold))
                    Spacer(minLength: 12)
                    HStack(spacing: 6) {
                        Text("Authorize")
                            .font(.system(size: 14, weight: .regular))
                            .opacity(0.7)
                        Image(systemName: "arrow.forward")
                            .font(.system(size: 18, weight: .semibold))
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .frame(maxWidth: .infinity)
                .frame(height: 62)
                .background(
                    Capsule()
                        .fill(MarketExampleTerminalTheme.primary)
                        .shadow(color: MarketExampleTerminalTheme.primary.opacity(0.35), radius: 16, x: 0, y: 6)
                )
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())
        }
    }

    /// Same semantics as `Home.tsx` `useMemo` for `homeBeamioTagLabel`: strip leading `@`, then `@{normalized}`.
    private func marketExampleHomeStyleBeamioTagLabel(_ profile: TerminalProfile) -> String {
        if let raw = profile.accountName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            var normalized = raw
            while normalized.hasPrefix("@") { normalized.removeFirst() }
            if normalized.isEmpty { normalized = "Beamio" }
            return "@\(normalized)"
        }
        if let a = profile.address?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
            return marketExampleShortAddr(a)
        }
        return "@—"
    }

    private func clearTerminalSearchSelection() {
        BeamioHaptic.light()
        selectedLookup = nil
        tagQuery = ""
        searchResults = []
        showSearchDropdown = false
        searchDebounceTask?.cancel()
        tagFieldFocused = false
    }

    private func marketExampleSearchResultRow(profile: TerminalProfile) -> some View {
        let title = marketExampleSearchRowTitleBeamioTag(profile)
        let subtitle = marketExampleSearchRowSubtitleShortAddress(profile)
        return HStack(alignment: .center, spacing: 12) {
            marketExampleSearchRowAvatar(profile: profile, size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(MarketExampleTerminalTheme.onSurface)
                    .lineLimit(1)
                if let sub = subtitle {
                    Text(sub)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(MarketExampleTerminalTheme.onSurfaceVariant)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MarketExampleTerminalTheme.outlineVariant)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
    }

    /// List row title: `@` + normalized BeamioTag; if no tag, fall back to short address.
    private func marketExampleSearchRowTitleBeamioTag(_ profile: TerminalProfile) -> String {
        if let raw = profile.accountName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
            var n = raw
            while n.hasPrefix("@") { n.removeFirst() }
            if n.isEmpty { return "—" }
            return "@\(n)"
        }
        if let a = profile.address?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty {
            return marketExampleShortAddr(a)
        }
        return "—"
    }

    /// List row subtitle: shortened on-chain address (omit when same as title to avoid duplicate lines).
    private func marketExampleSearchRowSubtitleShortAddress(_ profile: TerminalProfile) -> String? {
        guard let a = profile.address?.trimmingCharacters(in: .whitespacesAndNewlines), !a.isEmpty else { return nil }
        let short = marketExampleShortAddr(a)
        let title = marketExampleSearchRowTitleBeamioTag(profile)
        if title == short { return nil }
        return short
    }

    @ViewBuilder
    private func marketExampleSearchRowAvatar(profile: TerminalProfile, size: CGFloat) -> some View {
        let trimmed = profile.image?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let seed = profile.accountName ?? profile.address ?? "beamio"
        let enc = seed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? seed
        let fallbackUrl = URL(string: "https://api.dicebear.com/8.x/fun-emoji/png?seed=\(enc)")
        if !trimmed.isEmpty {
            BeamioCardRasterOrSvgImage(urlString: trimmed, rasterContentMode: .fill) {
                marketExampleDicebearFallback(url: fallbackUrl, size: size)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
        } else {
            marketExampleDicebearFallback(url: fallbackUrl, size: size)
        }
    }

    private func marketExampleDicebearFallback(url: URL?, size: CGFloat) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img):
                img.resizable().scaledToFill()
            case .failure, .empty:
                Circle().fill(MarketExampleTerminalTheme.surfaceContainerLow)
            @unknown default:
                Circle().fill(MarketExampleTerminalTheme.surfaceContainerLow)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private func marketExampleProfileDisplayName(_ profile: TerminalProfile) -> String {
        let f = profile.firstName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lastRaw = profile.lastName?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\r\n").first.map(String.init) ?? ""
        let l0 = lastRaw.hasPrefix("{") ? "" : lastRaw.trimmingCharacters(in: .whitespacesAndNewlines)
        let both = "\(f) \(l0)".trimmingCharacters(in: .whitespacesAndNewlines)
        if !both.isEmpty { return both }
        let tag = profile.accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !tag.isEmpty { return tag }
        if let a = profile.address { return marketExampleShortAddr(a) }
        return "—"
    }

    private func marketExampleShortAddr(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 10 else { return t }
        return "\(t.prefix(6))…\(t.suffix(4))"
    }

    /// Status row: reflects optional selection from search (existing workspace lookup).
    private func marketExampleInfoStatusCard(selected: TerminalProfile?) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(MarketExampleTerminalTheme.primary.opacity(0.1))
                    .frame(width: 48, height: 48)
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(MarketExampleTerminalTheme.primary)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(selected == nil ? "Ready to bind" : "Profile selected")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(MarketExampleTerminalTheme.onSurface)
                Text(
                    selected == nil
                        ? "Type at least 2 characters, then search. Tap a result to confirm your workspace tag, then use Next Phase below the profile capsule."
                        : "Tap Next Phase to open wallet setup with this handle prefilled. Use the remove control to search again."
                )
                    .font(.system(size: 12))
                    .foregroundStyle(MarketExampleTerminalTheme.onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            ZStack {
                Circle()
                    .fill(MarketExampleTerminalTheme.primaryFixed)
                    .frame(width: 24, height: 24)
                Circle()
                    .fill(MarketExampleTerminalTheme.primary)
                    .frame(width: 8, height: 8)
                    .opacity(0.85)
                    .modifier(MarketExamplePulseDot())
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(MarketExampleTerminalTheme.surfaceContainerLow.opacity(0.5))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(MarketExampleTerminalTheme.outlineVariant.opacity(0.1), lineWidth: 1)
                )
        )
    }

}

private struct MarketExamplePulseDot: ViewModifier {
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? 1.15 : 1.0)
            .opacity(on ? 0.55 : 1.0)
            .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

private struct OnboardingView: View {
    @ObservedObject var vm: POSViewModel
    var onBack: () -> Void

    private enum TagStatus: Equatable {
        case idle
        case checking
        case valid
        case invalid
    }

    @FocusState private var focus: Field?
    private enum Field: Hashable {
        case handle
        case password
        case confirm
    }

    @State private var beamioTag = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var showPassword = false
    @State private var isSubmitting = false
    @State private var tagStatus: TagStatus = .idle
    @State private var tagError = ""
    @State private var lastCheckedTag = ""
    @State private var tagDebounceTask: Task<Void, Never>?

    private let brandBlue = Color(red: 0.08, green: 0.38, blue: 0.94)

    private var normalizedTag: String {
        var s = beamioTag.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("@") { s.removeFirst() }
        return s
    }

    private func localValidateTag(_ raw: String) -> (ok: Bool, value: String, msg: String) {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasPrefix("@") { trimmed.removeFirst() }
        if trimmed.isEmpty { return (false, trimmed, "Please enter a business handle") }
        if trimmed.range(of: "^[a-zA-Z0-9_.]{3,20}$", options: .regularExpression) == nil {
            return (false, trimmed, "Use 3–20 letters, numbers, dots, or underscores")
        }
        return (true, trimmed, "")
    }

    private var tagOk: Bool { tagStatus == .valid }
    private var isCheckingTag: Bool { tagStatus == .checking }
    private var passwordRules: (len8: Bool, mixed: Bool, numbers: Bool) {
        let len8 = password.count >= 8
        let mixed = password.range(of: "[a-z]", options: .regularExpression) != nil
            && password.range(of: "[A-Z]", options: .regularExpression) != nil
        let numbers = password.range(of: "[0-9]", options: .regularExpression) != nil
        return (len8, mixed, numbers)
    }

    private var passwordsMatch: Bool { password.count > 0 && password == confirmPassword }
    private var confirmMismatch: Bool { confirmPassword.count > 0 && password != confirmPassword }

    private var canSubmit: Bool {
        tagOk && passwordRules.len8 && passwordRules.mixed && passwordRules.numbers && passwordsMatch && !isSubmitting && !isCheckingTag
    }

    /// Mirrors `BusinessIdentityForm` `validateAndCheckTag`.
    @MainActor
    @discardableResult
    private func validateAndCheckTag() async -> Bool {
        if tagStatus == .checking { return false }
        let loc = localValidateTag(beamioTag)

        tagError = ""

        if !loc.ok {
            if loc.value.count > 0 {
                tagStatus = .invalid
                tagError = loc.msg
            } else {
                tagStatus = .idle
            }
            return false
        }

        let v = loc.value
        if v == lastCheckedTag, tagStatus == .valid { return true }
        lastCheckedTag = v

        tagStatus = .checking

        let available = await vm.api.isBeamioAccountNameAvailable(v)
        if available == false {
            tagStatus = .invalid
            tagError = "@\(v) is already taken"
        } else if available == true {
            tagStatus = .valid
            tagError = ""
        } else {
            tagStatus = .invalid
            tagError = "Network error. Try again."
        }
        return available == true
    }

    private func scheduleTagDebounceCheck() {
        tagDebounceTask?.cancel()
        let trimmed = normalizedTag
        if trimmed.count <= 2 { return }
        if trimmed == lastCheckedTag, tagStatus == .valid { return }

        tagDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            _ = await validateAndCheckTag()
        }
    }

    @MainActor
    private func handleContinue() async {
        let tagOkNow = await validateAndCheckTag()
        guard tagOkNow else { return }
        let r = passwordRules
        guard r.len8, r.mixed, r.numbers, password == confirmPassword else { return }

        isSubmitting = true
        await vm.completeOnboarding(beamioAccountName: beamioTag, password: password, confirmPassword: confirmPassword)
        isSubmitting = false
    }

    var body: some View {
        NavigationStack {
            ZStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        introHeader
                        formBody
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 32)
                }
                .background(Color(uiColor: .systemGroupedBackground))
                .disabled(isSubmitting)

                if isSubmitting {
                    onboardingLoadingOverlay
                }
            }
            .navigationTitle("Wallet setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") {
                        BeamioHaptic.light()
                        onBack()
                    }
                    .disabled(isSubmitting)
                }
            }
            .onChange(of: beamioTag) { _, _ in
                if isCheckingTag { return }
                tagStatus = .idle
                tagError = ""
                scheduleTagDebounceCheck()
            }
            .onChange(of: focus) { old, new in
                if old == .handle, new != .handle {
                    let s = normalizedTag
                    if s.count >= 3 { Task { await validateAndCheckTag() } }
                }
            }
            .onAppear {
                let parent = vm.onboardingParentBeamioTag.trimmingCharacters(in: .whitespacesAndNewlines)
                vm.onboardingParentBeamioTag = ""
                guard !parent.isEmpty else { return }
                lastCheckedTag = ""
                tagError = ""
                tagStatus = .checking
                Task { @MainActor in
                    let suggested = await vm.resolveFirstAvailablePosTerminalTag(parent: parent)
                    guard !suggested.isEmpty else {
                        tagStatus = .invalid
                        tagError = "Could not verify an available terminal handle. Check your connection and try again, or enter a handle manually."
                        return
                    }
                    beamioTag = suggested
                    lastCheckedTag = suggested
                    tagStatus = .valid
                    tagError = ""
                }
            }
            .onDisappear { tagDebounceTask?.cancel() }
        }
    }

    private var tagInvalidBorder: Color {
        tagStatus == .invalid ? Color.orange.opacity(0.9) : .clear
    }

    private var introHeader: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Step 1 of 2")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(brandBlue.opacity(0.08))
                    .foregroundStyle(brandBlue)
                    .clipShape(Capsule())
                Spacer()
                Text("Business identity")
                    .font(.system(size: 10, weight: .bold))
                    .tracking(2)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 8)

            Text("Create your business identity")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(Color(uiColor: .label))
                .fixedSize(horizontal: false, vertical: true)

            Text("Choose your Verra handle and set the password that protects your business workspace.")
                .font(.body)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 28)
    }

    private var formBody: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Business handle")
                    .font(.system(size: 11, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(Color(uiColor: .label).opacity(0.7))

                TextField("@yourbusiness", text: $beamioTag)
                    .focused($focus, equals: .handle)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .submitLabel(.next)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(tagInvalidBorder, lineWidth: tagStatus == .invalid ? 2 : 0)
                    )
                    .disabled(isSubmitting || isCheckingTag)
                    .onSubmit {
                        guard !isSubmitting, !isCheckingTag else { return }
                        Task { @MainActor in
                            let ok = await validateAndCheckTag()
                            if ok { focus = .password }
                        }
                    }
                    .onChange(of: beamioTag) { _, new in
                        let stripped = new.replacingOccurrences(of: "@", with: "")
                        if stripped != new { beamioTag = stripped }
                    }

                if tagStatus == .invalid, !tagError.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Text(tagError)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.orange)
                    }
                    .padding(.leading, 4)
                } else if tagStatus == .valid, !normalizedTag.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(brandBlue)
                        Text("@\(normalizedTag) is available")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(brandBlue)
                    }
                    .padding(.leading, 4)
                }

                if isCheckingTag {
                    HStack(spacing: 8) {
                        ProgressView()
                            .scaleEffect(0.85)
                        Text("Checking availability…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
            }

            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Account password")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color(uiColor: .label).opacity(0.7))

                    HStack(spacing: 12) {
                        Group {
                            if showPassword {
                                TextField("Password", text: $password)
                                    .textContentType(.newPassword)
                            } else {
                                SecureField("Password", text: $password)
                                    .textContentType(.newPassword)
                            }
                        }
                        .focused($focus, equals: .password)
                        .submitLabel(.next)
                        .onSubmit { focus = .confirm }
                        .disabled(isSubmitting)
                        .frame(maxWidth: .infinity, alignment: .leading)

                        Button {
                            showPassword.toggle()
                        } label: {
                            Image(systemName: showPassword ? "eye.slash.fill" : "eye.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
                        .disabled(isSubmitting)
                    }
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                }

                VStack(alignment: .leading, spacing: 10) {
                    Text("Confirm password")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(1.2)
                        .foregroundStyle(Color(uiColor: .label).opacity(0.7))

                    Group {
                        if showPassword {
                            TextField("Confirm password", text: $confirmPassword)
                                .textContentType(.newPassword)
                        } else {
                            SecureField("Confirm password", text: $confirmPassword)
                                .textContentType(.newPassword)
                        }
                    }
                    .focused($focus, equals: .confirm)
                    .submitLabel(.go)
                    .onSubmit {
                        guard canSubmit else { return }
                        Task { await handleContinue() }
                    }
                    .disabled(isSubmitting)
                    .padding(16)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .secondarySystemGroupedBackground)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .strokeBorder(confirmMismatch ? Color.orange.opacity(0.9) : .clear, lineWidth: confirmMismatch ? 2 : 0)
                    )
                }
            }

            passwordRulesHint

            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "checkmark.shield.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary.opacity(0.45))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Protected by local encryption")
                        .font(.system(size: 11, weight: .bold))
                        .tracking(0.6)
                    Text("Your business credentials stay encrypted on this device and under your control.")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.top, 4)

            Button {
                BeamioHaptic.light()
                vm.showVerraWorkspaceGateway = true
            } label: {
                HStack(spacing: 0) {
                    Text("Already have a wallet? ")
                        .foregroundStyle(.secondary)
                    Text("Restore")
                        .underline()
                        .foregroundStyle(brandBlue)
                }
                .font(.system(size: 14, weight: .medium))
            }
            .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
            .frame(maxWidth: .infinity)
            .disabled(isSubmitting)
            .opacity(isSubmitting ? 0.45 : 1)
            .padding(.top, 12)

            Button {
                Task { await handleContinue() }
            } label: {
                HStack {
                    Text("Continue")
                        .font(.headline.weight(.heavy))
                    Image(systemName: "arrow.right")
                        .font(.headline.weight(.bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 14)
                        .fill(canSubmit ? brandBlue : Color(uiColor: .systemGray4))
                )
                .foregroundStyle(canSubmit ? .white : .secondary)
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())
            .disabled(!canSubmit)
            .padding(.top, 8)
        }
    }

    private var passwordRulesHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            ruleRow(ok: passwordRules.len8, text: "At least 8 characters")
            ruleRow(ok: passwordRules.mixed, text: "Upper and lower case letters")
            ruleRow(ok: passwordRules.numbers, text: "At least one number")
        }
        .padding(.top, 4)
    }

    private func ruleRow(ok: Bool, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .font(.caption)
                .foregroundStyle(ok ? AnyShapeStyle(brandBlue) : AnyShapeStyle(.tertiary))
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var onboardingLoadingOverlay: some View {
        OnboardingCreatingOverlay(brandBlue: brandBlue)
    }
}

private struct OnboardingCreatingOverlay: View {
    private struct Step: Identifiable {
        let id: Int
        let title: String
        let description: String
        let symbol: String
    }

    let brandBlue: Color
    @State private var creatingStep = 0
    @State private var spin = false
    @State private var pulse = false

    private let steps = [
        Step(id: 0, title: "Generating Secure ID", description: "Creating cryptographic keys", symbol: "key.fill"),
        Step(id: 1, title: "Finalizing Terminal", description: "Preparing user interface", symbol: "arrow.clockwise")
    ]

    var body: some View {
        ZStack {
            Color.white.ignoresSafeArea()
            Circle()
                .fill(brandBlue.opacity(0.08))
                .frame(width: 240, height: 240)
                .blur(radius: 70)
                .offset(x: 110, y: -230)
            Circle()
                .fill(Color(red: 0.27, green: 0.36, blue: 0.6).opacity(0.07))
                .frame(width: 280, height: 280)
                .blur(radius: 80)
                .offset(x: -130, y: 240)

            VStack(spacing: 34) {
                loaderMark

                VStack(spacing: 28) {
                    Text("Securing your identity...")
                        .font(.system(size: 30, weight: .heavy))
                        .tracking(-0.4)
                        .foregroundStyle(Color(uiColor: .label))
                        .multilineTextAlignment(.center)

                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(steps.indices, id: \.self) { idx in
                            loadingStepRow(step: steps[idx], idx: idx)
                        }
                    }
                    .frame(maxWidth: 330)
                }
            }
            .padding(.horizontal, 28)
        }
        .allowsHitTesting(true)
        .task {
            creatingStep = 0
            spin = true
            pulse = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.25)) {
                creatingStep = min(1, steps.count - 1)
            }
        }
    }

    private var loaderMark: some View {
        ZStack {
            Circle()
                .stroke(Color(red: 0.76, green: 0.78, blue: 0.85).opacity(0.3), lineWidth: 1.5)
                .frame(width: 224, height: 224)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 12).repeatForever(autoreverses: false), value: spin)
            Circle()
                .stroke(brandBlue.opacity(0.2), lineWidth: 1)
                .frame(width: 172, height: 172)
                .rotationEffect(.degrees(spin ? -360 : 0))
                .animation(.linear(duration: 8).repeatForever(autoreverses: false), value: spin)
            Circle()
                .stroke(brandBlue.opacity(0.1), lineWidth: 2)
                .frame(width: 116, height: 116)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 15).repeatForever(autoreverses: false), value: spin)
            Circle()
                .fill(brandBlue.opacity(0.1))
                .frame(width: pulse ? 184 : 162, height: pulse ? 184 : 162)
                .blur(radius: 28)
                .animation(.easeInOut(duration: 4).repeatForever(autoreverses: true), value: pulse)

            Circle()
                .fill(.white.opacity(0.72))
                .frame(width: 128, height: 128)
                .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 1))
                .shadow(color: .black.opacity(0.06), radius: 32, y: 8)
                .overlay {
                    Image("LaunchBrandLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: pulse ? 58 : 54, height: pulse ? 58 : 54)
                        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .animation(.easeInOut(duration: 3).repeatForever(autoreverses: true), value: pulse)
                }

            Circle()
                .fill(brandBlue)
                .frame(width: 12, height: 12)
                .shadow(color: brandBlue.opacity(0.6), radius: 12)
                .offset(y: -112)
                .rotationEffect(.degrees(spin ? 360 : 0))
                .animation(.linear(duration: 12).repeatForever(autoreverses: false), value: spin)
        }
        .frame(width: 240, height: 240)
        .accessibilityHidden(true)
    }

    private func loadingStepRow(step: Step, idx: Int) -> some View {
        let isCompleted = idx < creatingStep
        let isActive = idx == creatingStep

        return HStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(isCompleted ? Color.green.opacity(0.1) : isActive ? brandBlue.opacity(0.1) : Color(uiColor: .systemGray5))
                    .frame(width: 32, height: 32)
                if isActive {
                    Circle()
                        .trim(from: 0.12, to: 1)
                        .stroke(brandBlue, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 32, height: 32)
                        .rotationEffect(.degrees(spin ? 360 : 0))
                        .animation(.linear(duration: 1.1).repeatForever(autoreverses: false), value: spin)
                }
                Image(systemName: isCompleted ? "checkmark" : step.symbol)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(isCompleted ? Color.green : isActive ? brandBlue : Color(uiColor: .secondaryLabel))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(step.title)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .label))
                Text(step.description)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            Spacer(minLength: 0)
        }
        .opacity(!isCompleted && !isActive ? 0.4 : 1)
    }
}

private struct RecoveryKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.displayScale) private var displayScale
    let code: String
    @State private var copied = false
    @State private var hasBackedUp = false
    @State private var isConfirmed = false
    @State private var saveError: String?

    private let brandBlue = Color(red: 0.08, green: 0.38, blue: 0.94)
    private let deepBlue = Color(red: 0.0, green: 0.29, blue: 0.76)

    private var qrImage: UIImage? {
        BeamioLinkAppQr.image(from: code, pointSize: 208, scale: displayScale)
    }

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            let compact = h < 720
            let tight = h < 640
            let ultra = h < 580
            let metrics = RecoveryBackupMetrics(
                titleSize: ultra ? 21 : tight ? 23 : compact ? 25 : 28,
                bodySize: ultra ? 11 : tight ? 12 : 13,
                qrSize: ultra ? 150 : tight ? 168 : compact ? 192 : 222,
                logoSize: ultra ? 30 : tight ? 34 : compact ? 40 : 46,
                cardPadding: ultra ? 8 : tight ? 9 : 11,
                sectionSpacing: ultra ? 8 : tight ? 10 : compact ? 12 : 16,
                buttonVerticalPadding: ultra ? 8 : tight ? 10 : 12,
                footerSpacing: ultra ? 6 : 8,
                horizontalPadding: tight ? 16 : 20,
                topPadding: max(8, geo.safeAreaInsets.top + (ultra ? 4 : 8)),
                bottomPadding: max(8, geo.safeAreaInsets.bottom + (ultra ? 4 : 8))
            )

            VStack(spacing: 0) {
                mainBackupContent(metrics: metrics)
                footerControls(metrics: metrics)
            }
            .padding(.horizontal, metrics.horizontalPadding)
            .padding(.top, metrics.topPadding)
            .padding(.bottom, metrics.bottomPadding)
            .frame(width: geo.size.width, height: geo.size.height)
            .background(Color.white.ignoresSafeArea())
        }
        .interactiveDismissDisabled(!isConfirmed)
    }

    private struct RecoveryBackupMetrics {
        let titleSize: CGFloat
        let bodySize: CGFloat
        let qrSize: CGFloat
        let logoSize: CGFloat
        let cardPadding: CGFloat
        let sectionSpacing: CGFloat
        let buttonVerticalPadding: CGFloat
        let footerSpacing: CGFloat
        let horizontalPadding: CGFloat
        let topPadding: CGFloat
        let bottomPadding: CGFloat
    }

    private func mainBackupContent(metrics: RecoveryBackupMetrics) -> some View {
        VStack(spacing: metrics.sectionSpacing) {
            VStack(spacing: 4) {
                Text("Security Backup")
                    .font(.system(size: metrics.titleSize, weight: .heavy))
                    .tracking(-0.4)
                    .foregroundStyle(Color(uiColor: .label))
                VStack(spacing: 2) {
                    Text("Your Recovery Code is your master key.")
                    Text("If you lose your phone,")
                    Text("this is the only way to get your funds back.")
                }
                .font(.system(size: metrics.bodySize, weight: .medium))
                .foregroundStyle(Color(uiColor: .secondaryLabel))
                .multilineTextAlignment(.center)
            }

            qrCard(metrics: metrics)

            VStack(spacing: 10) {
                backupButton(
                    title: "Save to Photos",
                    systemName: "square.and.arrow.down",
                    foreground: .white,
                    background: LinearGradient(colors: [deepBlue, brandBlue], startPoint: .topLeading, endPoint: .bottomTrailing),
                    disabled: isConfirmed,
                    verticalPadding: metrics.buttonVerticalPadding,
                    action: saveRecoveryImage
                )

                if let saveError {
                    Text(saveError)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 0.73, green: 0.1, blue: 0.1))
                        .multilineTextAlignment(.center)
                }

                Button {
                    copyRecoveryCode()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 15, weight: .bold))
                        Text(copied ? "Copied" : "Copy Recovery Code")
                            .font(.system(size: 14, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, metrics.buttonVerticalPadding)
                    .foregroundStyle(Color(uiColor: .label))
                    .background(Color(uiColor: .systemGray5))
                    .clipShape(Capsule())
                }
                .buttonStyle(BeamioHapticPlainButtonStyle(impact: .medium))
                .disabled(code.isEmpty || isConfirmed)
                .opacity((code.isEmpty || isConfirmed) ? 0.5 : 1)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func qrCard(metrics: RecoveryBackupMetrics) -> some View {
        VStack(spacing: metrics.sectionSpacing * 0.6) {
            ZStack {
                Circle()
                    .fill(brandBlue.opacity(0.06))
                    .blur(radius: 24)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color(uiColor: .systemGray5))
                if let qrImage {
                    Image(uiImage: qrImage)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(8)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .overlay {
                            Image("LaunchBrandLogo")
                                .resizable()
                                .scaledToFit()
                                .frame(width: metrics.logoSize, height: metrics.logoSize)
                                .padding(4)
                                .background(Color.white)
                                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                        }
                        .padding(8)
                        .accessibilityLabel("Recovery QR code")
                } else {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(Color(uiColor: .systemGray4))
                        .overlay {
                            Text("Recovery QR unavailable")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                        .padding(8)
                }
            }
            .frame(width: metrics.qrSize, height: metrics.qrSize)

            HStack(spacing: 8) {
                Text(code.isEmpty ? "Not available" : code)
                    .font(.system(size: metrics.bodySize - 1, weight: .medium, design: .monospaced))
                    .tracking(1.4)
                    .textCase(.uppercase)
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(2)
                    .minimumScaleFactor(0.72)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Image(systemName: "lock.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(brandBlue)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color(red: 0.95, green: 0.95, blue: 0.97))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(metrics.cardPadding)
        .background(Color.white.opacity(0.96))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color(uiColor: .systemGray5), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
    }

    private func footerControls(metrics: RecoveryBackupMetrics) -> some View {
        VStack(spacing: metrics.footerSpacing) {
            Button {
                guard hasBackedUp else { return }
                BeamioHaptic.light()
                isConfirmed.toggle()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isConfirmed ? deepBlue : Color(uiColor: .systemGray5))
                            .frame(width: 22, height: 22)
                        if isConfirmed {
                            Image(systemName: "checkmark")
                                .font(.system(size: 12, weight: .heavy))
                                .foregroundStyle(.white)
                        }
                    }
                    Text("I have securely saved my recovery code")
                        .font(.system(size: metrics.bodySize, weight: .medium))
                        .foregroundStyle(Color(uiColor: .label))
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 0)
                }
                .padding(metrics.buttonVerticalPadding)
                .background(Color(uiColor: .systemGray6))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color(uiColor: .systemGray5), lineWidth: 1)
                )
                .opacity(hasBackedUp ? 1 : 0.4)
            }
            .buttonStyle(.plain)
            .disabled(!hasBackedUp)

            Button {
                BeamioHaptic.medium()
                dismiss()
            } label: {
                HStack(spacing: 8) {
                    Text("Continue")
                        .font(.system(size: 14, weight: .bold))
                    Image(systemName: "arrow.right")
                        .font(.system(size: 13, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, metrics.buttonVerticalPadding)
                .background(isConfirmed ? deepBlue : Color(uiColor: .systemGray4))
                .foregroundStyle(isConfirmed ? .white : Color(uiColor: .secondaryLabel))
                .clipShape(Capsule())
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())
            .disabled(!isConfirmed)
        }
    }

    private func backupButton(
        title: String,
        systemName: String,
        foreground: Color,
        background: LinearGradient,
        disabled: Bool,
        verticalPadding: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemName)
                    .font(.system(size: 15, weight: .bold))
                Text(title)
                    .font(.system(size: 14, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, verticalPadding)
            .foregroundStyle(foreground)
            .background(background)
            .clipShape(Capsule())
        }
        .buttonStyle(BeamioHapticPlainButtonStyle(impact: .medium))
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
    }

    private func saveRecoveryImage() {
        guard let qrImage else {
            saveError = "Unable to create the recovery image. Please copy the recovery code instead."
            return
        }
        saveError = nil
        BeamioHaptic.medium()
        UIImageWriteToSavedPhotosAlbum(qrImage, nil, nil, nil)
        hasBackedUp = true
    }

    private func copyRecoveryCode() {
        guard !code.isEmpty else { return }
        BeamioHaptic.medium()
        UIPasteboard.general.string = code
        copied = true
        hasBackedUp = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            copied = false
        }
    }
}

// MARK: - Home (align Android `NdefScreen`)

private struct HomeRootView: View {
    @ObservedObject var vm: POSViewModel
    @Binding var amountFlow: AmountFlow?

    private let linkPurple = Color(red: 124 / 255, green: 58 / 255, blue: 237 / 255)
    private let brandBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)
    private let mintGreen = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)

    var body: some View {
        GeometryReader { geo in
            let tight = geo.size.height < 680
            let compact = geo.size.height < 760
            let outerPadding: CGFloat = tight ? 14 : 20
            let sectionGap: CGFloat = tight ? 12 : compact ? 16 : 20
            VStack(spacing: 0) {
                homeTopHeader
                    .padding(.horizontal, outerPadding)
                    .frame(height: tight ? 54 : 64)
                    .background(Color.white.opacity(0.94))
                    .overlay(alignment: .bottom) {
                        Rectangle()
                            .fill(Color(uiColor: .separator).opacity(0.38))
                            .frame(height: 0.5)
                    }

                VStack(spacing: sectionGap) {
                    homeHeroSummary(compact: compact, tight: tight)

                    HStack(spacing: tight ? 10 : 14) {
                        homeDataCard(
                            title: "Period Top-Ups",
                            value: dashboardCurrencyText(vm.cardTopUpAmount, loaded: vm.homeStatsLoaded),
                            titleTint: Color(uiColor: .secondaryLabel),
                            valueTint: Color(uiColor: .label),
                            compact: compact,
                            tight: tight
                        )
                        homeDataCard(
                            title: "B-Units",
                            value: dashboardBUnitText,
                            titleTint: Color(red: 0xd9 / 255, green: 0x77 / 255, blue: 0x06 / 255),
                            valueTint: Color(uiColor: .label),
                            compact: compact,
                            tight: tight
                        )
                    }

                    if vm.hasAAAccount == false {
                        homeWelcomeNoAA
                    }

                    homeChargeHeroButton(compact: compact, tight: tight) { amountFlow = .charge }
                        .frame(maxWidth: .infinity)
                        .frame(height: tight ? 120 : compact ? 138 : 156)
                        .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))

                    homeActionArea(compact: compact, tight: tight, gap: tight ? 10 : 14)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
                .padding(.horizontal, outerPadding)
                .padding(.top, tight ? 14 : 22)
                .padding(.bottom, tight ? 14 : 22)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(Color.white)
    }

    private func homeActionArea(compact: Bool, tight: Bool, gap: CGFloat) -> some View {
        let tileHeight: CGFloat = tight ? 92 : compact ? 108 : 122
        return VStack(spacing: gap) {
            HStack(spacing: gap) {
                homeActionGridButton(
                    title: "Check Balance",
                    systemImage: "magnifyingglass",
                    iconTint: brandBlue
                ) { vm.beginReadBalance() }
                .frame(height: tileHeight)

                homeActionGridButton(
                    title: "Top-up",
                    systemImage: "plus",
                    iconTint: linkPurple
                ) { amountFlow = .topup }
                .frame(height: tileHeight)
            }

            HStack(spacing: gap) {
                homeActionGridButton(
                    title: "History",
                    systemImage: "list.bullet.rectangle",
                    iconTint: brandBlue
                ) {
                    amountFlow = .transactions
                    Task { @MainActor in await vm.openPosTransactionsScreen() }
                }
                .frame(height: tileHeight)

                homeActionGridButton(
                    title: "Link App",
                    systemImage: "link",
                    iconTint: brandBlue
                ) { vm.beginLinkApp() }
                .frame(height: tileHeight)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var homeTopHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            // Android `NdefScreen`: `ic_launcher_adaptive` in 40dp circle, `ContentScale.Crop`
            Image("LaunchBrandLogo")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .accessibilityLabel("App icon")
            VStack(alignment: .leading, spacing: 4) {
                Text(homeHeaderTitleLine)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            Spacer(minLength: 8)
            if let admin = vm.adminProfile, homeAdminCapsuleHasPresentableIdentity(admin) {
                HomeBeamioCapsuleCompact(profile: admin, fallbackAddress: nil)
            }
        }
    }

    /// Upper admin capsule: show only when profile has @handle or display name (no wallet-address fallback).
    private func homeAdminCapsuleHasPresentableIdentity(_ profile: TerminalProfile) -> Bool {
        let tag = sanitizeProfilePart(profile.accountName)
        if !tag.isEmpty { return true }
        let f = sanitizeProfilePart(profile.firstName)
        let lastRaw = profile.lastName?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\r\n").first.map(String.init) ?? ""
        let l0 = lastRaw.hasPrefix("{") ? "" : sanitizeProfilePart(lastRaw)
        let both = "\(f) \(l0)".trimmingCharacters(in: .whitespacesAndNewlines)
        return !both.isEmpty
    }

    /// Android `NdefScreen` title line: `@accountName` else `"\(first6)…\(last4)"` else `"Terminal"`.
    private var homeHeaderTitleLine: String {
        let tag = sanitizeProfilePart(vm.terminalProfile?.accountName)
        if !tag.isEmpty { return "@\(tag)" }
        if let a = vm.walletAddress { return homeHeaderWalletShortLine(a) }
        return "Terminal"
    }

    private func homeHeroSummary(compact: Bool, tight: Bool) -> some View {
        VStack(spacing: tight ? 6 : 8) {
            Text("Total Due")
                .font(.system(size: tight ? 11 : 13, weight: .heavy))
                .tracking(tight ? 2.0 : 2.8)
                .textCase(.uppercase)
                .foregroundStyle(Color(uiColor: .secondaryLabel))

            Text(dashboardTotalDueText)
                .font(.system(size: tight ? 44 : compact ? 54 : 64, weight: .heavy))
                .tracking(-2.2)
                .foregroundStyle(Color(uiColor: .label))
                .lineLimit(1)
                .minimumScaleFactor(0.42)
                .allowsTightening(true)
                .monospacedDigit()

            HStack(alignment: .center, spacing: 10) {
                Text("Subtotal \(dashboardSubtotalText)")
                Text("|")
                    .foregroundStyle(Color(uiColor: .secondaryLabel).opacity(0.5))
                Text("Tip \(dashboardTipOnlyText)")
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .font(.system(size: tight ? 12 : 14, weight: .medium))
            .foregroundStyle(Color(uiColor: .secondaryLabel))
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, tight ? 8 : 14)
    }

    private var dashboardTotalDueText: String {
        guard vm.homeStatsLoaded else { return "…" }
        guard let charge = vm.cardChargeAmount else { return "—" }
        return formatDashboardTotalDueAmount(charge, currency: "CAD")
    }

    private var dashboardSubtotalText: String {
        guard vm.homeStatsLoaded else { return "…" }
        guard let charge = vm.cardChargeAmount else { return "—" }
        return formatDashboardTotalDueAmount(max(0, charge - (vm.cardTipsAmount ?? 0)), currency: "CAD")
    }

    private var dashboardTipOnlyText: String {
        guard vm.homeStatsLoaded else { return "…" }
        guard let tips = vm.cardTipsAmount else { return "—" }
        return formatDashboardTotalDueAmount(tips, currency: "CAD")
    }

    private func formatDashboardTotalDueAmount(_ value: Double, currency: String) -> String {
        let amount = max(0, value)
        let prefix = dashboardCurrencyPrefix(currency)
        if amount > 10_000_000 {
            return "\(prefix) \(String(format: "%.2f", amount / 1_000_000))M"
        }
        if amount > 10_000 {
            return "\(prefix) \(String(format: "%.2f", amount / 1_000))K"
        }
        return "\(prefix) \(formatDashboardCurrencyCompact(amount))"
    }

    private func dashboardCurrencyPrefix(_ currency: String) -> String {
        switch currency.uppercased() {
        case "CAD": return "CA$"
        case "USD", "USDC": return "$"
        case "EUR": return "€"
        case "JPY": return "JP¥"
        case "TWD": return "NT$"
        case "CNY": return "CN¥"
        case "HKD": return "HK$"
        case "SGD": return "SG$"
        default: return currency.uppercased().isEmpty ? "$" : "\(currency.uppercased()) "
        }
    }

    private func homeDataCard(
        title: String,
        value: String,
        titleTint: Color,
        valueTint: Color,
        compact: Bool,
        tight: Bool
    ) -> some View {
        VStack(spacing: tight ? 5 : 7) {
            Text(title)
                .font(.system(size: tight ? 9 : 10, weight: .heavy))
                .tracking(1.3)
                .textCase(.uppercase)
                .foregroundStyle(titleTint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
            Text(value)
                .font(.system(size: tight ? 19 : compact ? 21 : 24, weight: .bold))
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
        .frame(height: tight ? 76 : compact ? 86 : 96)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color.white)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .stroke(Color(uiColor: .separator).opacity(0.42), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        )
    }

    private func dashboardBlackCard(compact: Bool, tight: Bool) -> some View {
        let metricSpacing: CGFloat = tight ? 16 : compact ? 21 : 26
        let cardPadding: CGFloat = tight ? 16 : compact ? 21 : 26
        return VStack(alignment: .leading, spacing: tight ? 6 : 10) {
            VStack(spacing: metricSpacing) {
                HStack(alignment: .center, spacing: metricSpacing) {
                    dashboardMetricTile(
                        title: "NET SALES",
                        systemImage: "banknote",
                        iconTint: brandBlue,
                        value: dashboardCurrencyText(vm.cardChargeAmount, loaded: vm.homeStatsLoaded),
                        detail: dashboardUsdcSettlementText(vm.cardChargeUsdcAmount, loaded: vm.homeStatsLoaded),
                        detailTint: mintGreen,
                        valueTint: brandBlue,
                        contentAlignment: .leading,
                        frameAlignment: .leading,
                        textAlignment: .leading,
                        compact: compact,
                        tight: tight
                    )
                    dashboardMetricTile(
                        title: "TIPS",
                        systemImage: "hands.sparkles",
                        iconTint: brandBlue,
                        value: dashboardCurrencyText(vm.cardTipsAmount, loaded: vm.homeStatsLoaded),
                        detail: dashboardUsdcSettlementText(vm.cardTipsUsdcAmount, loaded: vm.homeStatsLoaded),
                        detailTint: mintGreen,
                        contentAlignment: .trailing,
                        frameAlignment: .trailing,
                        textAlignment: .trailing,
                        compact: compact,
                        tight: tight
                    )
                }
                HStack(alignment: .center, spacing: metricSpacing) {
                    dashboardMetricTile(
                        title: "CREDITS",
                        systemImage: "creditcard",
                        iconTint: brandBlue,
                        value: dashboardCurrencyText(vm.cardTopUpAmount, loaded: vm.homeStatsLoaded),
                        detail: "Active Float",
                        detailTint: brandBlue,
                        contentAlignment: .leading,
                        frameAlignment: .leading,
                        textAlignment: .leading,
                        compact: compact,
                        tight: tight
                    )
                    dashboardMetricTile(
                        title: "B-UNITS",
                        systemImage: "bolt.fill",
                        iconTint: Color(red: 0xf5 / 255, green: 0xa6 / 255, blue: 0x00 / 255),
                        value: dashboardBUnitText,
                        detail: "Admin / Owner EOA",
                        detailTint: Color(uiColor: .secondaryLabel),
                        progress: dashboardBUnitProgress,
                        valueTint: Color(uiColor: .secondaryLabel),
                        valueFontSizeOffset: -4,
                        contentAlignment: .trailing,
                        frameAlignment: .trailing,
                        textAlignment: .trailing,
                        compact: compact,
                        tight: tight
                    )
                }
            }
            .padding(.horizontal, cardPadding)
            .padding(.vertical, cardPadding)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color(uiColor: .separator).opacity(0.45), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.04), radius: 6, y: 1)
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var homeProgramCardDisplayName: String {
        let name = vm.homeMerchantProgramCardName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return name.isEmpty ? "VERRA ELITE" : name
    }

    private func homeTopUpHeroButton(compact: Bool, tight: Bool, action: @escaping () -> Void) -> some View {
        let topupPurple = Color(red: 0xa7 / 255, green: 0x78 / 255, blue: 0xfa / 255)
        let topupDeepPurple = Color(red: 0x7c / 255, green: 0x3a / 255, blue: 0xed / 255)
        let topupPink = Color(red: 0xf0 / 255, green: 0x8a / 255, blue: 0xff / 255)
        return Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                topupPink,
                                topupPurple,
                                topupDeepPurple
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
                    .shadow(color: topupPurple.opacity(0.46), radius: 30, y: 15)
                    .shadow(color: topupDeepPurple.opacity(0.18), radius: 10, y: 4)

                VStack(spacing: tight ? 3 : 7) {
                    HStack {
                        Text(homeProgramCardDisplayName)
                            .font(.system(size: tight ? 8 : 10, weight: .heavy))
                            .tracking(tight ? 1.8 : 2.4)
                            .foregroundStyle(Color.white.opacity(0.86))
                            .lineLimit(1)
                            .minimumScaleFactor(0.58)
                        Spacer(minLength: 6)
                        if let badge = homeTopUpBonusBadgeText {
                            Text(badge)
                                .font(.system(size: tight ? 7 : 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, tight ? 6 : 9)
                                .padding(.vertical, tight ? 4 : 5)
                                .background(Capsule().fill(Color.white.opacity(0.22)))
                                .overlay(Capsule().stroke(Color.white.opacity(0.24), lineWidth: 0.5))
                                .lineLimit(1)
                                .minimumScaleFactor(0.72)
                        }
                    }

                    Spacer(minLength: 0)

                    ZStack {
                        Circle()
                            .fill(Color.white.opacity(0.22))
                            .frame(width: tight ? 28 : compact ? 36 : 46, height: tight ? 28 : compact ? 36 : 46)
                        Image(systemName: "creditcard.fill")
                            .font(.system(size: tight ? 14 : compact ? 18 : 22, weight: .semibold))
                            .foregroundStyle(.white)
                        Image(systemName: "plus")
                            .font(.system(size: tight ? 8 : 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .offset(x: tight ? 11 : 15, y: tight ? 8 : 10)
                    }

                    VStack(spacing: 2) {
                        Text("Top-up Card")
                            .font(.system(size: tight ? 13 : compact ? 15 : 18, weight: .heavy))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(homeTopUpBonusLine)
                            .font(.system(size: tight ? 7 : 10, weight: .medium))
                            .tracking(tight ? 0.8 : 1.2)
                            .foregroundStyle(Color.white.opacity(0.78))
                            .lineLimit(1)
                            .minimumScaleFactor(0.65)
                    }
                }
                .padding(.horizontal, tight ? 10 : 14)
                .padding(.vertical, tight ? 7 : 12)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(BeamioHapticPlainButtonStyle())
    }

    private func homeChargeHeroButton(compact: Bool, tight: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(brandBlue)
                    .overlay(
                        LinearGradient(
                            colors: [Color.white.opacity(0.16), Color.white.opacity(0.0)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: brandBlue.opacity(0.26), radius: 18, y: 8)

                VStack(spacing: tight ? 8 : 12) {
                    Text("CHARGE")
                        .font(.system(size: tight ? 24 : compact ? 30 : 36, weight: .semibold))
                        .tracking(-0.6)
                        .foregroundStyle(.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)

                    HStack(spacing: 8) {
                        Image(systemName: "wave.3.right.circle")
                            .font(.system(size: tight ? 16 : 19, weight: .semibold))
                        Text("Tap to Pay or Scan")
                            .font(.system(size: tight ? 12 : 14, weight: .semibold))
                            .tracking(1.0)
                            .textCase(.uppercase)
                    }
                    .foregroundStyle(Color.white.opacity(0.86))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                }
                .padding(.horizontal, tight ? 14 : 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .buttonStyle(BeamioHapticPlainButtonStyle())
    }

    private func homeChargeHeroCapsuleRow(compact: Bool, tight: Bool) -> some View {
        HStack(alignment: .center, spacing: tight ? 6 : 8) {
            HomeBeamioSelfMiniCapsule(title: homeHeaderTitleLine, tight: tight)
            Spacer(minLength: 6)
            if let admin = vm.adminProfile, homeAdminCapsuleHasPresentableIdentity(admin) {
                HomeBeamioProfileMiniCapsule(profile: admin, tight: tight)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var homeTopUpBonusBadgeText: String? {
        guard let rule = vm.programRechargeBonusRules.first else { return nil }
        if rule.bonusProportional {
            return "\(homeRechargeBonusTierPercentLabel(rule))% BONUS"
        }
        return "+$\(formatHomeBonusAmount(rule.bonusValue))"
    }

    private var homeTopUpBonusLine: String {
        guard let rule = vm.programRechargeBonusRules.first else { return "MEMBER CREDITS" }
        if rule.bonusProportional {
            return "GET \(homeRechargeBonusTierPercentLabel(rule))% BONUS"
        }
        return "BONUS $\(formatHomeBonusAmount(rule.bonusValue))"
    }

    private func dashboardMetricTile(
        title: String,
        systemImage: String,
        iconTint: Color,
        value: String,
        detail: String,
        detailTint: Color,
        progress: Double? = nil,
        valueTint: Color = Color(uiColor: .label),
        valueFontSizeOffset: CGFloat = 0,
        contentAlignment: HorizontalAlignment = .leading,
        frameAlignment: Alignment = .leading,
        textAlignment: TextAlignment = .leading,
        compact: Bool,
        tight: Bool
    ) -> some View {
        let titleRowHeight: CGFloat = tight ? 15 : 18
        let valueRowHeight: CGFloat = tight ? 40 : compact ? 50 : 60
        let detailRowHeight: CGFloat = tight ? 13 : 16
        let valueFontSize: CGFloat = max(
            12,
            (tight ? (value.count > 9 ? 28 : 34) : compact ? (value.count > 9 ? 33 : 42) : (value.count > 9 ? 38 : 50)) + valueFontSizeOffset
        )
        return VStack(alignment: contentAlignment, spacing: tight ? 4 : 7) {
            HStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.system(size: tight ? 11 : 13, weight: .bold))
                    .foregroundStyle(iconTint)
                    .frame(width: tight ? 14 : 16)
                Text(title)
                    .font(.system(size: tight ? 10 : 12, weight: .heavy))
                    .tracking(tight ? 1.2 : 1.6)
                    .foregroundStyle(Color(uiColor: .label).opacity(0.78))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .multilineTextAlignment(textAlignment)
            }
            .frame(maxWidth: .infinity, minHeight: titleRowHeight, maxHeight: titleRowHeight, alignment: frameAlignment)
            Text(value)
                .font(.system(size: valueFontSize, weight: .heavy))
                .tracking(-0.8)
                .foregroundStyle(valueTint)
                .lineLimit(1)
                .minimumScaleFactor(0.58)
                .monospacedDigit()
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, minHeight: valueRowHeight, maxHeight: valueRowHeight, alignment: frameAlignment)
            Text(detail)
                .font(.system(size: tight ? 10 : 12, weight: .bold))
                .foregroundStyle(detailTint)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .monospacedDigit()
                .multilineTextAlignment(textAlignment)
                .frame(maxWidth: .infinity, minHeight: detailRowHeight, maxHeight: detailRowHeight, alignment: frameAlignment)
            if let progress {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color(uiColor: .systemGray5))
                        Capsule()
                            .fill(Color(red: 0xf5 / 255, green: 0xa6 / 255, blue: 0x00 / 255))
                            .frame(width: geo.size.width * max(0, min(1, progress)))
                    }
                }
                .frame(height: tight ? 5 : 6)
            }
        }
        .frame(maxWidth: .infinity, alignment: frameAlignment)
    }

    private func dashboardCurrencyText(_ value: Double?, loaded: Bool) -> String {
        guard loaded else { return "…" }
        guard let value else { return "—" }
        return "$" + formatDashboardCurrencyCompact(value)
    }

    private func dashboardUsdcSettlementText(_ value: Double?, loaded: Bool) -> String {
        guard loaded else { return "…" }
        guard let value else { return "— USDC" }
        let parts = readBalanceFormatMoney(value, currency: "USDC")
        return "\(parts.mid)\(parts.suffix)"
    }

    private func formatDashboardCurrencyCompact(_ value: Double) -> String {
        let amount = max(0, value)
        let centsRounded = (amount * 100).rounded() / 100
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: NSNumber(value: centsRounded)) ?? String(format: "%.2f", centsRounded)
    }

    private var dashboardBUnitText: String {
        guard vm.homeUpstreamBUnitLoaded else { return "…" }
        guard let value = vm.homeUpstreamBUnitBalance else { return "—" }
        return formatBUnitBalance(value)
    }

    private var dashboardBUnitProgress: Double? {
        guard let value = vm.homeUpstreamBUnitBalance else { return nil }
        return min(1, value / 100_000.0)
    }

    private func formatBUnitBalance(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = 0
        let rounded = max(0, value).rounded()
        return formatter.string(from: NSNumber(value: rounded)) ?? String(format: "%.0f", rounded)
    }

    /// Tier discount（左）与充值奖励（右）同一行；多条奖励时首行带折扣，其余行仅右侧奖励。
    @ViewBuilder
    private var homeDashboardBonusDiscountSection: some View {
        let rules = vm.programRechargeBonusRules
        let formattedDiscount = homeDashboardFormatDiscountSummaryForDisplay(from: vm.infraRoutingDiscountSummary)
        let showDiscount = homeDashboardShowsTierDiscountRow(summary: vm.infraRoutingDiscountSummary)
            && formattedDiscount != nil
        if showDiscount || !rules.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                if rules.isEmpty, showDiscount, let disc = formattedDiscount {
                    HStack(alignment: .center, spacing: 8) {
                        homeDashboardDiscountLeadingInline(displaySummary: disc)
                        Spacer(minLength: 0)
                    }
                } else {
                    ForEach(Array(rules.enumerated()), id: \.offset) { idx, r in
                        HStack(alignment: .center, spacing: 8) {
                            if idx == 0, showDiscount, let disc = formattedDiscount {
                                homeDashboardDiscountLeadingInline(displaySummary: disc)
                            }
                            Spacer(minLength: 8)
                            homeDashboardSingleBonusLine(rule: r)
                        }
                    }
                }
            }
            .padding(.top, 10)
        }
    }

    private func homeDashboardDiscountLeadingInline(displaySummary: String) -> some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(brandBlue.opacity(0.22))
                    .frame(width: 24, height: 24)
                Image(systemName: "square.3.layers.3d")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(brandBlue)
            }
            Text(displaySummary)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color(uiColor: .label).opacity(0.88))
                .lineLimit(1)
                .multilineTextAlignment(.leading)
        }
    }

    /// 折扣百分比仅保留整数（四舍五入），去掉 `0%`；若删光则返回 `nil`。
    private func homeDashboardFormatDiscountSummaryForDisplay(from summary: String?) -> String? {
        guard var s = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        let pattern = "(\\d+(?:\\.\\d+)?)\\s*%"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        let ns = s as NSString
        var matches = re.matches(in: s, range: NSRange(location: 0, length: ns.length))
        matches.sort { $0.range.location > $1.range.location }
        for m in matches {
            guard m.numberOfRanges > 1,
                  let fullR = Range(m.range(at: 0), in: s),
                  let numR = Range(m.range(at: 1), in: s),
                  let v = Double(s[numR]) else { continue }
            let intPct = Int(v.rounded())
            if intPct <= 0 {
                s.removeSubrange(fullR)
            } else {
                s.replaceSubrange(fullR, with: "\(intPct)%")
            }
        }
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimChars: Set<Character> = ["+", "/", ",", "·", "•"]
        while let f = t.first, trimChars.contains(f) {
            t = String(t.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        while let l = t.last, trimChars.contains(l) {
            t = String(t.dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    private func homeDashboardSingleBonusLine(rule r: BeamioRechargeBonusRule) -> some View {
        HStack(spacing: 8) {
            if r.bonusProportional {
                Text("Start $\(formatHomeBonusAmount(r.paymentAmount))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .label).opacity(0.82))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                Text("Get \(homeRechargeBonusTierPercentLabel(r))%")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(brandBlue.opacity(0.98))
            } else {
                Text("Pay $\(formatHomeBonusAmount(r.paymentAmount))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .label).opacity(0.82))
                Image(systemName: "arrow.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                Text("Get $\(formatHomeBonusAmount(r.paymentAmount + r.bonusValue))")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(brandBlue.opacity(0.98))
            }
        }
    }

    private func formatHomeBonusAmount(_ v: Double) -> String {
        let r = (v * 100).rounded() / 100
        if abs(r - r.rounded()) < 0.001 {
            return String(format: "%.0f", r)
        }
        return String(format: "%.2f", r)
    }

    /// Reference bonus rate for proportional tier: `bonusValue / paymentAmount` as percent (e.g. 15 → 15%).
    private func homeRechargeBonusTierPercentLabel(_ rule: BeamioRechargeBonusRule) -> String {
        guard rule.paymentAmount > 1e-9 else { return "0" }
        let p = (rule.bonusValue / rule.paymentAmount) * 100.0
        let r = (p * 100).rounded() / 100
        if abs(r - r.rounded()) < 0.01 {
            return String(format: "%.0f", r)
        }
        return String(format: "%.2f", r)
    }

    /// 至少有一处 `…%` 四舍五入为大于 0 的整数时才显示 tier 折扣行（隐藏 `—`、`0%`、四舍五入后为 0 的小数等）。
    private func homeDashboardShowsTierDiscountRow(summary: String?) -> Bool {
        guard let raw = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return false }
        if raw == "—" || raw == "–" || raw == "-" { return false }
        let pattern = "(\\d+(?:\\.\\d+)?)\\s*%"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return false }
        let ns = raw as NSString
        let matches = re.matches(in: raw, range: NSRange(location: 0, length: ns.length))
        if matches.isEmpty { return false }
        var maxIntPct = 0
        for m in matches {
            guard m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: raw) else { continue }
            let v = Double(raw[r]) ?? 0
            maxIntPct = max(maxIntPct, Int(v.rounded()))
        }
        return maxIntPct > 0
    }

    private var homeWelcomeNoAA: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Welcome to Beamio Web3 POS!")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(.white)
                .padding(.bottom, 6)
            Text("Your EOA Vault is ready. You can currently send/receive direct USDC payments. Your Smart Terminal (AA) is locked. To unlock zero-gas routing, VIP memberships, and voucher economies, purchase a Fuel Pack or join an Alliance.")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.9))
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(brandBlue))
    }

    private func homeActionRow(
        title: String,
        subtitle: String,
        systemImage: String,
        iconBackground: Color,
        iconTint: Color,
        iconCorner: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(alignment: .center, spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 20))
                    .foregroundStyle(iconTint)
                    .frame(width: 40, height: 40)
                    .background(iconBackground)
                    .clipShape(RoundedRectangle(cornerRadius: iconCorner))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                }
                Spacer(minLength: 8)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .systemBackground)))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
        }
        .buttonStyle(BeamioHapticPlainButtonStyle())
    }

    private func homeActionGridButton(
        title: String,
        systemImage: String,
        iconTint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(spacing: 12) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(iconTint)
                    .frame(width: 48, height: 48)
                    .background(iconTint.opacity(0.12))
                    .clipShape(Circle())
                Text(title)
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color(uiColor: .label))
                    .multilineTextAlignment(.center)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white)
                    .overlay(
                        RoundedRectangle(cornerRadius: 24, style: .continuous)
                            .stroke(Color(uiColor: .separator).opacity(0.42), lineWidth: 1)
                    )
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            )
        }
        .buttonStyle(BeamioHapticPlainButtonStyle())
    }

    /// Android header wallet display: `take(6) + "…" + takeLast(4)` when length ≥ 10.
    private func homeHeaderWalletShortLine(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 10 else { return t }
        return "\(t.prefix(6))…\(t.suffix(4))"
    }

    private func sanitizeProfilePart(_ raw: String?) -> String {
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty || t.lowercased() == "null" { return "" }
        return t
    }
}

// MARK: - Sales Overview (History → full-screen; design parity with bizSite mockup)

/// Live aggregates from `vm.posLedger` when present; otherwise design-mock figures (bizSite parity).
private struct POSSalesOverviewScreen: View {
    @ObservedObject var vm: POSViewModel
    let onClose: () -> Void

    private let brandBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)
    private let surfaceBg = Color(red: 0xf5 / 255, green: 0xf6 / 255, blue: 0xf8 / 255)

    private var snapshot: PosLedgerSnapshot? { vm.posLedger }

    private var grossSales: Double {
        guard let s = snapshot else { return 352.48 }
        return s.chargeBaseDisplayTotalForSalesOverviewInTerminalStatsPeriod()
    }

    private var refunds: Double { snapshot == nil ? 20.99 : 0 }
    private var refundCount: Int { snapshot == nil ? 1 : 0 }
    private var netSales: Double { max(0, grossSales - refunds) }

    private var usdcSubtotal: Double {
        snapshot?.chargeUsdcSettlementTotalInTerminalStatsPeriod() ?? 120.00
    }

    private let taxesAndFees = 0.00

    private var tips: Double {
        snapshot?.tipsDisplayTotalInTerminalStatsPeriod() ?? 47.24
    }

    private var amountCollected: Double {
        guard snapshot != nil else { return 378.73 }
        return netSales + tips
    }

    private var transactionCount: Int {
        snapshot?.chargeTransactionCountInTerminalStatsPeriod() ?? 24
    }

    private var averageTicket: Double {
        transactionCount > 0 ? amountCollected / Double(transactionCount) : 0
    }

    private func fmtMoney(_ n: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: NSNumber(value: n)) ?? String(format: "%.2f", n)
    }

    private var periodLine: String {
        if let s = snapshot {
            return s.overviewSelectedPeriodLine()
        }
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? now
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM. d, yyyy"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "h:mm a"
        let d0 = df.string(from: start)
        let d1 = df.string(from: end)
        let t0 = tf.string(from: start).lowercased()
        let t1 = tf.string(from: end).lowercased()
        return "\(d0), \(t0) — \(d1), \(t1)"
    }

    private var profileImageURL: URL? {
        let raw = vm.adminProfile?.image ?? vm.terminalProfile?.image
        guard let s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return URL(string: s)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    periodBlock
                    mainCard
                    bottomRow
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .background(surfaceBg.ignoresSafeArea())
    }

    private var headerBar: some View {
        HStack(spacing: 12) {
            Button {
                BeamioHaptic.light()
                onClose()
            } label: {
                ZStack {
                    Circle().fill(Color(red: 0xe8 / 255, green: 0xee / 255, blue: 0xfc / 255))
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(brandBlue)
                }
                .frame(width: 40, height: 40)
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())
            .accessibilityLabel("Back")

            Text("Sales Overview")
                .font(.system(size: 18, weight: .heavy))
                .foregroundStyle(brandBlue)
                .frame(maxWidth: .infinity)

            HStack(spacing: 8) {
                Button {
                    BeamioHaptic.light()
                } label: {
                    Image(systemName: "calendar")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(BeamioHapticPlainButtonStyle())
                .accessibilityLabel("Select period")

                profileAvatar
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(Color(uiColor: .systemBackground).opacity(0.97))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var profileAvatar: some View {
        Group {
            if let url = profileImageURL {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().scaledToFill()
                    case .failure, .empty:
                        profilePlaceholder
                    @unknown default:
                        profilePlaceholder
                    }
                }
                .frame(width: 40, height: 40)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 2))
            } else {
                profilePlaceholder
            }
        }
    }

    private var profilePlaceholder: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [brandBlue, Color(red: 0x7c / 255, green: 0x3a / 255, blue: 0xed / 255)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: 40, height: 40)
            .overlay {
                Text(String((vm.adminProfile?.accountName ?? vm.terminalProfile?.accountName ?? "?").prefix(1)).uppercased())
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
            }
    }

    private var periodBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("SELECTED PERIOD")
                .font(.system(size: 10, weight: .heavy))
                .tracking(1.2)
                .foregroundStyle(Color(uiColor: .secondaryLabel))
            Text(periodLine)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundStyle(Color(uiColor: .label))
                .lineLimit(3)
                .minimumScaleFactor(0.85)
        }
    }

    private var mainCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Gross Sales")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color(uiColor: .label))
                Spacer()
                Text("$\(fmtMoney(grossSales))")
                    .font(.system(size: 18, weight: .bold))
                    .monospacedDigit()
            }
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text("Refunds")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(refundCount)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color(uiColor: .tertiarySystemFill)))
                }
                Spacer()
                Text("($\(fmtMoney(refunds)))")
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.red)
                    .monospacedDigit()
            }
            .padding(.top, 14)

            Divider().padding(.vertical, 16)

            HStack(alignment: .firstTextBaseline) {
                Text("Net Sales")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Text("$\(fmtMoney(netSales))")
                    .font(.system(size: 22, weight: .heavy))
                    .foregroundStyle(brandBlue)
                    .monospacedDigit()
            }

            Divider().padding(.vertical, 16)

            VStack(spacing: 10) {
                rowLine("USDC Subtotal", usdcSubtotal)
                rowLine("Taxes & Fees", taxesAndFees)
                rowLine("Tips", tips)
            }
            .font(.system(size: 14, weight: .medium))
            .foregroundStyle(Color(uiColor: .secondaryLabel))

            Button {
                BeamioHaptic.light()
            } label: {
                HStack {
                    Text("AMOUNT COLLECTED: $\(fmtMoney(amountCollected))")
                        .font(.system(size: 11, weight: .heavy))
                        .tracking(0.6)
                    Spacer(minLength: 8)
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(Capsule().fill(brandBlue))
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())
            .padding(.top, 20)
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0xee / 255, green: 0xf3 / 255, blue: 0xfb / 255),
                            Color(red: 0xe4 / 255, green: 0xea / 255, blue: 0xf5 / 255)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color.black.opacity(0.08), radius: 16, y: 6)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(brandBlue.opacity(0.12), lineWidth: 1)
        )
    }

    private func rowLine(_ title: String, _ value: Double) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text("$\(fmtMoney(value))")
                .fontWeight(.semibold)
                .foregroundStyle(Color(uiColor: .label))
                .monospacedDigit()
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                Text("TRANSACTIONS")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.1)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                HStack(spacing: 6) {
                    Text("\(transactionCount)")
                        .font(.system(size: 26, weight: .heavy))
                        .monospacedDigit()
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(brandBlue)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            )

            VStack(alignment: .leading, spacing: 8) {
                Text("AVERAGE TICKET")
                    .font(.system(size: 9, weight: .heavy))
                    .tracking(1.1)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                Text("$\(fmtMoney(averageTicket))")
                    .font(.system(size: 26, weight: .heavy))
                    .monospacedDigit()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color(uiColor: .systemBackground))
                    .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
            )
        }
    }
}

/// History → Top-Up Overview (settlement window; parity with Android / Merchant OS mock).
private struct POSTopUpOverviewScreen: View {
    @ObservedObject var vm: POSViewModel
    let onClose: () -> Void

    private let brandBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)
    private let surfaceBg = Color(red: 0xf5 / 255, green: 0xf6 / 255, blue: 0xf8 / 255)

    private var snapshot: PosLedgerSnapshot? { vm.posLedger }

    private var breakdown: PosTopUpOverviewBreakdown {
        guard let s = snapshot else {
            return PosTopUpOverviewBreakdown(cashTotal: 150, cardTotal: 200, usdcTotal: 100, cashCount: 8, cardCount: 12, usdcCount: 4)
        }
        return s.topUpOverviewBreakdownInTerminalStatsPeriod()
    }

    private var totalTopUps: Double { breakdown.totalAmount }

    private var periodLine: String {
        if let s = snapshot {
            return s.overviewSelectedPeriodLine()
        }
        let cal = Calendar.current
        let now = Date()
        let start = cal.startOfDay(for: now)
        let end = cal.date(byAdding: DateComponents(day: 1, second: -1), to: start) ?? now
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "MMM. d, yyyy"
        let tf = DateFormatter()
        tf.locale = Locale(identifier: "en_US_POSIX")
        tf.dateFormat = "h:mm a"
        let d0 = df.string(from: start)
        let d1 = df.string(from: end)
        let t0 = tf.string(from: start).lowercased()
        let t1 = tf.string(from: end).lowercased()
        return "\(d0), \(t0) — \(d1), \(t1)"
    }

    private func fmtMoney(_ n: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.minimumFractionDigits = 2
        f.maximumFractionDigits = 2
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.string(from: NSNumber(value: n)) ?? String(format: "%.2f", n)
    }

    var body: some View {
        VStack(spacing: 0) {
            headerSection
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    heroCard
                    Text("Payment Breakdown")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Color(uiColor: .label))
                        .padding(.top, 4)

                    topUpBreakdownRow(
                        icon: "banknote.fill",
                        title: "Cash Top-Ups",
                        subtitle: "Retail locations",
                        amount: breakdown.cashTotal,
                        txnCount: breakdown.cashCount
                    )
                    topUpBreakdownRow(
                        icon: "creditcard.fill",
                        title: "Card Top-Ups",
                        subtitle: "Debit & Credit",
                        amount: breakdown.cardTotal,
                        txnCount: breakdown.cardCount
                    )
                    topUpBreakdownRow(
                        icon: "arrow.left.arrow.right.circle.fill",
                        title: "USDC Top-Ups",
                        subtitle: "Web3 Wallet",
                        amount: breakdown.usdcTotal,
                        txnCount: breakdown.usdcCount
                    )
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 28)
            }
        }
        .background(surfaceBg.ignoresSafeArea())
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Button {
                    BeamioHaptic.light()
                    onClose()
                } label: {
                    ZStack {
                        Circle().fill(Color(red: 0xe8 / 255, green: 0xee / 255, blue: 0xfc / 255))
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(brandBlue)
                    }
                    .frame(width: 40, height: 40)
                }
                .buttonStyle(BeamioHapticPlainButtonStyle())
                .accessibilityLabel("Back")

                Text("Top-Up Overview")
                    .font(.system(size: 18, weight: .heavy))
                    .foregroundStyle(Color(red: 0x0f / 255, green: 0x27 / 255, blue: 0x47 / 255))
                    .frame(maxWidth: .infinity)

                Button {
                    BeamioHaptic.light()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color(uiColor: .secondaryLabel))
                        .frame(width: 40, height: 40)
                        .background(Circle().fill(Color(uiColor: .tertiarySystemFill)))
                }
                .buttonStyle(BeamioHapticPlainButtonStyle())
                .accessibilityLabel("More options")
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
            .padding(.bottom, 6)

            VStack(alignment: .leading, spacing: 6) {
                Text("SELECTED PERIOD")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(1.2)
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
                Text(periodLine)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(uiColor: .label))
                    .lineLimit(3)
                    .minimumScaleFactor(0.85)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 12)
        }
        .background(Color(uiColor: .systemBackground).opacity(0.97))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    private var heroCard: some View {
        ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0x5b / 255, green: 0x94 / 255, blue: 0xfa / 255),
                            brandBlue,
                            Color(red: 0x0e / 255, green: 0x4b / 255, blue: 0xbf / 255),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .shadow(color: Color.black.opacity(0.14), radius: 14, y: 6)

            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("TOTAL TOP-UPS")
                        .font(.system(size: 10, weight: .heavy))
                        .tracking(1.4)
                        .foregroundStyle(Color.white.opacity(0.92))
                    Spacer()
                }
                .padding(.top, 18)
                .padding(.horizontal, 20)

                Spacer(minLength: 8)

                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("$")
                        .font(.system(size: 28, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.95))
                    Text(fmtMoney(totalTopUps))
                        .font(.system(size: 38, weight: .heavy))
                        .foregroundStyle(Color.white)
                        .monospacedDigit()
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    Image(systemName: "doc.text.fill")
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.95))
                    Text("\(breakdown.totalCount) Transactions processed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.92))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 18)
            }

            HStack(spacing: 5) {
                Circle()
                    .fill(Color(red: 0x5a / 255, green: 0xe5 / 255, blue: 0x8d / 255))
                    .frame(width: 6, height: 6)
                Text("LIVE")
                    .font(.system(size: 10, weight: .heavy))
                    .tracking(0.8)
                    .foregroundStyle(Color.white.opacity(0.95))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.black.opacity(0.38)))
            .padding(.top, 14)
            .padding(.trailing, 14)
        }
        .frame(height: 200)
    }

    private func topUpBreakdownRow(icon: String, title: String, subtitle: String, amount: Double, txnCount: Int) -> some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle().fill(Color(red: 0xe8 / 255, green: 0xee / 255, blue: 0xfc / 255))
                Image(systemName: icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(brandBlue)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(brandBlue)
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(Color(uiColor: .secondaryLabel))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 4) {
                Text("$\(fmtMoney(amount))")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(brandBlue)
                    .monospacedDigit()
                Text("\(txnCount) TXNS")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(brandBlue)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(uiColor: .systemBackground))
                .shadow(color: .black.opacity(0.06), radius: 8, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color(red: 0xe8 / 255, green: 0xec / 255, blue: 0xf0 / 255), lineWidth: 1)
        )
    }
}

/// /home → Transactions slide-in. **No filter buttons** (per product spec). Items list is sourced from
/// `POSViewModel.posLedger` — already bounded by chain `*FromClear` totals so the on-screen sum equals
/// the post-clear amount on the program card. Reverse-chronological (newest at top).
private struct POSTransactionsScreen: View {
    @ObservedObject var vm: POSViewModel
    let onClose: () -> Void

    @State private var showSalesOverview = false
    @State private var showTopUpOverview = false

    private let brandBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)
    private let mintGreen = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)

    private var snapshot: PosLedgerSnapshot? { vm.posLedger }
    private var items: [POSLedgerDisplayItem] {
        POSLedgerDisplayItem.merged(from: snapshot?.itemsInTerminalStatsPeriod() ?? [])
    }

    /// Discriminator drives the in-page content cross-fade so empty ↔ list transitions match the
    /// parent page's `.move(edge: .trailing)` slide. **No `loading` branch** — first-open flicker
    /// (empty → loading spinner → empty) was visually distracting; in-flight network state is
    /// instead surfaced via the small ProgressView in `header`, while the empty panel renders
    /// immediately as the page slides in.
    private enum BodyState: Equatable { case empty, list }
    private var bodyState: BodyState { items.isEmpty ? .empty : .list }

    var body: some View {
        ZStack {
            Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ZStack {
                    switch bodyState {
                    case .empty:
                        emptyState
                            .geometryGroup()
                            .transition(.move(edge: .trailing))
                    case .list:
                        listBody
                            .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
                .animation(.easeInOut(duration: 0.32), value: bodyState)
            }
        }
        .ignoresSafeArea(.keyboard)
        .refreshable { await vm.refreshPosLedgerTrustedOnly() }
        .fullScreenCover(isPresented: $showSalesOverview) {
            POSSalesOverviewScreen(vm: vm, onClose: { showSalesOverview = false })
        }
        .fullScreenCover(isPresented: $showTopUpOverview) {
            POSTopUpOverviewScreen(vm: vm, onClose: { showTopUpOverview = false })
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Button {
                BeamioHaptic.light()
                onClose()
            } label: {
                ZStack {
                    Circle().fill(Color(uiColor: .systemBackground))
                    Image(systemName: "chevron.left")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                }
                .frame(width: 36, height: 36)
                .overlay(Circle().stroke(Color.black.opacity(0.06), lineWidth: 0.5))
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())

            VStack(alignment: .leading, spacing: 2) {
                Text("Transactions")
                    .font(.system(size: 18, weight: .semibold))
                Text("Top-Ups & charges since last clear")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                Button {
                    BeamioHaptic.light()
                    showTopUpOverview = false
                    showSalesOverview = true
                } label: {
                    ZStack {
                        Circle().fill(brandBlue.opacity(0.12))
                        Image(systemName: "chart.bar.xaxis")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(brandBlue)
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(BeamioHapticPlainButtonStyle())
                .accessibilityLabel("Sales overview")

                Button {
                    BeamioHaptic.light()
                    showSalesOverview = false
                    showTopUpOverview = true
                } label: {
                    ZStack {
                        Circle().fill(brandBlue.opacity(0.12))
                        Image(systemName: "banknote.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(brandBlue)
                    }
                    .frame(width: 36, height: 36)
                }
                .buttonStyle(BeamioHapticPlainButtonStyle())
                .accessibilityLabel("Top-up overview")
            }
            if vm.posLedgerRefreshing || vm.posLedgerLoading {
                ProgressView().controlSize(.small)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }

    /// Centred placeholder shown whenever the items list is empty (first open, post-clear, or
    /// after a refresh that returns no rows). Centring is owned by the parent ZStack —
    /// keeping no inner `.frame(maxHeight: .infinity)` avoids the parent/child frame fight that
    /// produced jitter during the slide-in transition.
    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "list.bullet.rectangle")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("No transactions since last clear")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.secondary)
            if let err = vm.posLedgerLastError {
                Text(err)
                    .font(.system(size: 11))
                    .foregroundStyle(Color.orange)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
        }
        .padding(.horizontal, 32)
    }

    private var listBody: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(items) { item in
                    POSTransactionRowView(item: item, brandBlue: brandBlue, mintGreen: mintGreen)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 24)
        }
    }

}

private struct POSTransactionTipAmount: Equatable {
    let value: Double
    let currencyCode: String
}

/// Display-only transaction row: matched TX_TIP rows are nested under their parent Charge,
/// following the Merchant OS mobile Transactions treatment.
private struct POSLedgerDisplayItem: Identifiable, Equatable {
    let tx: PosLedgerItem
    let tips: [PosLedgerItem]
    let embeddedTip: POSTransactionTipAmount?

    var id: String { tx.id }

    static func merged(from rawItems: [PosLedgerItem]) -> [POSLedgerDisplayItem] {
        let visibleItems = rawItems.filter { !isHiddenInternalLedgerCategory($0.txCategory) }
        let tips = visibleItems.filter { $0.type == .tip }
        var absorbedTipIds = Set<String>()
        var out: [POSLedgerDisplayItem] = []

        for tx in visibleItems where tx.type != .tip {
            let matchedTips: [PosLedgerItem]
            if tx.type == .charge {
                matchedTips = tips.filter { tipRowMatchesChargeParent(tip: $0, charge: tx) }
                for tip in matchedTips { absorbedTipIds.insert(tip.id.lowercased()) }
            } else {
                matchedTips = []
            }
            out.append(POSLedgerDisplayItem(
                tx: tx,
                tips: matchedTips,
                embeddedTip: tx.type == .charge && matchedTips.isEmpty ? parseEmbeddedTip(from: tx) : nil
            ))
        }

        // Keep unmatched tip rows visible rather than dropping ledger facts; matched tips never render standalone.
        for tip in tips where !absorbedTipIds.contains(tip.id.lowercased()) {
            out.append(POSLedgerDisplayItem(tx: tip, tips: [], embeddedTip: nil))
        }

        out.sort {
            if $0.tx.timestamp != $1.tx.timestamp { return $0.tx.timestamp > $1.tx.timestamp }
            return $0.tx.id > $1.tx.id
        }
        return out
    }

    private static func isHiddenInternalLedgerCategory(_ raw: String) -> Bool {
        let c = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return hiddenInternalLedgerCategories.contains(c)
    }

    private static let hiddenInternalLedgerCategories: Set<String> = [
        // keccak256("nfcTopup:bunitService") / keccak256("usdcTopup:bunitService").
        // Older `/api/posLedger` deployments may emit these as `type: "charge"`; they are internal
        // protocol fuel legs, not user-facing Transactions items.
        "0x02d119b2041653c3b6f7aef339e2560da8ba867b022a04aaa150d062e5212bb7",
        "0x7067fa2b19fb81129d35576ad5fe635356a1405044d1c080a5ab341df6445776",
    ]

    private static func tipRowMatchesChargeParent(tip: PosLedgerItem, charge: PosLedgerItem) -> Bool {
        let tipKeys = tipParentLinkKeys(tip)
        guard !tipKeys.isEmpty else { return false }
        let chargeKeys = chargeParentKeys(charge)
        return tipKeys.contains { chargeKeys.contains($0) }
    }

    private static func chargeParentKeys(_ tx: PosLedgerItem) -> Set<String> {
        var out = Set<String>()
        addNormalized(tx.id, to: &out)
        addNormalized(tx.originalPaymentHash, to: &out)
        for h in displayJsonHashes(tx.displayJson, keys: ["finishedHash", "baseRelayTxHash", "requestHash", "originalPaymentHash"]) {
            addNormalized(h, to: &out)
        }
        return out
    }

    private static func tipParentLinkKeys(_ tx: PosLedgerItem) -> Set<String> {
        var out = Set<String>()
        addNormalized(tx.originalPaymentHash, to: &out)
        for h in displayJsonHashes(tx.displayJson, keys: ["finishedHash", "originalPaymentHash", "baseRelayTxHash"]) {
            addNormalized(h, to: &out)
        }
        return out
    }

    private static func addNormalized(_ raw: String?, to out: inout Set<String>) {
        guard let n = normalizeBytes32HexLower(raw) else { return }
        out.insert(n)
    }

    private static func normalizeBytes32HexLower(_ raw: String?) -> String? {
        guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        if !s.hasPrefix("0x"), s.range(of: #"^[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil {
            s = "0x" + s
        }
        guard s.range(of: #"^0x[0-9a-fA-F]{64}$"#, options: .regularExpression) != nil else { return nil }
        let lower = s.lowercased()
        return lower == "0x" + String(repeating: "0", count: 64) ? nil : lower
    }

    private static func displayJsonHashes(_ displayJson: String, keys: [String]) -> [String] {
        guard
            let data = displayJson.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return keys.compactMap { obj[$0] as? String }
    }

    private static func parseEmbeddedTip(from tx: PosLedgerItem) -> POSTransactionTipAmount? {
        guard
            let data = tx.displayJson.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let breakdown = obj["chargeBreakdown"] as? [String: Any]
        else { return nil }
        let rawTip = String(describing: breakdown["tipCurrencyAmount"] ?? "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let tip = Double(rawTip), tip > 0 else { return nil }
        let currency = (breakdown["requestCurrency"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        return POSTransactionTipAmount(value: tip, currencyCode: currency?.isEmpty == false ? currency! : "CAD")
    }
}

/// One row in the POS Transactions list. Mirrors the biz Transactions table compact summary
/// (type icon + amount + tag-line) without any filtering UI affordances.
private struct POSTransactionRowView: View {
    let item: POSLedgerDisplayItem
    let brandBlue: Color
    let mintGreen: Color

    private var tx: PosLedgerItem { item.tx }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10)
                    .fill(tint.opacity(0.12))
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(tint)
            }
            .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 2) {
                Text(typeTitle)
                    .font(.system(size: 14, weight: .semibold))
                Text(secondaryLine)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(amountLine)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(amountTint)
                if let tipLine {
                    Text(tipLine)
                        .font(.system(size: 10))
                        .italic()
                        .foregroundStyle(.secondary)
                }
                Text(timeLine)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(uiColor: .systemBackground)))
    }

    private var tipPink: Color { Color(red: 0xF4 / 255, green: 0x3F / 255, blue: 0x5E / 255) }
    private var tint: Color {
        switch tx.type {
        case .topUp: return mintGreen
        case .tip: return tipPink
        case .charge: return brandBlue
        }
    }
    private var icon: String {
        switch tx.type {
        case .topUp: return "arrow.up"
        case .tip: return "heart.fill"
        case .charge: return "arrow.down"
        }
    }
    private var typeTitle: String {
        switch tx.type {
        case .topUp: return "Top-Up"
        case .tip: return "Tip"
        case .charge: return "Charge"
        }
    }
    private var amountTint: Color { tx.type == .topUp ? mintGreen : Color.primary }

    /// Prefer the row's fiat/card-currency amount when present, fall back to USDC, and
    /// for Charge rows include any merged tip that is denominated in the same currency.
    /// `currencyFiat == 4` (USDC) renders with the trailing " USDC" suffix.
    private var amountLine: String {
        let base = preferredDisplayAmount(tx)
        let total = base.value + tipTotal(in: base.currencyCode)
        let parts = readBalanceFormatMoney(total, currency: base.currencyCode)
        let sign = tx.type == .topUp ? "+" : "−"
        return "\(sign)\(parts.prefix)\(parts.mid)\(parts.suffix)"
    }

    private var tipLine: String? {
        guard tx.type == .charge else { return nil }
        let base = preferredDisplayAmount(tx)
        let grouped = tipTotalsByCurrency()
        let preferred = grouped[base.currencyCode] ?? grouped.first?.value ?? 0
        let code = grouped[base.currencyCode] != nil ? base.currencyCode : (grouped.first?.key ?? base.currencyCode)
        guard preferred > 0.000_001 else { return nil }
        let parts = readBalanceFormatMoney(preferred, currency: code)
        return "incl. \(parts.prefix)\(parts.mid)\(parts.suffix) tip"
    }

    private func preferredDisplayAmount(_ tx: PosLedgerItem) -> POSTransactionTipAmount {
        let fiat6 = Double(tx.amountFiat6) ?? 0
        let usd6 = Double(tx.amountUSDC6) ?? 0
        if fiat6 > 0 {
            return POSTransactionTipAmount(
                value: fiat6 / 1_000_000,
                currencyCode: Self.beamioCurrencyCodeForCurrencyFiat(tx.currencyFiat)
            )
        }
        return POSTransactionTipAmount(value: usd6 / 1_000_000, currencyCode: "USDC")
    }

    private func tipTotalsByCurrency() -> [String: Double] {
        var totals: [String: Double] = [:]
        for tip in item.tips {
            let amt = preferredDisplayAmount(tip)
            totals[amt.currencyCode, default: 0] += amt.value
        }
        if let embedded = item.embeddedTip {
            totals[embedded.currencyCode, default: 0] += embedded.value
        }
        return totals
    }

    private func tipTotal(in currencyCode: String) -> Double {
        tipTotalsByCurrency()[currencyCode] ?? 0
    }

    /// Mirrors `BeamioAPIClient.beamioCurrencyTypeCode` (kept private there).
    /// 0=CAD, 1=USD, 2=JPY, 3=CNY, 4=USDC, 5=HKD, 6=EUR, 7=SGD, 8=TWD.
    private static func beamioCurrencyCodeForCurrencyFiat(_ id: Int) -> String {
        switch id {
        case 1: return "USD"
        case 2: return "JPY"
        case 3: return "CNY"
        case 4: return "USDC"
        case 5: return "HKD"
        case 6: return "EUR"
        case 7: return "SGD"
        case 8: return "TWD"
        default: return "CAD"
        }
    }

    private var secondaryLine: String {
        if tx.type == .tip {
            if let note = tx.note, !note.isEmpty { return note }
            let counterparty = tx.payer
            let trimmed = counterparty.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.lowercased() != "0x0000000000000000000000000000000000000000" else {
                return "Member"
            }
            let short = trimmed.count >= 10 ? "\(trimmed.prefix(6))…\(trimmed.suffix(4))" : trimmed
            return short
        }
        let method = (tx.paymentMethodLabel ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let tagRaw = (tx.payerBeamioTag ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let who: String
        if !tagRaw.isEmpty {
            who = "@\(tagRaw)"
        } else {
            let counterparty = tx.payer.trimmingCharacters(in: .whitespacesAndNewlines)
            if counterparty.isEmpty || counterparty.lowercased() == "0x0000000000000000000000000000000000000000" {
                who = tx.type == .topUp ? "Wallet" : "Customer"
            } else {
                who = counterparty.count >= 10 ? "\(counterparty.prefix(6))…\(counterparty.suffix(4))" : counterparty
            }
        }
        if method.isEmpty { return who }
        return "\(who) · \(method)"
    }

    private var timeLine: String {
        guard tx.timestamp > 0 else { return "—" }
        let date = Date(timeIntervalSince1970: TimeInterval(tx.timestamp))
        let nowSec = Date().timeIntervalSince1970
        let diff = nowSec - TimeInterval(tx.timestamp)
        if diff < 60 * 60 { return "\(Int(diff / 60))m ago" }
        if diff < 24 * 60 * 60 { return "\(Int(diff / 3600))h ago" }
        if diff < 48 * 60 * 60 { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d, HH:mm"
        return f.string(from: date)
    }
}

/// Android `BeamioCapsuleCompact`: avatar + displayName + @tag
private struct HomeBeamioSelfMiniCapsule: View {
    let title: String
    let tight: Bool

    var body: some View {
        let iconSize: CGFloat = tight ? 18 : 22
        HStack(spacing: tight ? 5 : 6) {
            Image("LaunchBrandLogo")
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: iconSize, height: iconSize)
                .clipShape(Circle())
            Text(title)
                .font(.system(size: tight ? 10 : 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.leading, tight ? 5 : 6)
        .padding(.trailing, tight ? 7 : 8)
        .padding(.vertical, tight ? 4 : 5)
        .background(Capsule().fill(Color.white.opacity(0.18)))
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
    }
}

private struct HomeBeamioProfileMiniCapsule: View {
    let profile: TerminalProfile
    let tight: Bool

    var body: some View {
        let iconSize: CGFloat = tight ? 18 : 22
        let label = capsuleLabel
        HStack(spacing: tight ? 5 : 6) {
            avatarView(image: profile.image, fallbackUrl: fallbackAvatarUrl)
                .frame(width: iconSize, height: iconSize)
                .clipShape(Circle())
            Text(label)
                .font(.system(size: tight ? 10 : 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.92))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.leading, tight ? 5 : 6)
        .padding(.trailing, tight ? 7 : 8)
        .padding(.vertical, tight ? 4 : 5)
        .background(Capsule().fill(Color.white.opacity(0.18)))
        .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
    }

    private var capsuleLabel: String {
        if let tag = sanitize(profile.accountName) { return "@\(tag)" }
        let name = displayNameLine(first: profile.firstName, last: profile.lastName)
        return name.isEmpty ? "Parent" : name
    }

    private var fallbackAvatarUrl: URL? {
        let seed = sanitize(profile.accountName) ?? "Beamio"
        let enc = seed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? seed
        return URL(string: "https://api.dicebear.com/8.x/fun-emoji/png?seed=\(enc)")
    }

    @ViewBuilder
    private func avatarView(image: String?, fallbackUrl: URL?) -> some View {
        let trimmed = image?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            BeamioCardRasterOrSvgImage(urlString: trimmed, rasterContentMode: .fill) {
                fallbackDice(fallbackUrl)
            }
        } else {
            fallbackDice(fallbackUrl)
        }
    }

    private func fallbackDice(_ url: URL?) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            case .failure: Color.white.opacity(0.22)
            case .empty: Color.white.opacity(0.16)
            @unknown default: Color.white.opacity(0.22)
            }
        }
    }

    private func sanitize(_ raw: String?) -> String? {
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty || t.lowercased() == "null" { return nil }
        return t.hasPrefix("@") ? String(t.dropFirst()) : t
    }

    private func displayNameLine(first: String?, last: String?) -> String {
        let f = sanitize(first) ?? ""
        let lastRaw = last?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\r\n").first.map(String.init) ?? ""
        let l0 = lastRaw.hasPrefix("{") ? "" : (sanitize(lastRaw) ?? "")
        return "\(f) \(l0)".trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct HomeBeamioCapsuleCompact: View {
    let profile: TerminalProfile
    let fallbackAddress: String?

    var body: some View {
        let tag = sanitizeName(profile.accountName)
        let beamioLine = tag.map { "@\($0)" }
        let disp = displayNameLine(first: profile.firstName, last: profile.lastName)
        let hasName = !disp.isEmpty
        let shortFallback = fallbackAddress.flatMap { a in
            let t = a.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.count >= 10 else { return t as String? }
            return "\(t.prefix(6))…\(t.suffix(4))"
        }
        let seed = tag ?? "Beamio"
        let enc = seed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? seed
        let avatarUrl = URL(string: "https://api.dicebear.com/8.x/fun-emoji/png?seed=\(enc)")

        HStack(alignment: .center, spacing: 8) {
            avatarView(image: profile.image, fallbackUrl: avatarUrl)
                .frame(width: 28, height: 28)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 0) {
                if hasName {
                    Text(disp)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
                if let b = beamioLine {
                    Text(b)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.primary.opacity(0.7))
                        .lineLimit(1)
                } else if !hasName, let fb = shortFallback {
                    Text(fb)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color.black.opacity(0.06))
        )
    }

    /// Primary avatar: same SVG / IPFS `getFragment` routing as Pass artwork (`BeamioCardRasterOrSvgImage`).
    @ViewBuilder
    private func avatarView(image: String?, fallbackUrl: URL?) -> some View {
        let trimmed = image?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            BeamioCardRasterOrSvgImage(urlString: trimmed, rasterContentMode: .fill) {
                fallbackDice(fallbackUrl)
            }
        } else {
            fallbackDice(fallbackUrl)
        }
    }

    private func fallbackDice(_ url: URL?) -> some View {
        AsyncImage(url: url) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            case .failure: Color.gray.opacity(0.3)
            case .empty: Color.gray.opacity(0.2)
            @unknown default: Color.gray.opacity(0.3)
            }
        }
    }

    private func sanitizeName(_ raw: String?) -> String? {
        let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty || t.lowercased() == "null" { return nil }
        return t
    }

    private func displayNameLine(first: String?, last: String?) -> String {
        let f = sanitizeName(first) ?? ""
        let lastRaw = last?.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\r\n").first.map(String.init) ?? ""
        let l0 = lastRaw.hasPrefix("{") ? "" : (sanitizeName(lastRaw) ?? "")
        let both = "\(f) \(l0)".trimmingCharacters(in: .whitespacesAndNewlines)
        return both
    }
}

// MARK: - Amount pad

/// Charge: full-screen slide-in from trailing (same host as `TopupAmountPadFullPage`); amount root → push tip. Avoids `.sheet` + nested sheet races (`tipSubtotal` as `"0"`).
/// Charge 支付方式只有两种：USDC 启用 ⇒ raw `"usdc"`；USDC 关闭 ⇒ raw `"nfcCard"`（默认 NFC 卡持卡人付款）。
/// 与 topup 端 `TopupPaymentMethodOption.usdc` 同源（`PosTerminalPolicy.allowPayerUsdcInCharge` ≡ `allowTopupUsdc`）。
private enum ChargePaymentMethodRaw {
    static let nfcCard = "nfcCard"
    static let usdc = "usdc"
}

private let posChargeAmountPageBackground = Color(red: 0xEE / 255, green: 0xF5 / 255, blue: 0xFF / 255)
private let posTopupAmountPageBackground = Color(red: 0xF7 / 255, green: 0xF0 / 255, blue: 0xFF / 255)

private struct ChargeAmountTipNavigationSheet: View {
    var chargePolicy: PosTerminalPolicy
    var onCancel: () -> Void
    /// (subtotal, tipBps, methodRaw)
    var onChargeComplete: (String, Int, String) -> Void

    @State private var path = NavigationPath()
    /// `ChargeAmountPadRoot` 选定的方法（NavigationPath 仅传字符串 subtotal，把 method 暂存这里以保持泛型简单）。
    @State private var pendingMethodRaw: String = ChargePaymentMethodRaw.nfcCard

    var body: some View {
        NavigationStack(path: $path) {
            ChargeAmountPadRoot(
                chargePolicy: chargePolicy,
                onCancel: onCancel,
                onContinue: { subtotal, methodRaw in
                    pendingMethodRaw = methodRaw
                    path.append(subtotal)
                }
            )
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: String.self) { subtotal in
                TipFlowPage(subtotal: subtotal) { tipBps in
                    onChargeComplete(subtotal, tipBps, pendingMethodRaw)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(posChargeAmountPageBackground.ignoresSafeArea())
        .compositingGroup()
        .onAppear { path = NavigationPath() }
    }
}

/// Charge amount entry: same chrome as `TopupAmountPadFullPage` (surface, circular back, expandable keypad).
/// 当 `chargePolicy.allowPayerUsdcInCharge == true` 时，金额面板右侧出现「USDC enable/disable」二态切换：
/// - enable → 蓝色（`usdcAccent`）+ 实心 `dollarsign.circle.fill`，methodRaw = `"usdc"`；
/// - disable → 浅灰（`usdcDisabledGray`）+ 描边图标，methodRaw = `"nfcCard"`（默认）。
/// 终端无 USDC 许可时按钮整体不显示。
private struct ChargeAmountPadRoot: View {
    var chargePolicy: PosTerminalPolicy
    var onCancel: () -> Void
    /// (amount, methodRaw) — methodRaw ∈ {"usdc","nfcCard"}
    var onContinue: (String, String) -> Void

    /// `false` ⇒ NFC 卡付款（默认）；`true` ⇒ USDC 外部钱包付款。policy 关闭时强制回 false。
    @AppStorage("pos.charge.usdcEnabled")
    private var persistedUsdcEnabled: Bool = false
    @State private var amount = "0"

    private let primaryBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)
    private let usdcAccent = Color(red: 0x27 / 255, green: 0x75 / 255, blue: 0xCA / 255)
    private let usdcDisabledGray = Color(red: 0xB0 / 255, green: 0xB4 / 255, blue: 0xBC / 255)

    private var usdcAllowed: Bool { chargePolicy.allowPayerUsdcInCharge }
    private var usdcEnabled: Bool { usdcAllowed && persistedUsdcEnabled }

    private var selectedMethodRaw: String {
        usdcEnabled ? ChargePaymentMethodRaw.usdc : ChargePaymentMethodRaw.nfcCard
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geo in
                let compact = geo.size.height < 640
                let sidePad: CGFloat = compact ? 16 : 20
                let amtDollar: CGFloat = compact ? 28 : 34
                let amtMain: CGFloat = compact ? 52 : 64
                let methodIconSize: CGFloat = compact ? 36 : 42

                VStack(spacing: 0) {
                    chargeAmountWell(
                        compact: compact,
                        amtDollar: amtDollar,
                        amtMain: amtMain,
                        methodIconSize: methodIconSize
                    )
                        .padding(.horizontal, sidePad)
                        .padding(.top, geo.safeAreaInsets.top + 8)
                    BeamioNumericAmountPadKeypad(amount: $amount, compact: compact)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, sidePad)
                        .padding(.top, compact ? 10 : 12)
                    continueButton(compact: compact)
                        .padding(.horizontal, sidePad)
                        .padding(.top, compact ? 10 : 12)
                        .padding(.bottom, compact ? 12 : 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            SheetCircularBackButton(action: onCancel)
                .padding(.leading, 8)
                .safeAreaPadding(.top, 6)
        }
        .background(posChargeAmountPageBackground.ignoresSafeArea())
        .compositingGroup()
    }

    private func chargeAmountWell(compact: Bool, amtDollar: CGFloat, amtMain: CGFloat, methodIconSize: CGFloat) -> some View {
        let amountAccent = usdcEnabled ? usdcAccent : primaryBlue
        let toggleColor = usdcEnabled ? usdcAccent : usdcDisabledGray
        let toggleIcon = usdcEnabled ? "dollarsign.circle.fill" : "dollarsign.circle"
        return HStack(alignment: .center, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("$")
                    .font(.system(size: amtDollar, weight: .bold, design: .rounded))
                    .foregroundStyle(amountAccent)
                Text(beamioAmountPadFormattedDisplay(amount))
                    .font(.system(size: amtMain, weight: .heavy, design: .rounded))
                    .foregroundStyle(amountAccent)
                    .lineLimit(1)
                    .minimumScaleFactor(0.35)
            }
            .frame(maxWidth: .infinity, alignment: usdcAllowed ? .leading : .trailing)
            if usdcAllowed {
                Button {
                    BeamioHaptic.light()
                    persistedUsdcEnabled.toggle()
                } label: {
                    VStack(spacing: compact ? 6 : 8) {
                        Text("USDC")
                            .font(.system(size: compact ? 11 : 12, weight: .semibold))
                            .foregroundStyle(toggleColor)
                            .lineLimit(1)
                        ZStack {
                            Circle()
                                .fill(toggleColor.opacity(usdcEnabled ? 0.16 : 0.12))
                                .frame(width: methodIconSize, height: methodIconSize)
                            Image(systemName: toggleIcon)
                                .font(.system(size: methodIconSize * 0.5, weight: .semibold))
                                .foregroundStyle(toggleColor)
                        }
                    }
                    .frame(minWidth: compact ? 64 : 72)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(usdcEnabled ? "USDC payment enabled. Tap to disable." : "USDC payment disabled. Tap to enable."))
            }
        }
        .padding(.vertical, compact ? 18 : 22)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(readBalanceDetailsSurfaceContainerLow)
        )
    }

    private var canContinue: Bool {
        guard let v = Double(amount) else { return false }
        return v > 0
    }

    private func continueButton(compact: Bool) -> some View {
        Button {
            onContinue(amount, selectedMethodRaw)
        } label: {
            Text("Continue")
                .font(.system(size: compact ? 17 : 18, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 17 : 19)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(primaryBlue))
        }
        .buttonStyle(BeamioHapticPlainButtonStyle())
        .disabled(!canContinue)
        .opacity(canContinue ? 1 : 0.45)
    }
}

// MARK: - Tip (pushed inside `ChargeAmountTipNavigationSheet`)

private struct TipFlowPage: View {
    var subtotal: String
    var onConfirm: (Int) -> Void

    @State private var selected: Double = 0

    /// Same as Read Balance `Top-Up Card Now` / AmountPad top-up primary.
    private let primaryBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)

    private var num: Double { Double(subtotal) ?? 0 }

    var body: some View {
        GeometryReader { geo in
            let compact = geo.size.height < 640
            VStack(spacing: 20) {
                Text("Subtotal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("$\(String(format: "%.2f", num))")
                    .font(.system(size: 44, weight: .light, design: .rounded))
                tipGrid
                Button {
                    let bps = Int((selected * 10_000).rounded())
                    onConfirm(bps)
                } label: {
                    HStack(spacing: 8) {
                        Text("Confirm & Pay")
                            .font(.system(size: compact ? 17 : 18, weight: .semibold))
                        Image(systemName: "chevron.right")
                            .font(.system(size: compact ? 17 : 18, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, compact ? 17 : 19)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(primaryBlue))
                }
                .buttonStyle(BeamioHapticPlainButtonStyle())
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var tipGrid: some View {
        VStack(spacing: 16) {
            HStack(spacing: 16) {
                tipCell(rate: 0.15, label: "15%")
                tipCell(rate: 0.18, label: "18%")
            }
            HStack(spacing: 16) {
                tipCell(rate: 0.20, label: "20%")
                tipCell(rate: 0, label: "No Tip")
            }
        }
    }

    private func tipCell(rate: Double, label: String) -> some View {
        let on = selected == rate
        return Button {
            selected = rate
        } label: {
            VStack(spacing: 8) {
                Text(label)
                    .font(.title3.bold())
                if rate == 0 {
                    Text("+$0.00").font(.subheadline).foregroundStyle(.secondary)
                } else {
                    Text("+$\(String(format: "%.2f", num * rate))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .background(
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(on ? primaryBlue : Color.black.opacity(0.08), lineWidth: on ? 2 : 1)
                    .background(RoundedRectangle(cornerRadius: 24).fill(on ? primaryBlue.opacity(0.08) : Color.white))
            )
        }
        .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
    }
}

// MARK: - Read Balance / Balance Details (align Android `ReadScreen` + `StandardMemberPassHeroCard`)

private let readBalanceDetailsSurface = Color(red: 0xF9 / 255, green: 0xF9 / 255, blue: 0xFE / 255)
private let readBalanceDetailsOutline = Color(red: 0x73 / 255, green: 0x76 / 255, blue: 0x85 / 255)
private let readBalanceDetailsOnSurface = Color(red: 0x1A / 255, green: 0x1C / 255, blue: 0x1F / 255)
private let readBalanceDetailsSurfaceContainerLow = Color(red: 0xF3 / 255, green: 0xF3 / 255, blue: 0xF8 / 255)
private let readBalanceDetailsSurfaceContainerLowest = Color.white

// MARK: - Shared amount pad (Top-up / Charge)

private func formatIntegerPartWithCommas(_ intPart: String) -> String {
    let digits = intPart.filter(\.isNumber)
    if digits.isEmpty { return "0" }
    let stripped = String(digits.drop(while: { $0 == "0" }))
    let core = stripped.isEmpty ? "0" : stripped
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US_POSIX")
    f.maximumFractionDigits = 0
    f.minimumFractionDigits = 0
    f.usesGroupingSeparator = true
    f.groupingSeparator = ","
    let n = NSDecimalNumber(string: core)
    guard n != NSDecimalNumber.notANumber else { return core }
    return f.string(from: n) ?? core
}

private func beamioAmountPadFormattedDisplay(_ amount: String) -> String {
    let s = amount.trimmingCharacters(in: .whitespacesAndNewlines)
    if s.isEmpty || s == "0" { return "0.00" }

    let intRaw: String
    let frac: String?
    if let r = s.range(of: ".") {
        intRaw = String(s[s.startIndex..<r.lowerBound])
        frac = String(s[r.upperBound...])
    } else {
        intRaw = s
        frac = nil
    }

    let intGrouped = formatIntegerPartWithCommas(intRaw.isEmpty ? "0" : intRaw)

    if let frac {
        return frac.isEmpty ? "\(intGrouped)." : "\(intGrouped).\(frac)"
    }
    if let d = Double(s), d == floor(d) {
        return "\(intGrouped).00"
    }
    return s
}

/// NFC/QR scan bottom overlay: 2 decimals + US grouping (align Android `formatUsdAmountWithGrouping`).
private func formatUsdAmountScanOverlay(_ amount: Double) -> String {
    let f = NumberFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.numberStyle = .decimal
    f.minimumFractionDigits = 2
    f.maximumFractionDigits = 2
    f.usesGroupingSeparator = true
    f.groupingSeparator = ","
    return f.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
}

private struct BeamioNumericAmountPadKeypad: View {
    @Binding var amount: String
    var compact: Bool

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [".", "0", "⌫"]]

    var body: some View {
        GeometryReader { g in
            let colGap: CGFloat = compact ? 7 : 9
            let rowGap: CGFloat = compact ? 7 : 9
            let w = max(0, g.size.width)
            let h = max(0, g.size.height)
            let rowCount = CGFloat(rows.count)
            let cellH = rowCount > 0 ? max(1, (h - (rowCount - 1) * rowGap) / rowCount) : 1
            let approxKeyW = max(0, (w - 2 * colGap) / 3)
            let fontSize = max(16, min(approxKeyW, cellH) * (compact ? 0.4 : 0.42))

            VStack(spacing: rowGap) {
                ForEach(rows, id: \.self) { row in
                    HStack(spacing: colGap) {
                        ForEach(row, id: \.self) { key in
                            Button {
                                BeamioHaptic.medium()
                                tap(key)
                            } label: {
                                Group {
                                    if key == "⌫" {
                                        Image(systemName: "delete.left")
                                            .font(.system(size: fontSize, weight: .medium))
                                    } else {
                                        Text(key)
                                            .font(.system(size: fontSize, weight: .medium, design: .rounded))
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(readBalanceDetailsSurfaceContainerLowest)
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                                )
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(readBalanceDetailsOnSurface)
                            .frame(maxWidth: .infinity)
                            .frame(height: cellH)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(width: w, height: h, alignment: .top)
        }
    }

    private func tap(_ key: String) {
        if key == "⌫" {
            if amount.count > 1 { amount.removeLast() } else { amount = "0" }
            return
        }
        if key == "." {
            if amount.contains(".") { return }
            amount += amount == "0" ? "0." : "."
            return
        }
        if amount == "0" { amount = key } else {
            if let d = amount.split(separator: ".", omittingEmptySubsequences: false).last, d.contains(".") == false, amount.contains("."), d.count >= 2 { return }
            amount += key
        }
    }
}

// MARK: - Top-up full page (align Check Balance details: surface + circular back, no scroll)

private enum TopupPaymentMethodOption: String, CaseIterable, Identifiable {
    case creditCard
    case usdc
    case cash
    case bonus

    var id: String { rawValue }

    /// Cycle order for method chip (must match Android `TOPUP_METHOD_CYCLE_ORDER`).
    static let cycleOrder: [TopupPaymentMethodOption] = [.creditCard, .usdc, .cash, .bonus]

    var title: String {
        switch self {
        case .creditCard: return "Card"
        case .usdc: return "USDC"
        case .cash: return "Cash"
        case .bonus: return "Bonus"
        }
    }

    var systemImage: String {
        switch self {
        case .creditCard: return "creditcard.fill"
        case .usdc: return "dollarsign.circle.fill"
        case .cash: return "banknote.fill"
        case .bonus: return "sparkles"
        }
    }

    var accentColor: Color {
        switch self {
        case .creditCard:
            return Color(red: 0xD4 / 255, green: 0x9B / 255, blue: 0x1F / 255)
        case .usdc:
            return Color(red: 0x27 / 255, green: 0x75 / 255, blue: 0xCA / 255)
        case .cash:
            return Color(red: 0x6B / 255, green: 0x72 / 255, blue: 0x80 / 255)
        case .bonus:
            return Color(red: 0xEC / 255, green: 0x48 / 255, blue: 0x99 / 255)
        }
    }

    func allowed(by policy: PosTerminalPolicy) -> Bool {
        switch self {
        case .creditCard: return policy.allowTopupBankCard
        case .usdc: return policy.allowTopupUsdc
        case .cash: return policy.allowTopupCash
        case .bonus: return policy.allowTopupAirdrop
        }
    }
}

/// Full-screen Add Funds: same chrome as `ReadBalanceView` (top-leading back, `readBalanceDetailsSurface`), no `ScrollView`.
private struct TopupAmountPadFullPage: View {
    var topupPolicy: PosTerminalPolicy
    var onCancel: () -> Void
    /// Method, Activate Bonus expanded, selected bonus %, keypad principal string (same as pad `amount` at confirm).
    var onContinue: (TopupPaymentMethodOption, Bool, Int, String) -> Void

    @AppStorage("pos.topup.lastPaymentMethod")
    private var persistedSelectedMethodRaw: String = TopupPaymentMethodOption.creditCard.rawValue
    @State private var amount = "0"
    @State private var bonusExpanded = false
    @State private var selectedBonusRate: Int = 20

    /// Same primary as Read Balance “Top-Up Card Now”.
    private let topUpPurple = Color(red: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255)
    private let bonusPink = Color(red: 0xEC / 255, green: 0x48 / 255, blue: 0x99 / 255)

    private var allowedMethods: [TopupPaymentMethodOption] {
        TopupPaymentMethodOption.cycleOrder.filter { $0.allowed(by: topupPolicy) }
    }

    private var selectedMethod: TopupPaymentMethodOption {
        TopupPaymentMethodOption(rawValue: persistedSelectedMethodRaw) ?? .creditCard
    }

    private func setSelectedMethod(_ method: TopupPaymentMethodOption) {
        persistedSelectedMethodRaw = method.rawValue
        if method == .bonus {
            bonusExpanded = false
        }
    }

    private var bonusWorkflowEnabled: Bool {
        selectedMethod != .bonus && topupPolicy.allowTopupAirdrop
    }

    private var nextSelectedMethod: TopupPaymentMethodOption {
        let pool: [TopupPaymentMethodOption] =
            bonusExpanded ? allowedMethods.filter { $0 != .bonus } : allowedMethods
        guard !pool.isEmpty else { return selectedMethod }
        let idx = pool.firstIndex(of: selectedMethod) ?? 0
        return pool[(idx + 1) % pool.count]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            GeometryReader { geo in
                let compact = geo.size.height < 640
                let sidePad: CGFloat = compact ? 16 : 20
                let gap: CGFloat = compact ? 8 : 10
                let bonusOuterGap: CGFloat = gap
                let methodIconSize: CGFloat = compact ? 36 : 42
                let amtDollar: CGFloat = compact ? 28 : 34
                let amtMain: CGFloat = compact ? 52 : 64

                VStack(spacing: 0) {
                    amountWell(
                        compact: compact,
                        amtDollar: amtDollar,
                        amtMain: amtMain,
                        methodIconSize: methodIconSize
                    )
                    .padding(.horizontal, sidePad)
                    .padding(.top, geo.safeAreaInsets.top + 8)
                    if allowedMethods.isEmpty {
                        Text("No top-up methods are enabled for this terminal. Ask the merchant to update device settings.")
                            .font(.system(size: compact ? 13 : 14, weight: .medium))
                            .foregroundStyle(readBalanceDetailsOutline)
                            .multilineTextAlignment(.leading)
                            .padding(.horizontal, sidePad + 4)
                            .padding(.top, 6)
                    }
                    if bonusWorkflowEnabled {
                        bonusSection(compact: compact)
                            .padding(.horizontal, sidePad)
                            .padding(.top, bonusOuterGap)
                    }
                    BeamioNumericAmountPadKeypad(amount: $amount, compact: compact)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .padding(.horizontal, sidePad)
                        .padding(.top, bonusOuterGap)
                    confirmButton(compact: compact)
                        .padding(.horizontal, sidePad)
                        .padding(.top, compact ? 10 : 12)
                        .padding(.bottom, compact ? 12 : 16)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            SheetCircularBackButton(action: onCancel)
                .padding(.leading, 8)
                .safeAreaPadding(.top, 6)
        }
        .background(posTopupAmountPageBackground.ignoresSafeArea())
        /// Eager compositing so the whole screen (incl. payment tiles) participates in the trailing push transition; `LazyVGrid` can leave cells on the old layer during `move`.
        .compositingGroup()
        .onChange(of: topupPolicy) { _, _ in
            if !allowedMethods.isEmpty, !selectedMethod.allowed(by: topupPolicy) {
                setSelectedMethod(allowedMethods[0])
                bonusExpanded = false
            }
        }
    }

    private var parsedAmountValue: Double {
        Double(amount) ?? 0
    }

    private var selectedBonusFraction: Double {
        Double(selectedBonusRate) / 100.0
    }

    private var totalBonusValue: Double {
        parsedAmountValue * selectedBonusFraction
    }

    private var totalWithBonusValue: Double {
        parsedAmountValue + totalBonusValue
    }

    private var amountDisplayAccentColor: Color {
        selectedMethod == .bonus ? bonusPink : topUpPurple
    }

    private func bonusSection(compact: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if !bonusExpanded {
                collapsedBonusPanel(compact: compact)
                    .transition(bonusPanelSlideTransition)
                    .zIndex(0)
            }
            if bonusExpanded {
                expandedBonusPanels(compact: compact)
                    .transition(bonusPanelSlideTransition)
                    .zIndex(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .clipped()
        .animation(.easeInOut(duration: 0.28), value: bonusExpanded)
    }

    private var bonusPanelSlideTransition: AnyTransition {
        .asymmetric(
            insertion: .move(edge: .trailing).combined(with: .opacity),
            removal: .move(edge: .leading).combined(with: .opacity)
        )
    }

    private func expandedBonusPanels(compact: Bool) -> some View {
        VStack(spacing: compact ? 8 : 10) {
            bonusRatePickerPanel(compact: compact)
            bonusBreakdownPanel(compact: compact)
        }
    }

    private func toggleBonusExpanded(_ expanded: Bool) {
        withAnimation(.easeInOut(duration: 0.28)) {
            bonusExpanded = expanded
        }
    }

    private func collapsedBonusPanel(compact: Bool) -> some View {
        Button {
            BeamioHaptic.light()
            toggleBonusExpanded(true)
        } label: {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Activate Bonus")
                        .font(.system(size: compact ? 15 : 16, weight: .semibold))
                        .foregroundStyle(readBalanceDetailsOnSurface)
                    Text("Get extra credits on your deposit")
                        .font(.system(size: compact ? 12 : 13, weight: .medium))
                        .foregroundStyle(readBalanceDetailsOutline)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(readBalanceDetailsOutline.opacity(0.28))
                        .frame(width: compact ? 48 : 54, height: compact ? 28 : 32)
                    Circle()
                        .fill(Color.white)
                        .frame(width: compact ? 22 : 26, height: compact ? 22 : 26)
                        .padding(.leading, 3)
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, compact ? 14 : 16)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(readBalanceDetailsSurfaceContainerLowest)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(Color.black.opacity(0.04), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Activate bonus")
    }

    private func bonusRatePickerPanel(compact: Bool) -> some View {
        let buttonHeight: CGFloat = compact ? 34 : 36
        return HStack(spacing: compact ? 6 : 8) {
            ForEach([10, 20, 30], id: \.self) { rate in
                let selected = selectedBonusRate == rate
                Button {
                    BeamioHaptic.light()
                    selectedBonusRate = rate
                } label: {
                    Text("\(rate)%")
                        .font(.system(size: compact ? 14 : 15, weight: .semibold))
                        .foregroundStyle(selected ? Color.white : readBalanceDetailsOnSurface)
                        .frame(maxWidth: .infinity)
                        .frame(height: buttonHeight)
                        .background(
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(selected ? bonusPink : readBalanceDetailsSurfaceContainerLow)
                        )
                }
                .buttonStyle(.plain)
            }

            Button {
                BeamioHaptic.light()
                toggleBonusExpanded(false)
            } label: {
                ZStack(alignment: .trailing) {
                    Capsule(style: .continuous)
                        .fill(topUpPurple)
                        .frame(width: compact ? 38 : 42, height: compact ? 22 : 24)
                    Circle()
                        .fill(Color.white)
                        .frame(width: compact ? 16 : 18, height: compact ? 16 : 18)
                        .padding(.trailing, 3)
                }
                .frame(maxWidth: .infinity, minHeight: buttonHeight, maxHeight: buttonHeight)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Turn off bonus")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 0)
    }

    private func bonusBreakdownPanel(compact: Bool) -> some View {
        VStack(spacing: compact ? 6 : 8) {
            bonusBreakdownRow(
                label: "Total Bonus",
                value: topupSummaryAmountString(totalBonusValue),
                highlight: true,
                compact: compact
            )
        }
        .padding(.horizontal, compact ? 14 : 16)
        .padding(.vertical, compact ? 8 : 10)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(readBalanceDetailsSurfaceContainerLowest)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.black.opacity(0.04), lineWidth: 1)
        )
    }

    private func bonusBreakdownRow(label: String, value: String, highlight: Bool, compact: Bool) -> some View {
        HStack(alignment: .lastTextBaseline) {
            Text(label)
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(readBalanceDetailsOnSurface.opacity(0.8))
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: compact ? 15 : 16, weight: .semibold, design: .monospaced))
                .foregroundStyle(highlight ? bonusPink : readBalanceDetailsOnSurface)
        }
    }

    private func topupSummaryAmountString(_ value: Double) -> String {
        "$\(formatUsdAmountScanOverlay(value))"
    }

    private func amountWell(compact: Bool, amtDollar: CGFloat, amtMain: CGFloat, methodIconSize: CGFloat) -> some View {
        let wellHeight: CGFloat = compact ? 132 : 146
        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: compact ? 8 : 10) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text("$")
                        .font(.system(size: amtDollar, weight: .bold, design: .rounded))
                        .foregroundStyle(amountDisplayAccentColor)
                    Text(beamioAmountPadFormattedDisplay(amount))
                        .font(.system(size: amtMain, weight: .heavy, design: .rounded))
                        .foregroundStyle(amountDisplayAccentColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.35)
                }
                if bonusExpanded {
                    HStack(alignment: .lastTextBaseline, spacing: 8) {
                        Text("New Balance")
                            .font(.system(size: compact ? 12 : 13, weight: .semibold))
                            .foregroundStyle(readBalanceDetailsOnSurface.opacity(0.82))
                        Text(topupSummaryAmountString(totalWithBonusValue))
                            .font(.system(size: compact ? 14 : 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(topUpPurple)
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                guard allowedMethods.count > 1 else { return }
                BeamioHaptic.light()
                setSelectedMethod(nextSelectedMethod)
            } label: {
                VStack(spacing: compact ? 6 : 8) {
                    Text(selectedMethod.title)
                        .font(.system(size: compact ? 11 : 12, weight: .semibold))
                        .foregroundStyle(selectedMethod.accentColor)
                        .lineLimit(1)
                    ZStack {
                        Circle()
                            .fill(selectedMethod.accentColor.opacity(0.14))
                            .frame(width: methodIconSize, height: methodIconSize)
                        Image(systemName: selectedMethod.systemImage)
                            .font(.system(size: methodIconSize * 0.46))
                            .foregroundStyle(selectedMethod.accentColor)
                    }
                }
                .frame(minWidth: compact ? 64 : 72)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Payment method \(selectedMethod.title). Tap to switch"))
        }
        .padding(.vertical, compact ? 18 : 22)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: wellHeight, maxHeight: wellHeight, alignment: .center)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(readBalanceDetailsSurfaceContainerLow)
        )
    }

    private var canContinue: Bool {
        guard !allowedMethods.isEmpty, let v = Double(amount) else { return false }
        return v > 0
    }

    private func confirmButton(compact: Bool) -> some View {
        Button {
            guard BeamioAPIClient.nfcTopupCurrencySplitFromPosKeypad(
                keypadAmount: amount,
                methodRaw: selectedMethod.rawValue,
                bonusExpanded: bonusExpanded,
                selectedBonusRate: selectedBonusRate
            ) != nil else { return }
            onContinue(selectedMethod, bonusExpanded, selectedBonusRate, amount)
        } label: {
            Text("Confirm Top-Up")
                .font(.system(size: compact ? 17 : 18, weight: .semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, compact ? 17 : 19)
                .foregroundStyle(.white)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(topUpPurple))
        }
        .buttonStyle(BeamioHapticPlainButtonStyle())
        .disabled(!canContinue)
        .opacity(canContinue ? 1 : 0.45)
    }
}

private func readBalanceColorRelativeLuminance(_ color: Color) -> Double {
    let ui = UIColor(color)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    func lin(_ x: CGFloat) -> Double {
        let xs = Double(x)
        return xs <= 0.03928 ? xs / 12.92 : pow((xs + 0.055) / 1.055, 2.4)
    }
    let lr = lin(r), lg = lin(g), lb = lin(b)
    return 0.2126 * lr + 0.7152 * lg + 0.0722 * lb
}

private func readBalanceWcagContrastRatio(_ luminanceA: Double, _ luminanceB: Double) -> Double {
    let light = max(luminanceA, luminanceB)
    let dark = min(luminanceA, luminanceB)
    return (light + 0.05) / (dark + 0.05)
}

private func readBalanceUseDarkForegroundPerWcag(backgroundLuminance: Double) -> Bool {
    let lb = backgroundLuminance.clamped(to: 0 ... 1)
    let contrastWithWhiteText = readBalanceWcagContrastRatio(1.0, lb)
    let contrastWithBlackText = readBalanceWcagContrastRatio(lb, 0.0)
    return contrastWithBlackText > contrastWithWhiteText
}

private func readBalanceGradientColorAlongDiagonal(_ gradientStart: Color, _ gradientEnd: Color, t: CGFloat) -> Color {
    let s = t.clamped(to: 0 ... 1)
    let us = UIColor(gradientStart)
    let ue = UIColor(gradientEnd)
    var sr: CGFloat = 0, sg: CGFloat = 0, sb: CGFloat = 0, sa: CGFloat = 0
    var er: CGFloat = 0, eg: CGFloat = 0, eb: CGFloat = 0, ea: CGFloat = 0
    us.getRed(&sr, green: &sg, blue: &sb, alpha: &sa)
    ue.getRed(&er, green: &eg, blue: &eb, alpha: &ea)
    return Color(
        red: Double(sr + (er - sr) * s),
        green: Double(sg + (eg - sg) * s),
        blue: Double(sb + (eb - sb) * s),
        opacity: Double(sa + (ea - sa) * s)
    )
}

private func readBalanceCardDiagonalGradientT(u: CGFloat, v: CGFloat, aspectWidthOverHeight: CGFloat = 1.6) -> CGFloat {
    let a2 = aspectWidthOverHeight * aspectWidthOverHeight
    let den = a2 + 1
    return (u.clamped(to: 0 ... 1) * a2 + v.clamped(to: 0 ... 1)) / den
}

private func readBalanceUseDarkForegroundWcagPreferRightSmallTextZone(
    gradientStart: Color,
    gradientEnd: Color,
    aspectWidthOverHeight: CGFloat = 1.6
) -> Bool {
    let samples: [(CGFloat, CGFloat)] = [
        (0.93, 0.07), (0.94, 0.14), (0.91, 0.23), (0.89, 0.32), (0.86, 0.41),
    ]
    var minCrWhite = Double.greatestFiniteMagnitude
    var minCrBlack = Double.greatestFiniteMagnitude
    for (u, v) in samples {
        let t = readBalanceCardDiagonalGradientT(u: u, v: v, aspectWidthOverHeight: aspectWidthOverHeight)
        let bg = readBalanceGradientColorAlongDiagonal(gradientStart, gradientEnd, t: t)
        let lb = readBalanceColorRelativeLuminance(bg)
        minCrWhite = min(minCrWhite, readBalanceWcagContrastRatio(1.0, lb))
        minCrBlack = min(minCrBlack, readBalanceWcagContrastRatio(lb, 0.0))
    }
    if !minCrWhite.isFinite || !minCrBlack.isFinite {
        return readBalanceUseDarkForegroundPerWcag(backgroundLuminance: readBalanceColorRelativeLuminance(gradientStart))
    }
    return minCrBlack > minCrWhite
}

private func readBalanceRgbToHsv(r: CGFloat, g: CGFloat, b: CGFloat) -> (h: CGFloat, s: CGFloat, v: CGFloat) {
    let maxc = max(r, g, b)
    let minc = min(r, g, b)
    let delta = maxc - minc
    if delta < 1e-5 { return (0, 0, maxc) }
    let hDeg: CGFloat = {
        if abs(maxc - r) < 1e-5 {
            var hh = 60 * ((g - b) / delta)
            if hh < 0 { hh += 360 }
            return hh
        }
        if abs(maxc - g) < 1e-5 { return 60 * ((b - r) / delta + 2) }
        return 60 * ((r - g) / delta + 4)
    }()
    let h = ((hDeg / 360).truncatingRemainder(dividingBy: 1) + 1).truncatingRemainder(dividingBy: 1)
    let s = delta / maxc
    return (h, s, maxc)
}

private func readBalanceHsvToColor(h: CGFloat, s: CGFloat, v: CGFloat) -> Color {
    let hh = ((h * 6).truncatingRemainder(dividingBy: 6) + 6).truncatingRemainder(dividingBy: 6)
    let i = Int(floor(Double(hh))).clamped(to: 0 ... 5)
    let f = hh - CGFloat(i)
    let p = v * (1 - s)
    let q = v * (1 - f * s)
    let t = v * (1 - (1 - f) * s)
    let (rp, gp, bp): (CGFloat, CGFloat, CGFloat) = switch i {
    case 0: (v, t, p)
    case 1: (q, v, p)
    case 2: (p, v, t)
    case 3: (p, q, v)
    case 4: (t, p, v)
    default: (v, p, q)
    }
    return Color(red: Double(rp.clamped(to: 0 ... 1)), green: Double(gp.clamped(to: 0 ... 1)), blue: Double(bp.clamped(to: 0 ... 1)))
}

private func readBalanceSameFamilyGradientEnd(start: Color) -> Color {
    let lum = readBalanceColorRelativeLuminance(start)
    let deepBackground = !readBalanceUseDarkForegroundPerWcag(backgroundLuminance: lum)
    let ui = UIColor(start)
    var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    ui.getRed(&r, green: &g, blue: &b, alpha: &a)
    let (ho, s0, v0) = readBalanceRgbToHsv(r: r, g: g, b: b)
    if deepBackground {
        let v1 = (v0 + 0.38).clamped(to: 0.52 ... 0.97)
        let s1 = (s0 * 0.9).clamped(to: 0.1 ... 1)
        return readBalanceHsvToColor(h: ho, s: s1, v: v1)
    } else {
        let v1 = (v0 - 0.32).clamped(to: 0.1 ... 0.5)
        let s1 = (s0 * 1.06).clamped(to: 0.12 ... 1)
        return readBalanceHsvToColor(h: ho, s: s1, v: v1)
    }
}

private struct ReadBalancePassHeroPalette {
    var gradientStart: Color
    var gradientEnd: Color
    var primaryText: Color
    var secondaryText: Color
    var tertiaryText: Color
    var decorativeCircle: Color
    var avatarBorder: Color
    var avatarBackdrop: Color
    var walletIconTint: Color
}

private func readBalancePassHeroPalette(tierCardBackgroundHex: String?) -> ReadBalancePassHeroPalette {
    let start = readBalanceParseHexColor(tierCardBackgroundHex) ?? Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xF0 / 255)
    let end = readBalanceSameFamilyGradientEnd(start: start)
    let darkForeground = readBalanceUseDarkForegroundWcagPreferRightSmallTextZone(gradientStart: start, gradientEnd: end)
    let primaryOnLight = Color(red: 0x0F / 255, green: 0x17 / 255, blue: 0x2A / 255)
    let primary = darkForeground ? primaryOnLight : .white
    let secondary = darkForeground ? primaryOnLight.opacity(0.88) : Color.white.opacity(0.88)
    let tertiary = darkForeground ? primaryOnLight.opacity(0.78) : Color.white.opacity(0.78)
    let deco = darkForeground ? Color.black.opacity(0.06) : Color.white.opacity(0.05)
    let avBorder = darkForeground ? Color.black.opacity(0.16) : Color.white.opacity(0.22)
    let avBack = darkForeground ? Color.black.opacity(0.07) : Color.white.opacity(0.08)
    let wallet = darkForeground ? Color.black.opacity(0.38) : Color.white.opacity(0.2)
    return ReadBalancePassHeroPalette(
        gradientStart: start,
        gradientEnd: end,
        primaryText: primary,
        secondaryText: secondary,
        tertiaryText: tertiary,
        decorativeCircle: deco,
        avatarBorder: avBorder,
        avatarBackdrop: avBack,
        walletIconTint: wallet
    )
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

private struct ReadBalanceStandardPassHeroCard: View {
    let memberDisplayName: String
    let memberNo: String
    let tierDisplayName: String?
    let tierDiscountPercent: Double?
    let programCardDisplayName: String
    let tierCardBackgroundHex: String?
    let cardMetadataImageUrl: String?
    let balancePrefix: String
    let balanceAmount: String
    let balanceSuffix: String

    var body: some View {
        let tone = readBalancePassHeroPalette(tierCardBackgroundHex: tierCardBackgroundHex)
        let shape: RoundedRectangle = RoundedRectangle(cornerRadius: 24, style: .continuous)
        return ZStack(alignment: .bottomTrailing) {
            shape.fill(
                LinearGradient(
                    colors: [tone.gradientStart, tone.gradientEnd],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            Circle()
                .fill(tone.decorativeCircle)
                .frame(width: 180, height: 180)
                .offset(x: 120, y: -72)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(memberDisplayName)
                        .font(.system(size: 22, weight: .heavy))
                        .foregroundStyle(tone.primaryText)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(memberNo.isEmpty ? "—" : memberNo)
                            .font(.system(size: 14, weight: .bold, design: .monospaced))
                            .foregroundStyle(tone.primaryText)
                            .lineLimit(1)
                        if let raw = tierDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                            Text(raw)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(tone.secondaryText)
                                .multilineTextAlignment(.trailing)
                                .lineLimit(2)
                        }
                        if let d = tierDiscountPercent, d > 0 {
                            Text("\(beamioTierDiscountPercentLabel(d))% discount")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(tone.tertiaryText)
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                    }
                }
                Spacer(minLength: 8)
                VStack(alignment: .leading, spacing: 8) {
                    Text(programCardDisplayName)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(tone.secondaryText)
                        .lineLimit(2)
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        if !balancePrefix.isEmpty {
                            Text(balancePrefix.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(tone.primaryText)
                        }
                        Text(balanceAmount)
                            .font(.system(size: 32, weight: .bold, design: .monospaced))
                            .foregroundStyle(tone.primaryText)
                            .tracking(-0.6)
                        if !balanceSuffix.isEmpty {
                            Text(balanceSuffix)
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(tone.primaryText)
                        }
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            ZStack {
                Circle()
                    .strokeBorder(tone.avatarBorder, lineWidth: 1)
                    .background(Circle().fill(tone.avatarBackdrop))
                if let u = cardMetadataImageUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !u.isEmpty {
                    BeamioCardRasterOrSvgImage(urlString: u, rasterContentMode: .fill) {
                        Image(systemName: "creditcard.fill").foregroundStyle(tone.walletIconTint)
                    }
                    .clipShape(Circle())
                } else {
                    Image(systemName: "creditcard.fill")
                        .font(.system(size: 22))
                        .foregroundStyle(tone.walletIconTint)
                        .padding(10)
                }
            }
            .frame(width: 48, height: 48)
            .padding(.trailing, 22)
            .padding(.bottom, 12)
        }
        .aspectRatio(1.6, contentMode: .fit)
        .clipShape(shape)
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.2), radius: 12, x: 0, y: 6)
    }
}

private func readBalanceLastTopUpFallbackLine(assets: UIDAssets?) -> String {
    guard let a = assets else { return "—" }
    let iso = a.posLastTopupAt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !iso.isEmpty {
        let t = iso.replacingOccurrences(of: "T", with: " ")
        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
        let take = min(16, trimmed.count)
        return String(trimmed.prefix(take)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    return "—"
}

private func readBalanceFormatUsdcThousands(_ amount: Double) -> String {
    let fmt = NumberFormatter()
    fmt.numberStyle = .decimal
    fmt.minimumFractionDigits = 2
    fmt.maximumFractionDigits = 2
    fmt.locale = Locale(identifier: "en_US")
    return fmt.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
}

private struct ReadBalanceLastTopUpUsdcStatsCard: View {
    let assets: UIDAssets?
    let cardCurrency: String
    let usdcBalance: Double

    var body: some View {
        let parts = readBalanceFormatMoney(usdcBalance, currency: "USDC")
        let p6Trim = assets?.posLastTopupPointsE6?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let p6 = Int64(p6Trim) ?? 0
        return VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LAST TOP-UP")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(readBalanceDetailsOutline)
                        .tracking(1)
                    if p6 > 0 {
                        let v = Double(p6) / 1_000_000.0
                        let row = readBalanceFormatMoney(v, currency: cardCurrency)
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            if !row.prefix.isEmpty {
                                Text(row.prefix)
                                    .font(.system(size: 12, weight: .bold))
                                    .foregroundStyle(readBalanceDetailsOnSurface)
                            }
                            Text(row.mid)
                                .font(.system(size: 20, weight: .bold, design: .monospaced))
                                .foregroundStyle(readBalanceDetailsOnSurface)
                            if !row.suffix.isEmpty {
                                Text(row.suffix.trimmingCharacters(in: .whitespacesAndNewlines))
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(readBalanceDetailsOutline)
                            }
                        }
                    } else {
                        Text(readBalanceLastTopUpFallbackLine(assets: assets))
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(readBalanceDetailsOnSurface)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .trailing, spacing: 4) {
                    Text("USDC on Base")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(readBalanceDetailsOutline)
                        .tracking(1)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(readBalanceFormatUsdcThousands(usdcBalance))
                            .font(.system(size: 20, weight: .bold, design: .monospaced))
                            .foregroundStyle(readBalanceDetailsOnSurface)
                        Text(parts.suffix.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(readBalanceDetailsOutline)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 24, style: .continuous).fill(readBalanceDetailsSurfaceContainerLow))
    }
}

// MARK: - Sheet host (scan + balance)

private struct SheetHost: View {
    @ObservedObject var vm: POSViewModel
    let sheet: POSViewModel.Sheet
    @Binding var amountFlow: AmountFlow?

    var body: some View {
        NavigationStack {
            Group {
                switch sheet {
                case .readResult:
                    ReadBalanceView(
                        assets: vm.lastReadAssets,
                        rawResponseJson: vm.lastReadRawJson,
                        error: vm.lastReadError,
                        merchantInfraCard: vm.merchantInfraCard,
                        amountFlow: $amountFlow,
                        onDismissSheet: { vm.closeScanSheet() }
                    )
                case .scan(let action):
                    ScanSheet(vm: vm, action: action)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
    }
}

private func readBalanceBalanceDetailsCardNameLine(card: CardItem) -> String {
    let raw = card.cardName.trimmingCharacters(in: .whitespacesAndNewlines)
    if raw.isEmpty { return "—" }
    let n = raw.replacingOccurrences(of: " CARD", with: "").replacingOccurrences(of: " Card", with: "")
    let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
    return t.isEmpty ? "—" : t
}

private func readBalancePassHeroMemberDisplayName(
    beamioTag: String?,
    walletAddress: String?,
    passCard: CardItem?,
    cardNameFallback: String?
) -> String {
    if var tag = beamioTag?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty {
        if tag.hasPrefix("@") { tag = String(tag.dropFirst()) }
        if !tag.isEmpty { return tag }
    }
    let a = walletAddress?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !a.isEmpty, a.hasPrefix("0x"), a.count >= 10 {
        if a.count > 10 { return "\(a.prefix(6))…\(a.suffix(4))" }
        return a
    }
    let rawName: String? = passCard?.cardName ?? cardNameFallback
    if let nm = rawName?.trimmingCharacters(in: .whitespacesAndNewlines), !nm.isEmpty {
        let n = nm.replacingOccurrences(of: " CARD", with: "").replacingOccurrences(of: " Card", with: "")
        let t = n.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty,
           t.caseInsensitiveCompare("Infrastructure card") != .orderedSame,
           t.caseInsensitiveCompare("Asset Card") != .orderedSame {
            return t
        }
    }
    return "Member"
}

private func readBalanceMemberNoDisplayString(primaryPass: CardItem?, assets: UIDAssets?) -> String {
    if let c = primaryPass {
        let m = readBalanceMemberNo(from: c)
        if !m.isEmpty { return m }
    }
    let p = assets?.primaryMemberTokenId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !p.isEmpty, (Int64(p) ?? 0) > 0 {
        return "M-\(p.readBalancePadStart(6))"
    }
    return ""
}

private func readBalanceHeroBalanceAmount(primaryPass: CardItem?, assets: UIDAssets?) -> Double {
    if let card = primaryPass {
        let p6Trim = card.points6.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p6 = Int64(p6Trim), p6 > 0 { return Double(p6) / 1_000_000.0 }
        let pTrim = card.points.trimmingCharacters(in: .whitespacesAndNewlines)
        if let p = Double(pTrim), p != 0 { return p }
    }
    let a6Trim = assets?.points6?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let a6 = Int64(a6Trim), a6 > 0 { return Double(a6) / 1_000_000.0 }
    let apTrim = assets?.points?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if let ap = Double(apTrim), ap != 0 { return ap }
    return 0
}

private func readBalanceHeroCardBackgroundHex(assets: UIDAssets?, primaryPass: CardItem?, merchantInfraCard: String) -> String? {
    if let h = primaryPass?.cardBackground?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { return h }
    let infra = merchantInfraCard.trimmingCharacters(in: .whitespacesAndNewlines)
    if !infra.isEmpty {
        for c in assets?.cards ?? [] {
            if c.cardAddress.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(infra) == .orderedSame {
                if let bg = c.cardBackground?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty { return bg }
                break
            }
        }
    }
    if let cards = assets?.cards, cards.count == 1 {
        return cards[0].cardBackground?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }
    return nil
}

private func readBalancePrettyJsonString(_ raw: String) -> String {
    guard let d = raw.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: d),
          let pretty = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]),
          let s = String(data: pretty, encoding: .utf8) else { return raw }
    return s
}

/// Align Android `ReadScreen` success / error layout (`MainActivity.kt` ReadScreen).
private struct ReadBalanceView: View {
    let assets: UIDAssets?
    let rawResponseJson: String?
    let error: String?
    /// Terminal-registered merchant / infrastructure card; Balance Details only lists this card’s pass row.
    let merchantInfraCard: String
    @Binding var amountFlow: AmountFlow?
    var onDismissSheet: () -> Void

    private let topUpBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)

    @State private var responseExpanded = false
    @State private var topupButtonEnabled = true

    private var balanceLoadIdentity: String {
        guard let a = assets else { return "" }
        let c = a.counter.map { String($0) } ?? ""
        return [a.uid ?? "", a.beamioTag ?? "", a.tagIdHex ?? "", c].joined(separator: "|")
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            VStack(spacing: 0) {
                GeometryReader { geo in
                let compact = geo.size.height < 560
                let sidePad: CGFloat = compact ? 16 : 20
                let gapSm: CGFloat = compact ? 8 : 10
                ZStack {
                    readBalanceDetailsSurface
                    if let err = error, !err.isEmpty {
                        VStack(spacing: 12) {
                            Spacer(minLength: 0)
                            Text("❌ \(err)")
                                .font(.subheadline)
                                .foregroundStyle(readBalanceDetailsOnSurface)
                                .multilineTextAlignment(.center)
                                .padding()
                            Button("Done") {
                                BeamioHaptic.medium()
                                onDismissSheet()
                            }
                            .buttonStyle(.borderedProminent)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let a = assets, a.ok {
                        let primaryPass = readBalancePosAdminCards(from: a, merchantInfraCard: merchantInfraCard)?.first
                        let memberDisplay = readBalancePassHeroMemberDisplayName(
                            beamioTag: a.beamioTag,
                            walletAddress: a.address,
                            passCard: primaryPass,
                            cardNameFallback: primaryPass?.cardName
                        )
                        let memberNoLine = readBalanceMemberNoDisplayString(primaryPass: primaryPass, assets: a)
                        let tierNameLine: String? = {
                            guard let t = primaryPass?.tierName?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
                            return t
                        }()
                        let disc = primaryPass.flatMap { readBalanceTierDiscountPercent(for: $0) }
                        let programLine = primaryPass.map { readBalanceBalanceDetailsCardNameLine(card: $0) } ?? "—"
                        let bgHex = readBalanceHeroCardBackgroundHex(assets: a, primaryPass: primaryPass, merchantInfraCard: merchantInfraCard)
                        let balNum = readBalanceHeroBalanceAmount(primaryPass: primaryPass, assets: a)
                        let balCurrency = primaryPass?.cardCurrency ?? a.cardCurrency ?? "CAD"
                        let balParts = readBalanceFormatMoney(balNum, currency: balCurrency)
                        let usdcBal = Double(a.usdcBalance ?? "0") ?? 0
                        VStack(spacing: 0) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: gapSm + 4) {
                                    ReadBalanceStandardPassHeroCard(
                                        memberDisplayName: memberDisplay,
                                        memberNo: memberNoLine,
                                        tierDisplayName: tierNameLine,
                                        tierDiscountPercent: disc,
                                        programCardDisplayName: programLine,
                                        tierCardBackgroundHex: bgHex,
                                        cardMetadataImageUrl: primaryPass?.cardImage,
                                        balancePrefix: balParts.prefix,
                                        balanceAmount: balParts.mid,
                                        balanceSuffix: balParts.suffix
                                    )
                                    ReadBalanceLastTopUpUsdcStatsCard(
                                        assets: a,
                                        cardCurrency: balCurrency,
                                        usdcBalance: usdcBal
                                    )
                                    readBalanceResponseSection(compact: compact, gapSm: gapSm)
                                }
                                .padding(.horizontal, sidePad)
                                .padding(.top, 56)
                                .padding(.bottom, gapSm)
                            }
                            VStack(spacing: compact ? 8 : 10) {
                                Button {
                                    onDismissSheet()
                                    amountFlow = .topup
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "plus")
                                            .font(.system(size: 14, weight: .semibold))
                                        Text("Top-Up Card Now")
                                            .font(.system(size: compact ? 13 : 14, weight: .semibold))
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, compact ? 12 : 14)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(topUpBlue))
                                    .foregroundStyle(.white)
                                }
                                .buttonStyle(BeamioHapticPlainButtonStyle())
                                .disabled(!topupButtonEnabled)
                                .opacity(topupButtonEnabled ? 1 : 0.45)
                            }
                            .padding(.horizontal, sidePad)
                            .padding(.top, gapSm)
                            .padding(.bottom, compact ? 12 : 16)
                            .background(readBalanceDetailsSurface)
                        }
                    } else {
                        VStack {
                            Spacer(minLength: 0)
                            Text("No data")
                                .foregroundStyle(readBalanceDetailsOutline)
                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            }
            SheetCircularBackButton(action: onDismissSheet)
                .padding(.leading, 8)
                .safeAreaPadding(.top, 6)
        }
        .background(readBalanceDetailsSurface.ignoresSafeArea())
        .toolbar(.hidden, for: .navigationBar)
        .task(id: balanceLoadIdentity) {
            topupButtonEnabled = true
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if !Task.isCancelled { topupButtonEnabled = false }
        }
    }

    @ViewBuilder
    private func readBalanceResponseSection(compact: Bool, gapSm: CGFloat) -> some View {
        if let raw = rawResponseJson, !raw.isEmpty {
            Button {
                responseExpanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Response Data")
                            .font(.system(size: compact ? 13 : 15, weight: .semibold))
                            .foregroundStyle(readBalanceDetailsOutline)
                        Spacer()
                        Text(responseExpanded ? "▼" : "▶")
                            .font(.system(size: 11))
                            .foregroundStyle(readBalanceDetailsOutline)
                    }
                    .padding(compact ? 10 : 14)
                    if responseExpanded {
                        ScrollView {
                            Text(readBalancePrettyJsonString(raw))
                                .font(.system(size: 9, design: .monospaced))
                                .foregroundStyle(Color(red: 0x64 / 255, green: 0x74 / 255, blue: 0x8b / 255))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                        }
                        .frame(maxHeight: compact ? 160 : 240)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color(red: 0xf8 / 255, green: 0xfa / 255, blue: 0xfc / 255)))
                        .padding(.horizontal, compact ? 10 : 14)
                        .padding(.bottom, compact ? 10 : 14)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(readBalanceDetailsSurfaceContainerLowest))
                .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.black.opacity(0.05), lineWidth: 1))
            }
            .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
            .padding(.top, gapSm)
        }
    }
}

private func readBalanceCardList(from assets: UIDAssets?) -> [CardItem]? {
    guard let assets else { return nil }
    if let c = assets.cards, !c.isEmpty { return c }
    guard let addr = assets.cardAddress?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
    return [
        CardItem(
            cardAddress: addr,
            cardName: "Asset Card",
            cardType: "",
            points: assets.points ?? "0",
            points6: assets.points6 ?? "0",
            cardCurrency: assets.cardCurrency ?? "CAD",
            nfts: assets.nfts ?? [],
            cardBackground: nil,
            cardImage: nil,
            tierName: nil,
            tierDescription: nil,
            primaryMemberTokenId: assets.primaryMemberTokenId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            tierDiscountPercent: nil
        ),
    ]
}

/// Balance Details：仅保留与终端 `merchantInfraCard` 一致的卡行（POS admin / program card），不展示其它会员卡。
private func readBalancePosAdminCards(from assets: UIDAssets?, merchantInfraCard: String) -> [CardItem]? {
    guard let assets else { return nil }
    let infra = merchantInfraCard.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    /// One row per `cardAddress` (API may repeat the same program card). Balance Details shows at most one pass panel.
    func dedupeSameAddress(_ items: [CardItem]) -> [CardItem] {
        var seen = Set<String>()
        var out: [CardItem] = []
        for it in items {
            let k = it.cardAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !k.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k)
            out.append(it)
        }
        return out
    }
    if infra.isEmpty {
        if let c = assets.cards, !c.isEmpty {
            let infraRows = c.filter { $0.cardType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "infrastructure" }
            let pick = dedupeSameAddress(infraRows.isEmpty ? [c[0]] : infraRows)
            return pick.isEmpty ? [] : [pick[0]]
        }
        if let list = readBalanceCardList(from: assets) {
            let d = dedupeSameAddress(list)
            return d.isEmpty ? [] : [d[0]]
        }
        return nil
    }
    if let c = assets.cards, !c.isEmpty {
        let filtered = c.filter { $0.cardAddress.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == infra }
        let u = dedupeSameAddress(filtered)
        return u.isEmpty ? [] : [u[0]]
    }
    guard let addr = assets.cardAddress?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
    guard addr.lowercased() == infra else { return [] }
    return [
        CardItem(
            cardAddress: addr,
            cardName: "Asset Card",
            cardType: "",
            points: assets.points ?? "0",
            points6: assets.points6 ?? "0",
            cardCurrency: assets.cardCurrency ?? "CAD",
            nfts: assets.nfts ?? [],
            cardBackground: nil,
            cardImage: nil,
            tierName: nil,
            tierDescription: nil,
            primaryMemberTokenId: assets.primaryMemberTokenId?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
            tierDiscountPercent: nil
        ),
    ]
}

/// Android `parseDiscountPercentFromMembershipTierDescription`: first `N%` in tier marketing text.
private func readBalanceDiscountPercentFromDescription(_ text: String?) -> Double? {
    guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
    let pattern = #"(\d+(?:\.\d+)?)\s*%"#
    guard let re = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
          let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let r = Range(m.range(at: 1), in: text),
          let v = Double(text[r]) else { return nil }
    let clamped = min(100, max(0, v))
    return (clamped * 100).rounded() / 100
}

private func readBalanceTierDiscountPercent(for card: CardItem) -> Double? {
    if let d = card.tierDiscountPercent, d > 0 { return d }
    return readBalanceDiscountPercentFromDescription(card.tierDescription)
}

/// Tier discount 0–100 for UI (two decimals; aligns Android `formatTierDiscountPercentForUi`).
private func beamioTierDiscountPercentLabel(_ percent: Double) -> String {
    let r = (percent * 100).rounded() / 100
    return String(format: "%.2f", min(100, max(0, r)))
}

/// `subtotal * tierDiscountPercent / 100` rounded to cents for display parity with `readBalanceFormatMoney`.
private func beamioTierDiscountFiatAmount(subtotal: Double, tierDiscountPercent: Double) -> Double {
    let p = BeamioPaymentRouting.normalizeTierDiscountPercent(tierDiscountPercent)
    let raw = subtotal * p / 100.0
    return (raw * 100).rounded() / 100
}

/// Android `balanceAmountForBalanceDetailsHero` / `formatPointsBalanceForBalanceDetails`: prefer on-chain `points6`, then human `points`.
private func readBalancePassHumanAmount(for card: CardItem) -> Double {
    let p6Trim = card.points6.trimmingCharacters(in: .whitespacesAndNewlines)
    if let p6 = Int64(p6Trim), p6 > 0 {
        return Double(p6) / 1_000_000.0
    }
    return Double(card.points.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
}

private func readBalanceFormatMoney(_ amount: Double, currency: String) -> (prefix: String, mid: String, suffix: String) {
    let fmt = NumberFormatter()
    fmt.numberStyle = .decimal
    fmt.minimumFractionDigits = 2
    fmt.maximumFractionDigits = 2
    fmt.locale = Locale(identifier: "en_US")
    let mid = fmt.string(from: NSNumber(value: amount)) ?? String(format: "%.2f", amount)
    let c = currency.uppercased()
    let prefix: String = switch c {
    case "CAD": "CA$"
    case "USD": "$"
    case "EUR": "€"
    case "JPY": "JP¥"
    case "CNY": "CN¥"
    case "HKD": "HK$"
    case "SGD": "SG$"
    case "TWD": "NT$"
    default: ""
    }
    let suffix = c == "USDC" ? " USDC" : ""
    return (prefix, mid, suffix)
}

private func readBalanceParseHexColor(_ raw: String?) -> Color? {
    guard var s = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6 || s.count == 8 else { return nil }
    var rgb: UInt64 = 0
    guard Scanner(string: s).scanHexInt64(&rgb) else { return nil }
    if s.count == 8 {
        let a = Double((rgb >> 24) & 0xFF) / 255
        let r = Double((rgb >> 16) & 0xFF) / 255
        let g = Double((rgb >> 8) & 0xFF) / 255
        let b = Double(rgb & 0xFF) / 255
        return Color(red: r, green: g, blue: b, opacity: a)
    }
    let r = Double((rgb >> 16) & 0xFF) / 255
    let g = Double((rgb >> 8) & 0xFF) / 255
    let b = Double(rgb & 0xFF) / 255
    return Color(red: r, green: g, blue: b)
}

/// Gradient end stop: slightly darker for depth (tier `cardBackground` is a single hex).
private func paymentSuccessDarkerShade(of color: Color) -> Color {
    let ui = UIColor(color)
    var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
    if ui.getHue(&h, saturation: &s, brightness: &b, alpha: &a) {
        return Color(
            UIColor(hue: h, saturation: min(1, s + 0.04), brightness: max(0.12, b * 0.76), alpha: a)
        )
    }
    return color
}

/// Payer tier metadata：与 Top-up 成功页一致，优先 VM 合并后的 `state.cardBackground`，再 fall back pass。
private func paymentSuccessTierCardGradientColors(
    state: ChargeSuccessState,
    fallbackStart: Color,
    fallbackEnd: Color
) -> [Color] {
    let raw: String? = {
        if let s = state.cardBackground?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        if let s = state.passCard?.cardBackground?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty { return s }
        return nil
    }()
    guard let base = readBalanceParseHexColor(raw) else {
        return [fallbackStart, fallbackEnd]
    }
    return [base, paymentSuccessDarkerShade(of: base)]
}

private func readBalanceMemberNo(from card: CardItem?) -> String {
    guard let card else { return "" }
    let primary = card.primaryMemberTokenId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    if !primary.isEmpty, (Int64(primary) ?? 0) > 0 {
        return "M-\(primary.readBalancePadStart(6))"
    }
    let legacy = card.nfts
        .filter { (Int64($0.tokenId) ?? 0) > 0 }
        .max(by: { (Int64($0.tokenId) ?? 0) < (Int64($1.tokenId) ?? 0) })?
        .tokenId
    if let legacy, (Int64(legacy) ?? 0) > 0 {
        return "M-\(legacy.readBalancePadStart(6))"
    }
    return ""
}

private func readBalanceChainTierLabel(from card: CardItem) -> String? {
    let primaryTid = card.primaryMemberTokenId?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let primaryNft: NftItem?
    if !primaryTid.isEmpty {
        primaryNft = card.nfts.first {
            $0.tokenId == primaryTid || $0.tokenId.caseInsensitiveCompare(primaryTid) == .orderedSame
        }
    } else {
        primaryNft = card.nfts.filter { (Int64($0.tokenId) ?? 0) > 0 }
            .max(by: { (Int64($0.tokenId) ?? 0) < (Int64($1.tokenId) ?? 0) })
    }
    guard let nft = primaryNft else { return nil }
    let tierRaw = nft.tier.trimmingCharacters(in: .whitespacesAndNewlines)
    if tierRaw.isEmpty { return nil }
    if tierRaw.allSatisfy(\.isNumber) { return "Tier \(tierRaw)" }
    if let r = try? NSRegularExpression(pattern: "(?i)chain-tier-(\\d+)"),
       let m = r.firstMatch(in: tierRaw, range: NSRange(tierRaw.startIndex..., in: tierRaw)),
       m.numberOfRanges > 1,
       let range = Range(m.range(at: 1), in: tierRaw) {
        return "Tier \(String(tierRaw[range]))"
    }
    return nil
}

private func readBalancePassTierSubtitle(for card: CardItem) -> String {
    let displayName = card.tierName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let chainTier = readBalanceChainTierLabel(from: card)
    let descRaw = card.tierDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let desc: String? = descRaw.isEmpty || descRaw.caseInsensitiveCompare("Card") == .orderedSame ? nil : descRaw
    let dn = displayName
    let ct = chainTier
    if let dn, let desc, desc.caseInsensitiveCompare(dn) != .orderedSame, !desc.lowercased().hasPrefix(dn.lowercased()) {
        return "\(dn) · \(desc)"
    }
    if let dn { return dn }
    if let ct, let desc, desc.caseInsensitiveCompare(ct) != .orderedSame, !desc.lowercased().hasPrefix(ct.lowercased()) {
        return "\(ct) · \(desc)"
    }
    if let ct { return ct }
    if let desc { return desc }
    let ctStr = card.cardType.trimmingCharacters(in: .whitespacesAndNewlines)
    if !ctStr.isEmpty, ctStr.lowercased() != "infrastructure" {
        return String(ctStr.prefix(1).uppercased() + ctStr.dropFirst())
    }
    return ""
}

private extension String {
    var nilIfEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    func readBalancePadStart(_ minLength: Int, pad: Character = "0") -> String {
        guard count < minLength else { return self }
        return String(repeating: String(pad), count: minLength - count) + self
    }
}

// MARK: - Payment success (Android `PaymentSuccessContent`)

/// Full-screen charge preflight (`verra-home` `ndef1.html` — Transaction Status / Insufficient Balance).
private struct ChargeInsufficientFundsView: View {
    let state: ChargeInsufficientFundsState
    var onClose: () -> Void
    var onTopUp: () -> Void
    var onChargeAvailable: () -> Void

    // Theme aligned with `ndef1.html` (M3 / Tailwind extend colors).
    private let bgBackground = Color(red: 249 / 255, green: 249 / 255, blue: 254 / 255)
    private let headerBlue = Color(red: 0, green: 82 / 255, blue: 210 / 255)
    private let surfaceLow = Color(red: 243 / 255, green: 243 / 255, blue: 248 / 255)
    private let surfaceHighest = Color(red: 226 / 255, green: 226 / 255, blue: 231 / 255)
    private let primaryGradA = Color(red: 0, green: 75 / 255, blue: 195 / 255)
    private let primaryGradB = Color(red: 0, green: 82 / 255, blue: 210 / 255)
    private let errorRed = Color(red: 186 / 255, green: 26 / 255, blue: 26 / 255)
    private let onErrorContainer = Color(red: 147 / 255, green: 0, blue: 10 / 255)
    private let errorContainer = Color(red: 255 / 255, green: 218 / 255, blue: 214 / 255)
    private let onSurface = Color(red: 26 / 255, green: 28 / 255, blue: 31 / 255)
    private let onSurfaceVariant = Color(red: 67 / 255, green: 70 / 255, blue: 84 / 255)

    private var currency: String { state.payCurrency }

    /// Proportional pay-currency estimate from USDC6 totals (same path as charge routing).
    private var walletBalanceInPayCurrency: Double {
        guard state.requiredUsdc6 > 0 else { return 0 }
        return state.chargeTotalInPayCurrency * Double(state.availableUsdc6) / Double(state.requiredUsdc6)
    }

    private var shortfallInPayCurrency: Double {
        max(0, state.chargeTotalInPayCurrency - walletBalanceInPayCurrency)
    }

    private var taxAmt: Double { state.subtotal * state.taxPercent / 100.0 }
    private var discAmt: Double {
        beamioTierDiscountFiatAmount(subtotal: state.subtotal, tierDiscountPercent: state.tierDiscountPercent)
    }

    var body: some View {
        ZStack {
            radialGlowBackdrop
            VStack(spacing: 0) {
                transactionStatusHeader
                ScrollView {
                    VStack(spacing: 24) {
                        heroSection
                        summaryCard
                        smartRoutingCard
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                    .padding(.bottom, 12)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(bgBackground.ignoresSafeArea())
        .safeAreaInset(edge: .bottom, spacing: 0) {
            actionButtonsInset
        }
    }

    private var radialGlowBackdrop: some View {
        ZStack {
            bgBackground
            Circle()
                .fill(Color(red: 219 / 255, green: 225 / 255, blue: 1).opacity(0.35))
                .frame(width: 280, height: 280)
                .blur(radius: 60)
                .offset(x: 120, y: -280)
            Circle()
                .fill(Color(red: 179 / 255, green: 197 / 255, blue: 1).opacity(0.28))
                .frame(width: 260, height: 260)
                .blur(radius: 50)
                .offset(x: -140, y: 320)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private var transactionStatusHeader: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(headerBlue)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
            Text("Transaction Status")
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(headerBlue)
                .frame(maxWidth: .infinity)
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 8)
    }

    private var heroSection: some View {
        VStack(spacing: 0) {
            ZStack {
                Circle()
                    .fill(errorContainer)
                    .frame(width: 56, height: 56)
                Image(systemName: "creditcard.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(onErrorContainer)
            }
            .padding(.bottom, 16)
            Text("Insufficient Balance")
                .font(.system(size: 28, weight: .heavy))
                .foregroundStyle(onSurface)
                .multilineTextAlignment(.center)
                .padding(.bottom, 8)
            Text("Your wallet requires additional funds to complete this request.")
                .font(.system(size: 14))
                .foregroundStyle(onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 8)
        }
        .frame(maxWidth: .infinity)
    }

    private var summaryCard: some View {
        let corner: CGFloat = 16
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                chargeSummaryRow(label: "Total Charge Amount", amount: state.chargeTotalInPayCurrency)
                chargeSummaryRow(label: "Current Wallet Balance", amount: walletBalanceInPayCurrency)
            }
            .padding(20)
            HStack {
                Text("Shortfall Amount")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(errorRed)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
                Text("-\(chargeInsufficientMonoline(shortfallInPayCurrency, currency: currency))")
                    .font(.system(size: 20, weight: .heavy, design: .monospaced))
                    .foregroundStyle(errorRed)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity)
            .background(errorContainer.opacity(0.22))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceLow)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private func chargeSummaryRow(label: String, amount: Double) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(onSurfaceVariant)
            Spacer()
            Text(chargeInsufficientMonoline(amount, currency: currency))
                .font(.system(size: 18, weight: .bold, design: .monospaced))
                .foregroundStyle(onSurface)
        }
    }

    private var smartRoutingCard: some View {
        let corner: CGFloat = 16
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "cpu")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(headerBlue)
                Text("Smart Routing Engine")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(headerBlue)
                    .textCase(.uppercase)
                    .tracking(1.2)
            }
            .padding(.bottom, 16)
            VStack(spacing: 12) {
                routingLine("Voucher Deduction", amount: state.subtotal)
                routingLine(
                    "Tier discount (\(beamioTierDiscountPercentLabel(state.tierDiscountPercent))%)",
                    amount: discAmt
                )
                routingLine("Tip", amount: state.tip)
                routingLine("Tax", amount: taxAmt)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceHighest.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
    }

    private func routingLine(_ label: String, amount: Double) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 14))
                .foregroundStyle(onSurfaceVariant)
            Spacer()
            Text(chargeInsufficientMonoline(amount, currency: currency))
                .font(.system(size: 14, weight: .medium, design: .monospaced))
                .foregroundStyle(onSurface)
        }
    }

    private var actionButtonsInset: some View {
        VStack(spacing: 12) {
            Button(action: onTopUp) {
                Text("Top-Up")
                    .font(.system(size: 16, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(
                            colors: [primaryGradA, primaryGradB],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                    .shadow(color: Color.black.opacity(0.06), radius: 12, x: 0, y: 4)
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())

            if state.availableUsdc6 > 0 {
                Button(action: onChargeAvailable) {
                    HStack(spacing: 8) {
                        Text("Charge available balance")
                        Image(systemName: "arrow.forward")
                            .font(.system(size: 14, weight: .semibold))
                    }
                    .font(.system(size: 15, weight: .bold))
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .foregroundStyle(.white)
                    .background(
                        LinearGradient(
                            colors: [primaryGradA, primaryGradB],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: Capsule()
                    )
                }
                .buttonStyle(BeamioHapticPlainButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .background(bgBackground.ignoresSafeArea(edges: .bottom))
    }
}

private func chargeInsufficientMonoline(_ amount: Double, currency: String) -> String {
    let p = readBalanceFormatMoney(amount, currency: currency)
    return "\(p.prefix) \(p.mid)\(p.suffix)".trimmingCharacters(in: .whitespaces)
}

/// System share sheet (`ndef1.html` receipt share affordance).
private struct ActivitySharingView: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

private func paymentSuccessMemberTitle(_ state: ChargeSuccessState) -> String {
    readBalancePassHeroMemberDisplayName(
        beamioTag: state.customerBeamioTag,
        walletAddress: state.customerWalletAddress,
        passCard: state.passCard,
        cardNameFallback: state.cardName ?? state.passCard?.cardName
    )
}

/// Android `baseScanTransactionUri` — opens BaseScan tx page.
private func beamioBaseScanTxUrl(_ txHash: String) -> URL? {
    let t = txHash.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.isEmpty { return nil }
    let path: String
    if t.hasPrefix("0x") || t.hasPrefix("0X") {
        path = t
    } else if t.count == 64, t.allSatisfy({ $0.isHexDigit }) {
        path = "0x\(t.lowercased())"
    } else {
        path = t
    }
    return URL(string: "https://basescan.org/tx/\(path)")
}

/// Android `PaymentSuccessContent` — total first, then SMART ROUTING ENGINE breakdown.
private func paymentSuccessReceiptRoutingCard(
    state: ChargeSuccessState,
    subtotal: Double,
    currency: String,
    compact: Bool
) -> some View {
    let amountNum = Double(state.amount) ?? 0
    let taxP = state.chargeTaxPercent ?? 0
    let taxAmt = subtotal * taxP / 100.0
    let discP = state.chargeTierDiscountPercent
    let discAmt = discP.map { beamioTierDiscountFiatAmount(subtotal: subtotal, tierDiscountPercent: $0) }
    let tipNum = Double(state.tip ?? "") ?? 0
    let primaryContainer = Color(red: 0, green: 75 / 255, blue: 195 / 255)
    let primary = Color(red: 0, green: 55 / 255, blue: 146 / 255)
    let onSurfaceVariant = Color(red: 67 / 255, green: 70 / 255, blue: 84 / 255)
    let onSurface = Color(red: 26 / 255, green: 28 / 255, blue: 31 / 255)
    let outline = Color(red: 115 / 255, green: 118 / 255, blue: 133 / 255)
    let outlineVariant = Color(red: 195 / 255, green: 198 / 255, blue: 214 / 255)
    let surfaceContainerLow = Color(red: 243 / 255, green: 243 / 255, blue: 248 / 255)
    let sumParts = readBalanceFormatMoney(amountNum, currency: currency)
    let sumMainSize: CGFloat = compact ? 30 : 34
    let sumSideSize: CGFloat = compact ? 20 : 22

    return VStack(alignment: .leading, spacing: 12) {
        HStack {
            Spacer(minLength: 0)
            HStack(alignment: .center, spacing: 0) {
                if !sumParts.prefix.isEmpty {
                    Text(sumParts.prefix)
                        .font(.system(size: sumSideSize, weight: .bold, design: .monospaced))
                        .foregroundStyle(primaryContainer)
                }
                Text(sumParts.mid)
                    .font(.system(size: sumMainSize, weight: .bold, design: .monospaced))
                    .foregroundStyle(primaryContainer)
                if !sumParts.suffix.isEmpty {
                    Text(sumParts.suffix)
                        .font(.system(size: sumSideSize, weight: .bold, design: .monospaced))
                        .foregroundStyle(primaryContainer)
                }
            }
            Spacer(minLength: 0)
        }
        Rectangle()
            .fill(outlineVariant.opacity(0.35))
            .frame(height: 1)
        HStack(spacing: 8) {
            Image(systemName: "memorychip")
                .font(.system(size: 18))
                .foregroundStyle(primary)
            Text("SMART ROUTING ENGINE")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(onSurfaceVariant)
                .tracking(0.2)
        }
        HStack {
            Text("Voucher Deduction")
                .font(.system(size: 14))
                .foregroundStyle(onSurfaceVariant)
            Spacer()
            paymentSuccessRoutingAmountParts(amount: subtotal, currency: currency, negative: false, foreground: onSurface)
        }
        HStack {
            Text("Tax (\(String(format: "%.2f", taxP))%)")
                .font(.system(size: 14))
                .foregroundStyle(onSurfaceVariant)
            Spacer()
            paymentSuccessRoutingAmountParts(amount: taxAmt, currency: currency, negative: false, foreground: outline)
        }
        HStack(alignment: .center) {
            HStack(spacing: 6) {
                Text("Tier discount")
                    .font(.system(size: 14))
                    .foregroundStyle(onSurfaceVariant)
                if let d = discP, d > 0 {
                    Text("\(beamioTierDiscountPercentLabel(d))%")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(primaryContainer)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(primaryContainer.opacity(0.1))
                        .clipShape(Capsule())
                }
            }
            Spacer()
            if let d = discP, d > 0, let da = discAmt {
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("- ")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(primary)
                    paymentSuccessRoutingAmountParts(amount: da, currency: currency, negative: false, foreground: primary)
                }
            } else {
                Text("—")
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color(red: 148 / 255, green: 163 / 255, blue: 184 / 255))
            }
        }
        Rectangle()
            .fill(outlineVariant.opacity(0.35))
            .frame(height: 1)
            .padding(.top, 2)
        HStack {
            Text("Tip")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(onSurfaceVariant)
            Spacer()
            paymentSuccessRoutingAmountParts(amount: tipNum, currency: currency, negative: false, foreground: onSurface)
        }
    }
    .padding(18)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(surfaceContainerLow)
    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
}

private func paymentSuccessRoutingAmountParts(
    amount: Double,
    currency: String,
    negative: Bool,
    foreground: Color
) -> some View {
    let parts = readBalanceFormatMoney(amount, currency: currency)
    return HStack(alignment: .center, spacing: 2) {
        if negative {
            Text("−")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(foreground)
        }
        if !parts.prefix.isEmpty {
            Text(parts.prefix)
                .font(.system(size: 12))
                .foregroundStyle(foreground)
        }
        Text(parts.mid)
            .font(.system(size: 14, weight: .semibold, design: .monospaced))
            .foregroundStyle(foreground)
        if !parts.suffix.isEmpty {
            Text(parts.suffix)
                .font(.system(size: 12))
                .foregroundStyle(foreground)
        }
    }
}

/// Android `PaymentSuccessContent` — overlapping `StandardMemberPassHeroCard` + Approved badge.
private func paymentSuccessStandardPassHero(
    state: ChargeSuccessState,
    displayMemberNo: String,
    balanceParts: (prefix: String, mid: String, suffix: String)?
) -> some View {
    let pass = state.passCard
    let memberTitle = paymentSuccessMemberTitle(state)
    let heroMemberNo: String = {
        let m = pass?.formattedMemberNumber() ?? ""
        if !m.isEmpty { return m }
        return displayMemberNo
    }()
    let tierLine: String? = {
        if let t = pass?.tierName?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { return t }
        let s = state.tierName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? nil : s
    }()
    let tierDisc: Double? = {
        if let p = pass, let d = readBalanceTierDiscountPercent(for: p) { return d }
        if let c = state.chargeTierDiscountPercent, c > 0 { return c }
        return nil
    }()
    let programLine: String = {
        if let p = pass {
            let line = readBalanceBalanceDetailsCardNameLine(card: p)
            if line != "—" { return line }
        }
        let n = state.cardName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !n.isEmpty {
            let t = n.replacingOccurrences(of: " CARD", with: "")
                .replacingOccurrences(of: " Card", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { return t }
        }
        return "—"
    }()
    /// 与 Top-up 成功页一致：优先 `state` 中 metadata 合并后的底色，避免 pass 内滞后 NFT 字段盖住。
    let bgHex = state.cardBackground?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? pass?.cardBackground?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let imgUrl = state.cardImage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? pass?.cardImage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let balP = balanceParts?.prefix ?? ""
    let balM = balanceParts?.mid ?? "—"
    let balS = balanceParts?.suffix ?? ""

    let pageBg = Color(red: 249 / 255, green: 249 / 255, blue: 254 / 255)
    let primaryContainer = Color(red: 0, green: 75 / 255, blue: 195 / 255)
    let overlapTop: CGFloat = 48

    return VStack(spacing: 0) {
        ZStack(alignment: .top) {
            VStack(spacing: 0) {
                Color.clear.frame(height: overlapTop)
                ReadBalanceStandardPassHeroCard(
                    memberDisplayName: memberTitle,
                    memberNo: heroMemberNo.isEmpty ? "—" : heroMemberNo,
                    tierDisplayName: tierLine,
                    tierDiscountPercent: tierDisc,
                    programCardDisplayName: programLine,
                    tierCardBackgroundHex: bgHex,
                    cardMetadataImageUrl: imgUrl,
                    balancePrefix: balP,
                    balanceAmount: balM,
                    balanceSuffix: balS
                )
            }
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 68, height: 68)
                    Circle()
                        .stroke(pageBg, lineWidth: 4)
                        .frame(width: 68, height: 68)
                    Circle()
                        .fill(primaryContainer)
                        .frame(width: 56, height: 56)
                        .shadow(color: primaryContainer.opacity(0.35), radius: 12, x: 0, y: 4)
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 28))
                        .foregroundStyle(.white)
                }
                Text("Approved")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(primaryContainer)
                    .tracking(2)
                    .textCase(.uppercase)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .shadow(color: Color.black.opacity(0.06), radius: 4, x: 0, y: 2)
            }
            .offset(y: -overlapTop)
        }
    }
    .frame(maxWidth: .infinity)
}

/// Full-screen charge success (`verra-home` `ndef1.html` — Transaction Receipt or Partial Charge Approved).
private struct PaymentSuccessView: View {
    let state: ChargeSuccessState
    var onDone: () -> Void
    var onContinueRemainingCharge: (() -> Void)? = nil

    @State private var isSharing = false

    private let bgBackground = Color(red: 249 / 255, green: 249 / 255, blue: 254 / 255)
    private let headerBlue = Color(red: 0, green: 82 / 255, blue: 210 / 255)
    private let onSurface = Color(red: 26 / 255, green: 28 / 255, blue: 31 / 255)
    private let onSurfaceVariant = Color(red: 67 / 255, green: 70 / 255, blue: 84 / 255)
    private let outlineLabel = Color(red: 115 / 255, green: 118 / 255, blue: 133 / 255)
    private let primaryContainer = Color(red: 0, green: 75 / 255, blue: 195 / 255)
    private let primaryGradEnd = Color(red: 21 / 255, green: 98 / 255, blue: 240 / 255)
    private let emeraldFg = Color(red: 5 / 255, green: 150 / 255, blue: 105 / 255)
    private let emeraldBg = Color(red: 209 / 255, green: 250 / 255, blue: 229 / 255)
    private let errorRed = Color(red: 186 / 255, green: 26 / 255, blue: 26 / 255)
    /// Same as Read Balance `Top-Up Card Now` / AmountPad top-up primary (`ReadBalanceView` `topUpBlue`).
    private let checkBalancePrimaryButtonBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)

    /// Matches `overlapTop` in `paymentSuccessStandardPassHero` (badge draws this far above its layout box).
    private let paymentSuccessReceiptHeroOverlapTop: CGFloat = 48
    /// Clearance below `SheetCircularBackButton` (no full-width top bar).
    private let paymentSuccessFloatingBackClearance: CGFloat = 52

    private var partialCardGradient: [Color] {
        paymentSuccessTierCardGradientColors(state: state, fallbackStart: primaryContainer, fallbackEnd: primaryGradEnd)
    }

    var body: some View {
        GeometryReader { geo in
            let routingCompact = geo.size.height < 700
            let currency = state.cardCurrency ?? "CAD"
            let postNum = Double(state.postBalance ?? "") ?? nil
            let shortPayee = paymentShortAddr(state.payee)
            let memRaw = state.memberNo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let displayMemberNo = memRaw.isEmpty ? (shortPayee ?? "—") : memRaw
            let dateStr = topupFormatReceiptDate(Date())
            let subtotalNum = Double(state.subtotal ?? "") ?? nil
            let memberTitle = paymentSuccessMemberTitle(state)
            let balanceParts = postNum.map { readBalanceFormatMoney($0, currency: currency) }
            let chargedNum = Double(state.amount) ?? 0
            let shortfallNum = Double(state.remainingShortfall ?? "") ?? 0

            ZStack(alignment: .top) {
                receiptRadialBackdrop
                VStack(spacing: 0) {
                    ScrollView {
                        VStack(spacing: 20) {
                            if state.isPartialApproval {
                                partialHero(
                                    gradientColors: partialCardGradient,
                                    memberTitle: memberTitle,
                                    displayMemberNo: displayMemberNo,
                                    balanceParts: balanceParts,
                                    currency: currency,
                                    charged: chargedNum,
                                    shortfall: shortfallNum
                                )
                                if let sub = subtotalNum {
                                    paymentSuccessPartialRoutingBreakdown(state: state, subtotal: sub, currency: currency)
                                }
                                partialFooterGrid(dateStr: dateStr, displayMemberNo: displayMemberNo)
                            } else {
                                paymentSuccessStandardPassHero(
                                    state: state,
                                    displayMemberNo: displayMemberNo,
                                    balanceParts: balanceParts
                                )
                                if let sub = subtotalNum {
                                    paymentSuccessReceiptRoutingCard(
                                        state: state,
                                        subtotal: sub,
                                        currency: currency,
                                        compact: routingCompact
                                    )
                                }
                                receiptMetadata(displayMemberNo: displayMemberNo, dateStr: dateStr)
                                Color.clear.frame(height: 96)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(
                            .top,
                            paymentSuccessFloatingBackClearance
                                + (state.isPartialApproval ? 12 : 12 + paymentSuccessReceiptHeroOverlapTop)
                        )
                        .padding(.bottom, 24)
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .overlay(alignment: .topLeading) {
                SheetCircularBackButton(action: onDone)
                    .padding(.leading, 8)
                    .safeAreaPadding(.top, 6)
            }
            .overlay(alignment: .topTrailing) {
                HStack(spacing: 0) {
                    Button {
                        isSharing = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(readBalanceDetailsOutline)
                            .frame(width: 40, height: 44)
                    }
                    .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
                    if !state.isPartialApproval {
                        Button {
                            chargePrintReceipt(state: state, dateString: dateStr)
                        } label: {
                            Image(systemName: "printer.fill")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(readBalanceDetailsOutline)
                                .frame(width: 40, height: 44)
                        }
                        .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
                    }
                }
                .padding(.trailing, 8)
                .safeAreaPadding(.top, 6)
            }
            .background(bgBackground.ignoresSafeArea())
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if state.isPartialApproval, let onContinue = onContinueRemainingCharge {
                    VStack(spacing: 10) {
                        Button(action: onContinue) {
                            HStack(spacing: 6) {
                                Text("Continue Remaining Charge")
                                    .font(.system(size: 14, weight: .semibold))
                                Image(systemName: "arrow.forward")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(.white)
                            .background(RoundedRectangle(cornerRadius: 12).fill(checkBalancePrimaryButtonBlue))
                        }
                        .buttonStyle(BeamioHapticPlainButtonStyle())
                        Button(action: onDone) {
                            Text("Cancel Remaining")
                                .font(.system(size: 14, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .foregroundStyle(readBalanceDetailsOnSurface)
                                .background(
                                    RoundedRectangle(cornerRadius: 12)
                                        .stroke(Color.black.opacity(0.3), lineWidth: 1)
                                )
                        }
                        .buttonStyle(BeamioHapticPlainButtonStyle())
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity)
                    .background(bgBackground.ignoresSafeArea(edges: .bottom))
                }
            }
            .sheet(isPresented: $isSharing) {
                ActivitySharingView(activityItems: [chargeReceiptPlainText(state: state, dateString: dateStr)])
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func partialHero(
        gradientColors: [Color],
        memberTitle: String,
        displayMemberNo: String,
        balanceParts: (prefix: String, mid: String, suffix: String)?,
        currency: String,
        charged: Double,
        shortfall: Double
    ) -> some View {
        let sym = currencySymbolCode(currency)
        return VStack(spacing: 16) {
            ZStack(alignment: .top) {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 28)
                    partialBlueCard(
                        gradientColors: gradientColors,
                        memberTitle: memberTitle,
                        displayMemberNo: displayMemberNo,
                        balanceParts: balanceParts,
                        sym: sym
                    )
                }
                VStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(Color.white)
                            .frame(width: 56, height: 56)
                            .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 36))
                            .foregroundStyle(emeraldFg)
                    }
                    Text("Partial Approval")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color(red: 6 / 255, green: 95 / 255, blue: 70 / 255))
                        .tracking(1.4)
                        .textCase(.uppercase)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(emeraldBg)
                        .clipShape(Capsule())
                }
            }
            partialChargedShortfallCard(charged: charged, shortfall: shortfall, currency: currency)
        }
        .frame(maxWidth: .infinity)
    }

    private func partialBlueCard(
        gradientColors: [Color],
        memberTitle: String,
        displayMemberNo: String,
        balanceParts: (prefix: String, mid: String, suffix: String)?,
        sym: String
    ) -> some View {
        ZStack {
            LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(Color.white.opacity(0.08))
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    Text(memberTitle)
                        .font(.system(size: 20, weight: .heavy))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "radiowaves.right")
                        .font(.system(size: 28))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .padding(.top, 36)
                Spacer(minLength: 8)
                HStack(alignment: .bottom) {
                    Text(displayMemberNo)
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("Balance")
                            .font(.system(size: 10, weight: .medium))
                            .tracking(1.5)
                            .foregroundStyle(.white.opacity(0.7))
                            .textCase(.uppercase)
                        if let parts = balanceParts {
                            HStack(alignment: .lastTextBaseline, spacing: 3) {
                                if !parts.prefix.isEmpty {
                                    Text(parts.prefix)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                } else if !sym.isEmpty {
                                    Text(sym)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                                Text(parts.mid)
                                    .font(.system(size: 18, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                if !parts.suffix.isEmpty {
                                    Text(parts.suffix)
                                        .font(.system(size: 14, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                        } else {
                            Text("—")
                                .font(.system(size: 18, weight: .bold))
                                .foregroundStyle(.white)
                        }
                    }
                }
            }
            .padding(22)
        }
        .frame(height: 192)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.14), radius: 14, x: 0, y: 8)
    }

    /// Two-line amount: top = currency prefix/suffix (small), bottom = numeric mid (large). Keeps left/right columns aligned on small screens.
    private func partialApprovalAmountColumn(
        parts: (prefix: String, mid: String, suffix: String),
        foreground: Color,
        trailing: Bool
    ) -> some View {
        let pTrim = parts.prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let sTrim = parts.suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        let prefixFont = Font.system(size: 11, weight: .semibold)
        let suffixFont = Font.system(size: 11, weight: .medium)
        let numFont = Font.system(size: 28, weight: .bold, design: .monospaced)
        let hAlign: HorizontalAlignment = trailing ? .trailing : .leading
        let textAlign: TextAlignment = trailing ? .trailing : .leading
        let stackAlign: Alignment = trailing ? .trailing : .leading
        return VStack(alignment: hAlign, spacing: 6) {
            HStack(spacing: 4) {
                if !pTrim.isEmpty {
                    Text(pTrim)
                        .font(prefixFont)
                        .foregroundStyle(foreground)
                }
                if !sTrim.isEmpty {
                    Text(sTrim)
                        .font(suffixFont)
                        .foregroundStyle(foreground)
                }
                if pTrim.isEmpty, sTrim.isEmpty {
                    Text(" ")
                        .font(prefixFont)
                        .foregroundStyle(.clear)
                }
            }
            .frame(maxWidth: .infinity, alignment: stackAlign)
            Text(parts.mid)
                .font(numFont)
                .foregroundStyle(foreground)
                .multilineTextAlignment(textAlign)
                .lineLimit(4)
                .minimumScaleFactor(0.55)
                .frame(maxWidth: .infinity, alignment: stackAlign)
        }
    }

    private func partialChargedShortfallCard(charged: Double, shortfall: Double, currency: String) -> some View {
        let chargedParts = readBalanceFormatMoney(charged, currency: currency)
        let shortfallParts = readBalanceFormatMoney(shortfall, currency: currency)
        let primaryAmt = Color(red: 0, green: 55 / 255, blue: 146 / 255)
        return VStack(alignment: .leading, spacing: 14) {
            VStack(spacing: 10) {
                HStack(alignment: .center) {
                    Text("Successfully Charged")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(onSurfaceVariant)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Remaining Shortfall")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(errorRed)
                        .textCase(.uppercase)
                        .tracking(0.6)
                        .multilineTextAlignment(.trailing)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                HStack(alignment: .center, spacing: 12) {
                    partialApprovalAmountColumn(parts: chargedParts, foreground: primaryAmt, trailing: false)
                    Rectangle()
                        .fill(Color(red: 226 / 255, green: 226 / 255, blue: 231 / 255))
                        .frame(width: 1)
                        .frame(minHeight: 52)
                    partialApprovalAmountColumn(parts: shortfallParts, foreground: errorRed, trailing: true)
                }
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "info.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(onSurfaceVariant)
                Text("The member's balance was exhausted. Please collect the remaining amount via an alternative payment method.")
                    .font(.system(size: 11))
                    .foregroundStyle(onSurfaceVariant)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 243 / 255, green: 243 / 255, blue: 248 / 255))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 2)
    }

    private func partialFooterGrid(dateStr: String, displayMemberNo: String) -> some View {
        let settlement = state.settlementViaQr ? "App Validator" : "NTAG 424 DNA"
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Date & Time")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(outlineLabel)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text(dateStr)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(onSurface)
            }
            VStack(alignment: .trailing, spacing: 4) {
                Text("TX Hash")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(outlineLabel)
                    .textCase(.uppercase)
                    .tracking(0.8)
                if state.txHash.isEmpty {
                    Text("—")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(onSurface)
                        .lineLimit(1)
                } else if let url = beamioBaseScanTxUrl(state.txHash) {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Text(topupShortTx(state.txHash))
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(red: 0, green: 55 / 255, blue: 146 / 255))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(red: 0, green: 55 / 255, blue: 146 / 255).opacity(0.06))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
                } else {
                    Text(topupShortTx(state.txHash))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(onSurface)
                        .lineLimit(1)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Settlement (\(settlement))")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(outlineLabel)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Text(paymentShortAddr(state.payee) ?? "—")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(onSurface)
                    .lineLimit(1)
            }
            Text(displayMemberNo)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(onSurface)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
    }

    private var receiptRadialBackdrop: some View {
        ZStack {
            bgBackground
            Circle()
                .fill(Color(red: 219 / 255, green: 225 / 255, blue: 1).opacity(0.32))
                .frame(width: 280, height: 280)
                .blur(radius: 60)
                .offset(x: 120, y: -260)
            Circle()
                .fill(Color(red: 179 / 255, green: 197 / 255, blue: 1).opacity(0.26))
                .frame(width: 260, height: 260)
                .blur(radius: 50)
                .offset(x: -130, y: 300)
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }

    private func receiptMetadata(displayMemberNo: String, dateStr: String) -> some View {
        VStack(spacing: 10) {
            receiptMetaRow(left: "Date & Time", right: dateStr)
            HStack {
                Spacer(minLength: 0)
                Text(displayMemberNo)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(onSurface)
                    .multilineTextAlignment(.trailing)
            }
            if let t = state.tableNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                receiptMetaRow(left: "Table", right: t)
            }
            HStack {
                Text("TX HASH")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(outlineLabel)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
                if state.txHash.isEmpty {
                    Text("—")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(onSurface)
                } else if let url = beamioBaseScanTxUrl(state.txHash) {
                    Button {
                        UIApplication.shared.open(url)
                    } label: {
                        Text(topupShortTx(state.txHash))
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color(red: 0, green: 55 / 255, blue: 146 / 255))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color(red: 0, green: 55 / 255, blue: 146 / 255).opacity(0.06))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
                } else {
                    Text(topupShortTx(state.txHash))
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(Color(red: 0, green: 55 / 255, blue: 146 / 255))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color(red: 0, green: 55 / 255, blue: 146 / 255).opacity(0.06))
                        .clipShape(Capsule())
                }
            }
            HStack {
                Text("SETTLEMENT")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(outlineLabel)
                    .textCase(.uppercase)
                    .tracking(0.8)
                Spacer()
                HStack(spacing: 4) {
                    Text(state.settlementViaQr ? "App Validator" : "NTAG 424 DNA")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(onSurface)
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(headerBlue)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.top, 4)
    }

    private func receiptMetaRow(left: String, right: String) -> some View {
        HStack {
            Text(left)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(outlineLabel)
                .textCase(.uppercase)
                .tracking(0.8)
            Spacer()
            Text(right)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(onSurface)
                .multilineTextAlignment(.trailing)
        }
    }
}

private func currencySymbolCode(_ currency: String) -> String {
    let c = currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    switch c {
    case "CAD": return "CA$"
    case "USD": return "US$"
    case "EUR": return "€"
    case "GBP": return "£"
    default: return c.prefix(3).description
    }
}

/// `ndef1.html` partial charge — Smart Routing + total order (emerald deductions).
private func paymentSuccessPartialRoutingBreakdown(state: ChargeSuccessState, subtotal: Double, currency: String) -> some View {
    let taxP = state.chargeTaxPercent ?? 0
    let taxAmt = subtotal * taxP / 100.0
    let discP = state.chargeTierDiscountPercent
    let discAmt = discP.map { beamioTierDiscountFiatAmount(subtotal: subtotal, tierDiscountPercent: $0) }
    let tipNum = Double(state.tip ?? "") ?? 0
    let orderTotal = Double(state.originalOrderTotal ?? "") ?? 0
    let emerald = Color(red: 5 / 255, green: 150 / 255, blue: 105 / 255)
    let onSurfaceVariant = Color(red: 67 / 255, green: 70 / 255, blue: 84 / 255)
    let onSurface = Color(red: 26 / 255, green: 28 / 255, blue: 31 / 255)
    let divider = Color(red: 226 / 255, green: 226 / 255, blue: 231 / 255)
    let corner: CGFloat = 16
    let tierLabel: String = {
        if let d = discP, d > 0 { return "Tier Discount (\(beamioTierDiscountPercentLabel(d))%)" }
        return "Tier Discount"
    }()

    return VStack(alignment: .leading, spacing: 0) {
        Text("Smart Routing Engine")
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(onSurfaceVariant)
            .textCase(.uppercase)
            .tracking(1.2)
            .padding(.horizontal, 4)
            .padding(.bottom, 8)
        VStack(spacing: 10) {
            partialRoutingSignedRow(label: "Voucher Deduction", subtotal, currency: currency, negative: true, color: emerald)
            if let d = discAmt, discP ?? 0 > 0 {
                partialRoutingSignedRow(label: tierLabel, d, currency: currency, negative: true, color: emerald)
            }
            partialRoutingSignedRow(label: "Tax (\(String(format: "%.2f", taxP))%)", taxAmt, currency: currency, negative: false, color: onSurface)
            partialRoutingSignedRow(label: "Service Tip", tipNum, currency: currency, negative: false, color: onSurface)
            Rectangle()
                .fill(divider.opacity(0.5))
                .frame(height: 1)
                .padding(.vertical, 4)
            HStack {
                Text("Total Order Value")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(onSurface)
                Spacer()
                paymentSuccessRoutingAmountParts(amount: orderTotal, currency: currency, negative: false, foreground: onSurface)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .shadow(color: Color.black.opacity(0.05), radius: 6, x: 0, y: 2)
    }
}

private func partialRoutingSignedRow(
    label: String,
    _ amount: Double,
    currency: String,
    negative: Bool,
    color: Color
) -> some View {
    HStack {
        Text(label)
            .font(.system(size: 14))
            .foregroundStyle(Color(red: 67 / 255, green: 70 / 255, blue: 84 / 255))
        Spacer()
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            if negative {
                Text("−")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color)
            } else {
                Text("+")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(color)
            }
            paymentSuccessRoutingAmountParts(amount: amount, currency: currency, negative: false, foreground: color)
        }
    }
}

private func paymentShortAddr(_ payee: String) -> String? {
    let t = payee.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return nil }
    if t.count > 10 { return "\(t.prefix(6))…\(t.suffix(4))" }
    return t
}

private func paymentPassVoucherCard(
    state: ChargeSuccessState,
    displayMemberNo: String,
    postBalance: Double?,
    currency: String,
    cardBg: Color
) -> some View {
    let pass = state.passCard
    let accentGreen = Color(red: 0x6E / 255, green: 0xD0 / 255, blue: 0x88 / 255)
    let labelGrey = Color(red: 0xBB / 255, green: 0xBB / 255, blue: 0xBB / 255)
    let titleRaw: String? = {
        if let p = pass {
            let n = p.cardName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !n.isEmpty { return n }
        }
        let t = state.cardName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !t.isEmpty { return t }
        let tn = state.tierName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return tn.isEmpty ? nil : tn
    }()
    let titleTxt = (titleRaw ?? "Card")
        .replacingOccurrences(of: " CARD", with: "")
        .replacingOccurrences(of: " Card", with: "")
    let subtitle: String = {
        if let p = pass {
            let s = readBalancePassTierSubtitle(for: p)
            if !s.isEmpty { return s }
        }
        let tn = state.tierName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !tn.isEmpty, tn.caseInsensitiveCompare("Card") != .orderedSame { return tn }
        let ct = state.cardType?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if ct.isEmpty || ct.lowercased() == "infrastructure" { return "" }
        return ct.prefix(1).uppercased() + ct.dropFirst()
    }()

    return VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .top) {
            if let u = pass?.cardImage?.nilIfEmpty {
                BeamioCardRasterOrSvgImage(urlString: u, rasterContentMode: .fill) {
                    Image(systemName: "heart.fill").foregroundStyle(accentGreen)
                }
                .frame(width: 176, height: 140)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Image(systemName: "heart.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(accentGreen)
                    .frame(width: 176, height: 140, alignment: .center)
            }
            VStack(alignment: .trailing, spacing: 4) {
                Text(titleTxt)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                if !subtitle.isEmpty, subtitle.caseInsensitiveCompare("Card") != .orderedSame {
                    Text(subtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(labelGrey)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        Spacer().frame(height: 20)
        HStack(alignment: .bottom) {
            Text(displayMemberNo)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Balance")
                    .font(.system(size: 11))
                    .foregroundStyle(labelGrey)
                if let post = postBalance {
                    let p = readBalanceFormatMoney(post, currency: currency)
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        if !p.prefix.isEmpty {
                            Text(p.prefix)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(accentGreen)
                        }
                        Text(p.mid)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(accentGreen)
                        if !p.suffix.isEmpty {
                            Text(p.suffix)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(accentGreen)
                        }
                    }
                } else {
                    Text("—")
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(accentGreen)
                }
            }
        }
    }
    .padding(EdgeInsets(top: 20, leading: 20, bottom: 16, trailing: 20))
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 24).fill(cardBg))
}

private func paymentSmartRoutingCard(state: ChargeSuccessState, subtotal: Double, currency: String) -> some View {
    let taxP = state.chargeTaxPercent ?? 0
    let taxAmt = subtotal * taxP / 100.0
    let discP = state.chargeTierDiscountPercent
    let discAmt = discP.map { beamioTierDiscountFiatAmount(subtotal: subtotal, tierDiscountPercent: $0) }
    let tipNum = Double(state.tip ?? "") ?? 0

    return VStack(alignment: .leading, spacing: 0) {
        Text("Smart Routing Engine")
            .font(.system(size: 14, weight: .semibold))
            .padding(.bottom, 8)
        paymentRoutingMoneyRow(label: "Voucher Deduction", amount: subtotal, currency: currency, negative: false, discount: false)
        Spacer().frame(height: 8)
        paymentRoutingMoneyRow(label: "Tax (\(String(format: "%.2f", taxP))%)", amount: taxAmt, currency: currency, negative: false, discount: false)
        Spacer().frame(height: 8)
        if let d = discP, d > 0, let da = discAmt {
            paymentRoutingMoneyRow(
                label: "Tier discount (\(beamioTierDiscountPercentLabel(d))%)",
                amount: da,
                currency: currency,
                negative: true,
                discount: true
            )
        } else {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Tier discount")
                        .font(.system(size: 15))
                        .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                    Text("Not applied")
                        .font(.system(size: 11))
                        .foregroundStyle(Color(red: 0x94 / 255, green: 0xA3 / 255, blue: 0xB8 / 255))
                }
                Spacer()
                Text("—")
                    .font(.system(size: 15))
                    .foregroundStyle(Color(red: 0x94 / 255, green: 0xA3 / 255, blue: 0xB8 / 255))
            }
        }
        if tipNum > 0 {
            Spacer().frame(height: 8)
            paymentRoutingMoneyRow(label: "Tip", amount: tipNum, currency: currency, negative: false, discount: false)
        }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .systemBackground)))
    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.05), lineWidth: 1))
}

private func paymentRoutingMoneyRow(
    label: String,
    amount: Double,
    currency: String,
    negative: Bool,
    discount: Bool
) -> some View {
    let parts = readBalanceFormatMoney(amount, currency: currency)
    let mainC: Color = discount ? Color(red: 0x05 / 255, green: 0x96 / 255, blue: 0x69 / 255) : .primary
    return HStack {
        Text(label)
            .font(.system(size: 15))
            .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
        Spacer()
        HStack(alignment: .lastTextBaseline, spacing: 2) {
            if negative {
                Text("−")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(mainC)
            }
            if !parts.prefix.isEmpty {
                Text(parts.prefix)
                    .font(.system(size: 11))
                    .foregroundStyle(mainC)
            }
            Text(parts.mid)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(mainC)
            if !parts.suffix.isEmpty {
                Text(parts.suffix)
                    .font(.system(size: 11))
                    .foregroundStyle(mainC)
            }
        }
    }
}

private func chargeReceiptPlainText(state: ChargeSuccessState, dateString: String) -> String {
    let currency = state.cardCurrency ?? "CAD"
    let settlement = state.settlementViaQr ? "App Validator" : "NTAG 424 DNA"
    let shortPayee = paymentShortAddr(state.payee) ?? "—"
    let shortTx = state.txHash.isEmpty ? "—" : topupShortTx(state.txHash)
    let headline = state.isPartialApproval ? "PARTIAL CHARGE APPROVED" : "PAYMENT APPROVED"
    var lines: [String] = [
        headline,
        "",
        "Amount: \(topupFormatForReceipt(amount: state.amount, currency: currency))",
        "Card Balance: \(topupFormatForReceipt(amount: state.postBalance ?? "—", currency: currency))",
    ]
    if state.isPartialApproval {
        if let o = state.originalOrderTotal {
            lines.append("Original order total: \(topupFormatForReceipt(amount: o, currency: currency))")
        }
        if let r = state.remainingShortfall {
            lines.append("Remaining shortfall: \(topupFormatForReceipt(amount: r, currency: currency))")
        }
    }
    if let sub = state.subtotal {
        lines.append("Voucher Deduction: \(topupFormatForReceipt(amount: sub, currency: currency))")
        if let tip = state.tip, Double(tip) ?? 0 > 0 {
            lines.append("Tip: \(topupFormatForReceipt(amount: tip, currency: currency))")
        }
    }
    if let t = state.tableNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
        lines.append("Table number: \(t)")
    }
    lines.append(contentsOf: [
        "",
        "Date: \(dateString)",
        "Account ID: \(shortPayee)",
        "TX Hash: \(shortTx)",
        "",
        "Settlement: \(settlement)",
    ])
    return lines.joined(separator: "\n")
}

private func chargePrintReceipt(state: ChargeSuccessState, dateString: String) {
    let text = chargeReceiptPlainText(state: state, dateString: dateString)
    let fmt = UISimpleTextPrintFormatter(text: text)
    let pc = UIPrintInteractionController.shared
    pc.printFormatter = fmt
    pc.present(animated: true, completionHandler: nil)
}

// MARK: - Top-up success (Android `TopupSuccessContent` / `TopupScreen` Success)

private func topupSuccessStandardPassHero(
    state: TopupSuccessState,
    displayMemberNo: String,
    postBalance: Double?,
    currency: String
) -> some View {
    let pass = state.passCard
    let heroTitle = readBalancePassHeroMemberDisplayName(
        beamioTag: state.customerBeamioTag,
        walletAddress: state.address,
        passCard: pass,
        cardNameFallback: pass?.cardName
    )
    let heroMemberNo: String = {
        let m = pass?.formattedMemberNumber() ?? ""
        if !m.isEmpty { return m }
        return displayMemberNo
    }()
    let tierLine: String? = {
        let pt = pass?.tierName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !pt.isEmpty { return pt }
        let st = state.tierName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return st.isEmpty ? nil : st
    }()
    let tierDisc = pass.flatMap { readBalanceTierDiscountPercent(for: $0) }
    let programLine: String = {
        if let p = pass {
            let line = readBalanceBalanceDetailsCardNameLine(card: p)
            if line != "—" { return line }
        }
        return "—"
    }()
    /// `TopupSuccessState` / VM merged pass 已写入卡级 tiers 覆盖后的底色；优先于 pass 内可能滞后的 NFT 源字段。
    let bgHex = state.cardBackground?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? pass?.cardBackground?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let imgUrl = state.cardImage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        ?? pass?.cardImage?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    let balP: String
    let balM: String
    let balS: String
    if let post = postBalance {
        let p = readBalanceFormatMoney(post, currency: currency)
        balP = p.prefix
        balM = p.mid
        balS = p.suffix
    } else {
        balP = ""
        balM = "—"
        balS = ""
    }
    return ReadBalanceStandardPassHeroCard(
        memberDisplayName: heroTitle,
        memberNo: heroMemberNo.isEmpty ? "—" : heroMemberNo,
        tierDisplayName: tierLine,
        tierDiscountPercent: tierDisc,
        programCardDisplayName: programLine,
        tierCardBackgroundHex: bgHex,
        cardMetadataImageUrl: imgUrl,
        balancePrefix: balP,
        balanceAmount: balM,
        balanceSuffix: balS
    )
}

private struct TopupSuccessView: View {
    let state: TopupSuccessState
    var onDone: () -> Void

    private let pageBg = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    private let checkGreen = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)

    var body: some View {
        let currency = state.cardCurrency ?? "CAD"
        let amountNum = Double(state.amount) ?? 0
        let amtParts = readBalanceFormatMoney(amountNum, currency: currency)
        let postNum = Double(state.postBalance ?? "") ?? nil
        let shortAddr = topupShortAddr(state.address)
        let memRaw = state.memberNo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayMemberNo = memRaw.isEmpty ? (shortAddr ?? "—") : memRaw
        let dateStr = topupFormatReceiptDate(Date())

        ZStack(alignment: .topLeading) {
            ZStack {
                readBalanceDetailsSurface
                GeometryReader { geo in
                    let compact = geo.size.height < 620
                    let amtMainSize: CGFloat = compact ? 30 : 36
                    ScrollView {
                        VStack(spacing: 0) {
                            VStack(spacing: 0) {
                                Spacer().frame(height: 56)
                                ZStack {
                                    Circle()
                                        .fill(Color.white)
                                        .frame(width: 56, height: 56)
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 32))
                                        .foregroundStyle(checkGreen)
                                }
                                HStack(alignment: .lastTextBaseline, spacing: 2) {
                                    Text("+")
                                        .font(.system(size: compact ? 14 : 16, weight: .medium))
                                        .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                                    if !amtParts.prefix.isEmpty {
                                        Text(amtParts.prefix)
                                            .font(.system(size: compact ? 9 : 10))
                                            .foregroundStyle(readBalanceDetailsOnSurface)
                                    }
                                    Text(amtParts.mid)
                                        .font(.system(size: amtMainSize, weight: .light))
                                        .foregroundStyle(readBalanceDetailsOnSurface)
                                    if !amtParts.suffix.isEmpty {
                                        Text(amtParts.suffix)
                                            .font(.system(size: compact ? 9 : 10))
                                            .foregroundStyle(readBalanceDetailsOnSurface)
                                    }
                                }
                                .padding(.top, 4)
                                .padding(.bottom, 12)
                            }
                            .frame(maxWidth: .infinity)

                            VStack(alignment: .leading, spacing: 12) {
                                topupSuccessStandardPassHero(
                                    state: state,
                                    displayMemberNo: displayMemberNo,
                                    postBalance: postNum,
                                    currency: currency
                                )
                                .padding(.horizontal, 20)

                                VStack(spacing: 0) {
                                    topupReceiptRow(left: "Date", right: dateStr)
                                    topupThinDivider
                                    HStack {
                                        Spacer(minLength: 0)
                                        Text(displayMemberNo)
                                            .font(.system(size: 13, weight: .medium))
                                            .foregroundStyle(readBalanceDetailsOnSurface)
                                    }
                                    .padding(.vertical, 6)
                                    if !state.txHash.isEmpty {
                                        topupThinDivider
                                        HStack {
                                            Text("TX Hash")
                                                .font(.system(size: 13))
                                                .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                                            Spacer()
                                            if let url = beamioBaseScanTxUrl(state.txHash) {
                                                Button {
                                                    UIApplication.shared.open(url)
                                                } label: {
                                                    Text(topupShortTx(state.txHash))
                                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                                        .foregroundStyle(Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255))
                                                }
                                                .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
                                            } else {
                                                Text(topupShortTx(state.txHash))
                                                    .font(.system(size: 13, weight: .medium))
                                                    .foregroundStyle(readBalanceDetailsOnSurface)
                                            }
                                        }
                                        .padding(.vertical, 6)
                                    }
                                    topupThinDivider
                                    HStack {
                                        Text("Settlement")
                                            .font(.system(size: 13))
                                            .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                                        Spacer()
                                        HStack(spacing: 4) {
                                            Image(systemName: "shield.fill")
                                                .font(.system(size: 12))
                                                .foregroundStyle(checkGreen)
                                            Text(state.settlementViaQr ? "App Validator" : "NTAG 424 DNA")
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundStyle(checkGreen)
                                        }
                                    }
                                    .padding(.vertical, 6)
                                }
                                .padding(.horizontal, 16)
                                .padding(.vertical, 8)
                                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                                .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.05), lineWidth: 1))
                                .padding(.horizontal, 20)
                                .padding(.bottom, 12)
                            }
                        }
                    }
                    .scrollIndicators(.hidden)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .safeAreaInset(edge: .bottom, spacing: 0) {
                        Button {
                            topupPrintReceipt(state: state, dateString: dateStr)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "printer.fill")
                                    .font(.system(size: 14))
                                Text("Print Receipt")
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .foregroundStyle(readBalanceDetailsOnSurface)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .stroke(Color.black.opacity(0.3), lineWidth: 1)
                            )
                        }
                        .buttonStyle(BeamioHapticPlainButtonStyle())
                        .padding(.horizontal, 20)
                        .padding(.top, 12)
                        .padding(.bottom, 8)
                        .frame(maxWidth: .infinity)
                        .background(pageBg.ignoresSafeArea(edges: .bottom))
                    }
                }
            }
            SheetCircularBackButton(action: onDone)
                .padding(.leading, 8)
                .safeAreaPadding(.top, 6)
        }
        .background(pageBg.ignoresSafeArea())
    }

    private var topupThinDivider: some View {
        Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
    }

    private func topupReceiptRow(left: String, right: String, rightBlue: Bool = false) -> some View {
        HStack {
            Text(left)
                .font(.system(size: 13))
                .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
            Spacer()
            Text(right)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(
                    rightBlue
                        ? Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)
                        : readBalanceDetailsOnSurface
                )
        }
        .padding(.vertical, 6)
    }
}

private func topupShortAddr(_ address: String?) -> String? {
    guard let a = address?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else { return nil }
    if a.count > 10 { return "\(a.prefix(6))…\(a.suffix(4))" }
    return a
}

private func topupShortTx(_ hash: String) -> String {
    if hash.count > 12 { return "\(hash.prefix(7))…\(hash.suffix(5))" }
    return hash
}

private func topupFormatReceiptDate(_ date: Date) -> String {
    let d = DateFormatter()
    d.locale = Locale(identifier: "en_US")
    d.dateFormat = "MMM d, yyyy"
    let t = DateFormatter()
    t.locale = Locale(identifier: "en_US")
    t.dateFormat = "h:mm a"
    return "\(d.string(from: date)), \(t.string(from: date))"
}

private func topupReceiptPlainText(state: TopupSuccessState, dateString: String) -> String {
    let currency = state.cardCurrency ?? "CAD"
    let amt = state.amount
    let post = state.postBalance ?? "—"
    let shortAddr = topupShortAddr(state.address) ?? "—"
    let shortTx = state.txHash.isEmpty ? "—" : topupShortTx(state.txHash)
    let lines = [
        "TOP-UP COMPLETE",
        "",
        "Amount: \(topupFormatForReceipt(amount: amt, currency: currency))",
        "Card Balance: \(topupFormatForReceipt(amount: post, currency: currency))",
        "",
        "Date: \(dateString)",
        "Account ID: \(shortAddr)",
        "TX Hash: \(shortTx)",
        "",
        "Settlement: \(state.settlementViaQr ? "App Validator" : "NTAG 424 DNA")",
    ]
    return lines.joined(separator: "\n")
}

private func topupFormatForReceipt(amount: String, currency: String) -> String {
    let num = Double(amount) ?? 0
    let p = readBalanceFormatMoney(num, currency: currency)
    if !p.prefix.isEmpty { return "\(p.prefix)\(p.mid)" }
    return "\(p.mid)\(p.suffix)"
}

private func topupPrintReceipt(state: TopupSuccessState, dateString: String) {
    let text = topupReceiptPlainText(state: state, dateString: dateString)
    let fmt = UISimpleTextPrintFormatter(text: text)
    let pc = UIPrintInteractionController.shared
    pc.printFormatter = fmt
    pc.present(animated: true, completionHandler: nil)
}

/// Android `PaymentRoutingMonitorDisplayCard`: dark bezel, monospace steps, optional error + tap retry.
private struct PaymentRoutingMonitorCard: View {
    let steps: [PaymentRoutingStepRow]
    var errorLine: String?
    var retryHint: String?
    var onRetryTap: (() -> Void)?

    private let screenBg = Color(red: 0x0f / 255, green: 0x14 / 255, blue: 0x19 / 255)
    private let bezelStroke = Color(red: 0x3d / 255, green: 0x45 / 255, blue: 0x53 / 255)
    private let lineOk = Color(red: 0x8a / 255, green: 0xe0 / 255, blue: 0x6c / 255)
    private let linePending = Color(red: 0x5c / 255, green: 0x6b / 255, blue: 0x5c / 255)

    var body: some View {
        let visible = steps.beamioPaymentRoutingStepsForDisplay(maxVisible: 6)
        ZStack {
            RoundedRectangle(cornerRadius: 32)
                .fill(screenBg)
                .overlay(RoundedRectangle(cornerRadius: 32).strokeBorder(bezelStroke, lineWidth: 2))
            VStack(alignment: .leading, spacing: 0) {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(visible) { step in
                        paymentRoutingRow(step)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 8)
                if let err = errorLine, !err.isEmpty {
                    Text(err)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color(red: 1, green: 0.42, blue: 0.42))
                        .lineLimit(2)
                        .padding(.top, 6)
                }
                if let hint = retryHint, !hint.isEmpty, errorLine != nil, !(errorLine ?? "").isEmpty {
                    Text(hint)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(Color(red: 0x7c / 255, green: 0x8a / 255, blue: 0x99 / 255))
                        .frame(maxWidth: .infinity)
                        .multilineTextAlignment(.center)
                        .padding(.top, 6)
                }
            }
            .padding(10)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if onRetryTap != nil, errorLine != nil, !(errorLine ?? "").isEmpty {
                BeamioHaptic.medium()
                onRetryTap?()
            }
        }
    }

    @ViewBuilder
    private func paymentRoutingRow(_ step: PaymentRoutingStepRow) -> some View {
        HStack(alignment: .center, spacing: 6) {
            Group {
                switch step.status {
                case .loading:
                    ProgressView()
                        .scaleEffect(0.55)
                        .tint(lineOk)
                case .success:
                    Text("OK")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(lineOk)
                case .error:
                    Text("NO")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(Color(red: 1, green: 0.54, blue: 0.5))
                case .pending:
                    Text("--")
                        .font(.system(size: 8, design: .monospaced))
                        .foregroundStyle(linePending)
                }
            }
            .frame(width: 16, alignment: .center)
            let line = step.detail.isEmpty ? step.label : "\(step.label) \(step.detail)"
            Text(line)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(rowTextColor(step.status))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private func rowTextColor(_ status: PaymentRoutingStepStatus) -> Color {
        switch status {
        case .error: return Color(red: 1, green: 0.71, blue: 0.66)
        case .pending: return linePending
        case .loading, .success: return lineOk
        }
    }
}

/// Large rotating blue ring while the system NFC sheet is active (all scan flows).
private struct ScanNfcWaitingPanel: View {
    var title: String = "Waiting for NFC"
    var subtitle: String
    private let tint = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)
    private let ringSize: CGFloat = 140
    private let ringLineWidth: CGFloat = 10

    var body: some View {
        RoundedRectangle(cornerRadius: 24)
            .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
            .frame(height: 280)
            .background(RoundedRectangle(cornerRadius: 24).fill(Color.white))
            .overlay {
                VStack(spacing: 18) {
                    Spacer(minLength: 0)
                    ZStack {
                        Circle()
                            .stroke(Color.black.opacity(0.09), lineWidth: ringLineWidth)
                            .frame(width: ringSize, height: ringSize)
                        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: false)) { context in
                            let t = context.date.timeIntervalSinceReferenceDate
                            let degrees = (t * 300).truncatingRemainder(dividingBy: 360)
                            Circle()
                                .trim(from: 0, to: 0.26)
                                .stroke(
                                    tint,
                                    style: StrokeStyle(lineWidth: ringLineWidth, lineCap: .round)
                                )
                                .frame(width: ringSize, height: ringSize)
                                .rotationEffect(.degrees(-90 + degrees))
                        }
                    }
                    .frame(width: ringSize, height: ringSize)
                    VStack(spacing: 6) {
                        Text(title)
                            .font(.system(size: 18, weight: .semibold))
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 20)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 20)
            }
    }
}

private struct ScanSheet: View {
    @ObservedObject var vm: POSViewModel
    let action: ScanPendingAction
    @Environment(\.displayScale) private var displayScale
    @State private var qrArmed = false
    @State private var linkUrlCopied = false

    /// Charge: hide segmented control & bottom total while routing / QR parse / errors / success (align Android `ScanMethodSelectionScreen`).
    private var chargeChromeHidden: Bool {
        guard action == .payment else { return false }
        if !vm.chargeUsdcDeepLink.isEmpty { return true }
        if vm.chargeUsdcQrGenerating { return true }
        if vm.chargeApprovedInline != nil { return true }
        if vm.paymentQrInterpreting { return true }
        if let e = vm.chargeNfcReadError, !e.isEmpty { return true }
        if vm.scanMethod == .qr, vm.paymentQrParseError != nil, !(vm.paymentQrParseError ?? "").isEmpty { return true }
        if vm.paymentTerminalError != nil, !(vm.paymentTerminalError ?? "").isEmpty { return true }
        if vm.isNfcBusy, !vm.paymentRoutingSteps.isEmpty { return true }
        return false
    }

    private var showChargeQrApproved: Bool {
        action == .payment && vm.chargeApprovedInline != nil
    }

    /// Top-up: hide method bar & bottom total while signing / QR or NFC error card (Android `ScanMethodSelectionScreen`).
    private var topupQrChromeHidden: Bool {
        guard action == .topup else { return false }
        if let e = vm.topupNfcReadError, !e.isEmpty { return true }
        guard vm.scanMethod == .qr else { return false }
        if vm.topupQrSigningInProgress { return true }
        if let e = vm.topupQrExecuteError, !e.isEmpty { return true }
        return false
    }

    /// Check Balance + QR: hide segmented control while loading / error (Android read `nfcFetchingInfo` + error card).
    private var readQrChromeHidden: Bool {
        guard action == .read, vm.scanMethod == .qr else { return false }
        if vm.readQrFetchingInProgress { return true }
        if let e = vm.readQrExecuteError, !e.isEmpty { return true }
        return false
    }

    private var scanBottomCaptionHidden: Bool {
        chargeChromeHidden || topupQrChromeHidden || readQrChromeHidden
    }

    private static let scanOverlayTopUpBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xF0 / 255)
    private static let scanOverlayLabelGray = Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255)

    /// Android scan bottom overlay: subtotal + tax + tip (tier discount unknown before tap → 0).
    private var scanBottomMoneyValue: Double {
        let subtot = Double(vm.amountString) ?? 0
        switch action {
        case .payment:
            guard subtot > 0 else { return 0 }
            let taxP = vm.infraRoutingTaxPercent ?? 0
            let tip = BeamioPaymentRouting.chargeTipFromRequestAndBps(requestAmount: subtot, tipRateBps: vm.chargeTipRateBps)
            return BeamioPaymentRouting.chargeTotalInCurrency(
                requestAmount: subtot,
                taxPercent: taxP,
                tierDiscountPercent: 0,
                tipAmount: tip
            )
        case .topup:
            if let t = vm.topupExecuteDisplayTotal, t > 0 { return t }
            return subtot
        default:
            return 0
        }
    }

    private var scanBottomShowsAmountChrome: Bool {
        !scanBottomCaptionHidden && (action == .payment || action == .topup)
    }

    var body: some View {
        VStack(spacing: 0) {
            if !showChargeQrApproved {
                HStack(alignment: .center, spacing: 8) {
                    SheetCircularBackButton(action: { vm.closeScanSheet() })
                    Spacer(minLength: 8)
                    Text(navTitle)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
                .safeAreaPadding(.top, 6)
            }

            VStack(spacing: 16) {
                Group {
                    if showChargeQrApproved, let state = vm.chargeApprovedInline {
                        PaymentSuccessView(
                            state: state,
                            onDone: { vm.dismissChargeApprovedInline() },
                            onContinueRemainingCharge: nil
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        chargeOrReadCenterBlock
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                if scanBottomShowsAmountChrome {
                    VStack(spacing: 4) {
                        Text(action == .payment ? "Total Amount" : "Top-Up Amount")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(action == .topup ? Self.scanOverlayTopUpBlue : Self.scanOverlayLabelGray)
                        Text("$\(formatUsdAmountScanOverlay(scanBottomMoneyValue))")
                            .font(.system(size: 52, weight: .semibold))
                            .foregroundStyle(action == .topup ? Self.scanOverlayTopUpBlue : Color.black)
                        if action == .topup, let b = vm.topupExecuteDisplayBonus, b > 1e-6 {
                            Text("Bonus $\(formatUsdAmountScanOverlay(b))")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(Color(red: 0xEC / 255, green: 0x48 / 255, blue: 0x99 / 255))
                        }
                    }
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            qrArmed = false
            if vm.scanMethod == .qr {
                Task { @MainActor in
                    let ok = await vm.requestCameraIfNeeded()
                    if ok {
                        qrArmed = true
                    } else {
                        vm.setScanMethod(.nfc)
                    }
                }
            }
        }
        .onChange(of: vm.linkDeepLink) { _, _ in
            linkUrlCopied = false
        }
        .onChange(of: vm.topupUsdcDeepLink) { _, _ in
            linkUrlCopied = false
        }
        .onChange(of: vm.chargeUsdcDeepLink) { _, _ in
            linkUrlCopied = false
        }
        .onChange(of: linkUrlCopied) { _, copied in
            guard copied else { return }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                linkUrlCopied = false
            }
        }
    }

    @ViewBuilder
    private var chargeOrReadCenterBlock: some View {
        if action == .payment {
            paymentScanCenterContent
        } else if action == .topup {
            topupScanCenterContent
        } else if action == .read {
            readBalanceCenterContent
        } else {
            defaultScanCenterContent
        }
    }

    /// Top-up: same branch order as Check Balance — NFC wait → loading → errors → live QR after NFC dismiss / fallback → placeholder.
    @ViewBuilder
    private var topupScanCenterContent: some View {
        let nfcLoading = vm.pendingScanAction == .topup && vm.isNfcBusy
        if !vm.topupUsdcDeepLink.isEmpty {
            usdcTopupCustomerQrBlock(url: vm.topupUsdcDeepLink)
                .padding(.horizontal)
        } else if vm.scanAwaitingNfcTap && vm.scanMethod == .nfc && !vm.topupQrSigningInProgress && !nfcLoading {
            ScanNfcWaitingPanel(
                subtitle: "Hold the customer's card near the top of your iPhone."
            )
            .padding(.horizontal)
        } else if nfcLoading || vm.topupQrSigningInProgress {
            let topupBonusPink = Color(red: 0xEC / 255, green: 0x48 / 255, blue: 0x99 / 255)
            let showTopupTotals = (vm.topupExecuteDisplayTotal ?? 0) > 0
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: showTopupTotals ? 330 : 280)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255))
                            .padding(.bottom, 16)
                        if showTopupTotals, let tot = vm.topupExecuteDisplayTotal {
                            VStack(spacing: 4) {
                                Text("Total credit")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(Self.scanOverlayLabelGray)
                                Text("$\(formatUsdAmountScanOverlay(tot))")
                                    .font(.system(size: 30, weight: .semibold))
                                    .foregroundStyle(Self.scanOverlayTopUpBlue)
                                    .minimumScaleFactor(0.65)
                                    .lineLimit(1)
                                if let b = vm.topupExecuteDisplayBonus, b > 1e-6 {
                                    Text("Bonus $\(formatUsdAmountScanOverlay(b))")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(topupBonusPink)
                                }
                            }
                            .multilineTextAlignment(.center)
                            .padding(.bottom, 12)
                        }
                        VStack(spacing: 4) {
                            Text(vm.topupQrSigningInProgress ? "Sign & execute" : "Loading...")
                                .font(.system(size: 18, weight: .semibold))
                            if vm.topupQrSigningInProgress, !vm.topupQrCustomerHint.isEmpty {
                                Text(vm.topupQrCustomerHint)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.secondary)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                            }
                            Text(
                                vm.topupQrSigningInProgress
                                    ? "Completing top-up…"
                                    : (vm.scanBanner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Completing top-up…" : vm.scanBanner)
                            )
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(24)
                }
                .padding(.horizontal)
        } else if let topupErr = vm.topupQrExecuteError, !topupErr.isEmpty {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 8) {
                        Text(topupErr)
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0xef / 255, green: 0x44 / 255, blue: 0x44 / 255))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                        Text("Tap the center area to retry")
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                            .padding(.bottom, 8)
                    }
                    .padding(16)
                }
                .padding(.horizontal)
                .onTapGesture {
                    BeamioHaptic.medium()
                    vm.retryTopupQrExecute()
                }
        } else if let topupNfcErr = vm.topupNfcReadError, !topupNfcErr.isEmpty {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 8) {
                        Text(topupNfcErr)
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0xef / 255, green: 0x44 / 255, blue: 0x44 / 255))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                        Text(
                            vm.scanMethod == .nfc
                                ? "Tap the center area to try reading the NFC card again."
                                : "Tap the center area to try again"
                        )
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                            .padding(.bottom, 8)
                    }
                    .padding(16)
                }
                .padding(.horizontal)
                .onTapGesture {
                    BeamioHaptic.medium()
                    vm.retryTopupNfcAfterScanBannerError()
                }
        } else if vm.scanMethod == .nfc, !vm.scanAwaitingNfcTap, !vm.isNfcBusy, !vm.scanBanner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 8) {
                        Text(vm.scanBanner)
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0xef / 255, green: 0x44 / 255, blue: 0x44 / 255))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                        Text("Tap the center area to try again")
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                            .padding(.bottom, 8)
                    }
                    .padding(16)
                }
                .padding(.horizontal)
                .onTapGesture {
                    BeamioHaptic.medium()
                    vm.retryTopupNfcAfterScanBannerError()
                }
        } else if vm.scanMethod == .qr, qrArmed || vm.scanQrCameraArmed {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white))
                .overlay {
                    BeamioQRScannerView { text in
                        Task { await vm.onQrScanned(text) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .padding(6)
                    .frame(height: 268)
                }
                .padding(.horizontal)
                .id(vm.topupQrResetId)
        } else if vm.scanMethod == .qr {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white))
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary.opacity(0.25))
                        Text("Open camera to scan customer link")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal)
        } else {
            ScanNfcWaitingPanel(
                subtitle: "Hold the customer's card near the top of your iPhone."
            )
            .padding(.horizontal)
        }
    }

    /// Check Balance: closed QR-style panel while system NFC runs; loading after tag read; live camera only after NFC dismissed or armed.
    @ViewBuilder
    private var readBalanceCenterContent: some View {
        let nfcLoading = vm.pendingScanAction == .read && vm.isNfcBusy
        if vm.scanAwaitingNfcTap && vm.scanMethod == .nfc && !vm.readQrFetchingInProgress && !nfcLoading {
            ScanNfcWaitingPanel(
                subtitle: "Hold the customer's card near the top of your iPhone."
            )
            .padding(.horizontal)
        } else if vm.readQrFetchingInProgress || nfcLoading {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255))
                            .padding(.bottom, 20)
                        VStack(spacing: 4) {
                            Text("Loading...")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Fetching card info.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(24)
                }
                .padding(.horizontal)
        } else if let readErr = vm.readQrExecuteError, !readErr.isEmpty {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 8) {
                        Text(readErr)
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0xef / 255, green: 0x44 / 255, blue: 0x44 / 255))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                        Text(
                            vm.scanMethod == .nfc
                                ? "Tap the center area to try reading the NFC card again."
                                : "Tap the center area to try again"
                        )
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                            .padding(.bottom, 8)
                    }
                    .padding(16)
                }
                .padding(.horizontal)
                .onTapGesture {
                    BeamioHaptic.medium()
                    vm.retryReadQrAfterError()
                }
        } else if vm.scanMethod == .qr, vm.scanQrCameraArmed {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white))
                .overlay {
                    BeamioQRScannerView { text in
                        Task { await vm.onQrScanned(text) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .padding(6)
                    .frame(height: 268)
                }
                .padding(.horizontal)
                .id(vm.readQrResetId)
        } else {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white))
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary.opacity(0.25))
                        Text("Open camera to scan customer link")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal)
        }
    }

    /// Charge (NFC + QR): NFC wait panel matches Check Balance (`ScanNfcWaitingPanel`); then QR / routing / errors.
    /// USDC charge bypasses NFC entirely — `chargeUsdcQrGenerating` shows a "Generating QR…" placeholder while the
    /// `cardOwner` lookup runs, then the QR replaces it once `chargeUsdcDeepLink` is set.
    @ViewBuilder
    private var paymentScanCenterContent: some View {
        if !vm.chargeUsdcDeepLink.isEmpty {
            usdcChargeCustomerQrBlock(url: vm.chargeUsdcDeepLink)
                .padding(.horizontal)
        } else if vm.chargeUsdcQrGenerating {
            usdcChargeQrGeneratingBlock
                .padding(.horizontal)
        } else if vm.paymentQrInterpreting {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255))
                            .padding(.bottom, 20)
                        VStack(spacing: 4) {
                            Text("Processing…")
                                .font(.system(size: 18, weight: .semibold))
                            Text("Reading payment code.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.top, 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(24)
                }
                .padding(.horizontal)
        } else if let chargeNfcErr = vm.chargeNfcReadError, !chargeNfcErr.isEmpty {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 8) {
                        Text(chargeNfcErr)
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0xef / 255, green: 0x44 / 255, blue: 0x44 / 255))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                        Text(
                            vm.scanMethod == .nfc
                                ? "Tap the center area to try reading the NFC card again."
                                : "Tap the center area to try again"
                        )
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                            .padding(.bottom, 8)
                    }
                    .padding(16)
                }
                .padding(.horizontal)
                .onTapGesture {
                    BeamioHaptic.medium()
                    vm.retryPaymentNfcAfterScanBannerError()
                }
        } else if vm.scanMethod == .qr, let parseErr = vm.paymentQrParseError, !parseErr.isEmpty {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 8) {
                        Text(parseErr)
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0xef / 255, green: 0x44 / 255, blue: 0x44 / 255))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                        Text("Tap the center area to scan again")
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                            .padding(.bottom, 8)
                    }
                    .padding(16)
                }
                .padding(.horizontal)
                .onTapGesture {
                    BeamioHaptic.medium()
                    vm.retryPaymentQrParse()
                }
        } else if let termErr = vm.paymentTerminalError, !termErr.isEmpty {
            PaymentRoutingMonitorCard(
                steps: vm.paymentRoutingSteps,
                errorLine: termErr,
                retryHint: "Tap center to retry",
                onRetryTap: { vm.retryPaymentAfterTerminalError() }
            )
            .frame(width: 280, height: 280)
            .padding(.horizontal)
        } else if vm.isNfcBusy, !vm.paymentRoutingSteps.isEmpty {
            PaymentRoutingMonitorCard(steps: vm.paymentRoutingSteps, errorLine: nil, retryHint: nil, onRetryTap: nil)
                .frame(width: 280, height: 280)
                .padding(.horizontal)
        } else if vm.scanMethod == .nfc, vm.scanAwaitingNfcTap, !vm.isNfcBusy {
            ScanNfcWaitingPanel(
                subtitle: "Hold the customer's card near the top of your iPhone."
            )
            .padding(.horizontal)
        } else if vm.scanMethod == .nfc, !vm.scanAwaitingNfcTap, !vm.isNfcBusy, !vm.scanBanner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 8) {
                        Text(vm.scanBanner)
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0xef / 255, green: 0x44 / 255, blue: 0x44 / 255))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        Spacer()
                        Text("Tap the center area to try again")
                            .font(.subheadline)
                            .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                            .padding(.bottom, 8)
                    }
                    .padding(16)
                }
                .padding(.horizontal)
                .onTapGesture {
                    BeamioHaptic.medium()
                    vm.retryPaymentNfcAfterScanBannerError()
                }
        } else if vm.scanMethod == .qr, qrArmed || vm.scanQrCameraArmed {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white))
                .overlay {
                    BeamioQRScannerView { text in
                        Task { await vm.onQrScanned(text) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .padding(6)
                    .frame(height: 268)
                }
                .padding(.horizontal)
                .id(vm.qrPaymentResetId)
        } else if vm.scanMethod == .qr {
            RoundedRectangle(cornerRadius: 24)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(height: 280)
                .background(RoundedRectangle(cornerRadius: 24).fill(Color.white))
                .overlay {
                    VStack(spacing: 12) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary.opacity(0.25))
                        Text("Open camera to scan payment QR")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
                .padding(.horizontal)
        } else {
            ScanNfcWaitingPanel(
                subtitle: "Hold the customer's card near the top of your iPhone."
            )
            .padding(.horizontal)
        }
    }

    @ViewBuilder
    private var defaultScanCenterContent: some View {
        if action == .linkApp, !vm.linkDeepLink.isEmpty {
            linkAppDeepLinkReadyBlock(url: vm.linkDeepLink)
                .padding(.horizontal)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 24)
                    .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                    .frame(height: 280)
                    .background(RoundedRectangle(cornerRadius: 24).fill(Color.white))

                if vm.scanMethod == .qr, qrArmed || vm.scanQrCameraArmed {
                    BeamioQRScannerView { text in
                        Task { await vm.onQrScanned(text) }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 22))
                    .padding(6)
                    .frame(height: 268)
                } else if vm.scanMethod == .nfc, vm.scanAwaitingNfcTap, !vm.isNfcBusy, !(!vm.linkDeepLink.isEmpty || vm.showLinkCancel) {
                    ScanNfcWaitingPanel(subtitle: placeholderText)
                } else {
                    VStack(spacing: 12) {
                        if vm.isNfcBusy {
                            ProgressView()
                            Text(vm.scanBanner).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        } else if vm.showLinkCancel {
                            Text(vm.scanBanner).foregroundStyle(.red).multilineTextAlignment(.center)
                            Button {
                                Task { await vm.cancelLinkLock() }
                            } label: {
                                Text("Cancel link lock")
                                    .font(.system(size: 14, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .foregroundStyle(.white)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(beamioLinkBlue))
                            }
                            .buttonStyle(BeamioHapticPlainButtonStyle())
                            .disabled(vm.opRunning)
                            .opacity(vm.opRunning ? 0.55 : 1)
                        } else {
                            Image(systemName: "radiowaves.right")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary.opacity(0.3))
                            Text(vm.scanBanner.isEmpty ? placeholderText : vm.scanBanner)
                                .font(.footnote)
                                .multilineTextAlignment(.center)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                    }
                    .frame(height: 260)
                }
            }
            .padding(.horizontal)
        }
    }

    private var beamioSecondaryGray: Color { Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255) }
    private var beamioLinkBlue: Color { Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255) }
    private var beamioSuccessGreen: Color { Color(red: 0x22 / 255, green: 0xc5 / 255, blue: 0x5e / 255) }

    /// Align Android `ScanMethodSelectionScreen` link-app success: 280×280 card + “Link URL” pill + QR + copy/check.
    private func linkAppDeepLinkReadyBlock(url: String) -> some View {
        let qrImage = BeamioLinkAppQr.image(from: url, pointSize: 198, scale: displayScale)
        return VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(width: 280, height: 280)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 0) {
                        Text("Link ready")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.black)
                        Text("Customer opens Beamio app with this link")
                            .font(.system(size: 11))
                            .foregroundStyle(beamioSecondaryGray)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                            .padding(.bottom, 6)
                        if let qrImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 198, height: 198)
                                .padding(.vertical, 2)
                                .accessibilityLabel("Link app QR")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            Button {
                BeamioHaptic.medium()
                UIPasteboard.general.string = url
                linkUrlCopied = true
            } label: {
                HStack(alignment: .center, spacing: 8) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Link URL")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(beamioSecondaryGray)
                        Text(url)
                            .font(.system(size: 12))
                            .foregroundStyle(beamioLinkBlue)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    Group {
                        if linkUrlCopied {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(beamioSuccessGreen)
                                .accessibilityLabel("Copied")
                        } else {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 22))
                                .foregroundStyle(beamioLinkBlue)
                                .accessibilityLabel("Copy link")
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .frame(width: 280)
                .background(Color.white)
                .clipShape(Capsule())
                .overlay(Capsule().stroke(Color.black.opacity(0.12), lineWidth: 1))
            }
            .buttonStyle(.plain)
        }
    }

    /// USDC top-up: after NFC tap, present a QR pointing at `verra-home/usdc-topup` so the customer signs the EIP-3009 USDC transfer in their own wallet (admin signs `ExecuteForAdmin` on the back-end after settlement).
    private func usdcTopupCustomerQrBlock(url: String) -> some View {
        let qrImage = BeamioLinkAppQr.image(from: url, pointSize: 198, scale: displayScale)
        return VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(width: 280, height: 320)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 0) {
                        Text("Scan to pay USDC")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.black)
                        Text("Open in your crypto wallet's browser to confirm")
                            .font(.system(size: 11))
                            .foregroundStyle(beamioSecondaryGray)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                            .padding(.bottom, 6)
                        if let qrImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 198, height: 198)
                                .padding(.vertical, 2)
                                .accessibilityLabel("USDC top-up payment QR")
                        }
                        if !vm.topupQrCustomerHint.isEmpty {
                            Text(vm.topupQrCustomerHint)
                                .font(.system(size: 11))
                                .foregroundStyle(beamioSecondaryGray)
                                .multilineTextAlignment(.center)
                                .padding(.top, 6)
                                .padding(.horizontal, 8)
                        }
                        if !vm.topupUsdcSessionProgressLabel.isEmpty {
                            Text(vm.topupUsdcSessionProgressLabel)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(beamioLinkBlue)
                                .multilineTextAlignment(.center)
                                .padding(.top, 4)
                                .padding(.horizontal, 8)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            HStack(spacing: 8) {
                Button {
                    BeamioHaptic.medium()
                    UIPasteboard.general.string = url
                    linkUrlCopied = true
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Payment URL")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(beamioSecondaryGray)
                            Text(url)
                                .font(.system(size: 12))
                                .foregroundStyle(beamioLinkBlue)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Group {
                            if linkUrlCopied {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(beamioSuccessGreen)
                                    .accessibilityLabel("Copied")
                            } else {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 22))
                                    .foregroundStyle(beamioLinkBlue)
                                    .accessibilityLabel("Copy link")
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(width: 280)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.black.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button {
                BeamioHaptic.medium()
                vm.cancelTopupUsdcQr()
            } label: {
                Text("Cancel & rescan")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 280)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 12).fill(beamioLinkBlue))
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())
        }
    }

    /// Loading placeholder shown between `Confirm & Pay` (USDC) and the QR being ready: the merchant should never see
    /// the legacy NFC waiting panel for a USDC charge. Frame matches `usdcChargeCustomerQrBlock` so the swap is seamless.
    private var usdcChargeQrGeneratingBlock: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(width: 280, height: 320)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 14) {
                        Text("Generating USDC payment QR…")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.black)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 16)
                        ProgressView()
                            .scaleEffect(1.2)
                            .tint(beamioLinkBlue)
                        Text("Hand the customer's QR over after it appears — no NFC card needed.")
                            .font(.system(size: 11))
                            .foregroundStyle(beamioSecondaryGray)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18)
                    }
                    .padding(.vertical, 18)
                }
            Button {
                BeamioHaptic.medium()
                vm.cancelChargeUsdcQr()
            } label: {
                Text("Cancel")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 280)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 12).fill(beamioLinkBlue))
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())
        }
    }

    /// USDC charge QR (no-NFC): customer scans with any third-party Web3 wallet to sign the EIP-3009 USDC transfer
    /// straight into the merchant BeamioUserCard's adminEOA. No NFC tap, no @beamioTag — pure off-chain wallet flow.
    private func usdcChargeCustomerQrBlock(url: String) -> some View {
        let qrImage = BeamioLinkAppQr.image(from: url, pointSize: 198, scale: displayScale)
        return VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 32)
                .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                .frame(width: 280, height: 320)
                .background(RoundedRectangle(cornerRadius: 32).fill(Color.white))
                .overlay {
                    VStack(spacing: 0) {
                        Text("Scan to pay USDC")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Color.black)
                        Text("Open in your crypto wallet's browser to confirm")
                            .font(.system(size: 11))
                            .foregroundStyle(beamioSecondaryGray)
                            .multilineTextAlignment(.center)
                            .padding(.top, 4)
                            .padding(.bottom, 6)
                        if let qrImage {
                            Image(uiImage: qrImage)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 198, height: 198)
                                .padding(.vertical, 2)
                                .accessibilityLabel("USDC charge payment QR")
                        }
                        if !vm.chargeQrCustomerHint.isEmpty {
                            Text(vm.chargeQrCustomerHint)
                                .font(.system(size: 11))
                                .foregroundStyle(beamioSecondaryGray)
                                .multilineTextAlignment(.center)
                                .padding(.top, 6)
                                .padding(.horizontal, 8)
                        }
                        // PR #4: 编排器中间态进度（USDC 已 settle → topup → charge）。Empty ⇒ 顾客还没付 / 已 terminal，无需显示。
                        // 显示在客户提示之下，作为"系统正在推进"的非阻塞反馈，避免 merchant 误以为 QR 卡死。
                        if !vm.chargeUsdcSessionProgressLabel.isEmpty {
                            HStack(spacing: 6) {
                                ProgressView()
                                    .scaleEffect(0.7)
                                    .tint(beamioLinkBlue)
                                Text(vm.chargeUsdcSessionProgressLabel)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(beamioLinkBlue)
                                    .multilineTextAlignment(.center)
                            }
                            .padding(.top, 4)
                            .padding(.horizontal, 8)
                            .accessibilityLabel("Payment progress: \(vm.chargeUsdcSessionProgressLabel)")
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
            HStack(spacing: 8) {
                Button {
                    BeamioHaptic.medium()
                    UIPasteboard.general.string = url
                    linkUrlCopied = true
                } label: {
                    HStack(alignment: .center, spacing: 8) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Payment URL")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(beamioSecondaryGray)
                            Text(url)
                                .font(.system(size: 12))
                                .foregroundStyle(beamioLinkBlue)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 0)
                        Group {
                            if linkUrlCopied {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 22))
                                    .foregroundStyle(beamioSuccessGreen)
                                    .accessibilityLabel("Copied")
                            } else {
                                Image(systemName: "doc.on.doc")
                                    .font(.system(size: 22))
                                    .foregroundStyle(beamioLinkBlue)
                                    .accessibilityLabel("Copy link")
                            }
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .frame(width: 280)
                    .background(Color.white)
                    .clipShape(Capsule())
                    .overlay(Capsule().stroke(Color.black.opacity(0.12), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Button {
                BeamioHaptic.medium()
                vm.cancelChargeUsdcQr()
            } label: {
                Text("Cancel")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 280)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 12).fill(beamioLinkBlue))
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())
        }
    }

    private var navTitle: String {
        switch action {
        case .read: return "Check Balance"
        case .topup: return "Top-Up"
        case .payment: return "Charge"
        case .linkApp: return "Link App"
        }
    }

    private var placeholderText: String {
        switch action {
        case .read: return "Hold the customer's card near the top of the iPhone."
        case .topup: return "Hold the customer's card near the top of your iPhone."
        case .payment: return "Hold the customer's card near the top of your iPhone."
        case .linkApp: return "Hold the customer's card to create a link."
        }
    }
}

#Preview {
    ContentView()
}
