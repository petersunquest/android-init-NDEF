//
//  ContentView.swift
//  iOS_NDEF
//
//  Beamio POS: welcome / onboarding / home / amount / tip / NFC+QR scan (aligns with Android MainActivity flows).
//

import SwiftUI
import UIKit
import CoreImage

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

private enum BeamioHaptic {
    static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle) {
        let g = UIImpactFeedbackGenerator(style: style)
        g.prepare()
        g.impactOccurred()
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

    var body: some View {
        ZStack {
            Group {
                if vm.showWelcome {
                    WelcomeView(onCreateWallet: { vm.goCreateWallet() })
                } else if vm.showOnboarding {
                    OnboardingView(
                        vm: vm,
                        onBack: { vm.showWelcome = true; vm.showOnboarding = false }
                    )
                } else {
                    HomeRootView(vm: vm, amountFlow: $amountFlow)
                }
            }

            if vm.showLaunchSplash {
                LaunchBrandSplashOverlay()
                    .transition(.opacity)
                    .zIndex(0.9)
            }

            if let s = vm.sheet {
                SheetHost(vm: vm, sheet: s, amountFlow: $amountFlow)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .animation(.easeOut(duration: 0.22), value: vm.showLaunchSplash)
        .animation(.easeInOut(duration: 0.32), value: vm.sheet?.id)
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
        .sheet(item: $amountFlow) { flow in
            Group {
                switch flow {
                case .charge:
                    ChargeAmountTipNavigationSheet(
                        onCancel: { amountFlow = nil },
                        onChargeComplete: { amount, tipBps in
                            amountFlow = nil
                            vm.beginCharge(amount: amount, tipBps: tipBps)
                        }
                    )
                case .topup:
                    AmountPadSheet(
                        title: "Top-Up Amount",
                        continueTint: Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255),
                        onCancel: { amountFlow = nil },
                        onContinue: { value in
                            amountFlow = nil
                            vm.amountString = value
                            vm.beginTopUp()
                        }
                    )
                }
            }
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
        .sheet(isPresented: Binding(
            get: { vm.pendingRecoveryCode != nil },
            set: { if !$0 { vm.pendingRecoveryCode = nil } }
        )) {
            RecoveryKeySheet(code: vm.pendingRecoveryCode ?? "")
        }
    }
}

/// Matches `LaunchScreen.storyboard`: centered brand mark until Home is ready.
private struct LaunchBrandSplashOverlay: View {
    private let brandBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)

    var body: some View {
        ZStack {
            Color(uiColor: .systemBackground)
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Image("LaunchBrandLogo")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 120, height: 120)
                ProgressView()
                    .controlSize(.large)
                    .tint(brandBlue)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Loading")
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
    var id: String { rawValue }
}

// MARK: - Welcome / Onboarding

private struct WelcomeView: View {
    var onCreateWallet: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            Text("VERRA POS")
                .font(.title.bold())
            Text("Hold customer NTAG cards or scan QR for payments.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Spacer()
            Button(action: onCreateWallet) {
                Text("Continue")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(red: 0.08, green: 0.38, blue: 0.94))
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
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
        ZStack {
            Color.white.ignoresSafeArea()
            VStack(spacing: 28) {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(brandBlue)
                VStack(spacing: 10) {
                    Text("Creating your business workspace…")
                        .font(.title2.weight(.heavy))
                        .multilineTextAlignment(.center)
                    Text("We're preparing your business identity and getting your Verra workspace ready.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("This usually takes a few seconds.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 24)
            }
        }
        .allowsHitTesting(true)
    }
}

private struct RecoveryKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    let code: String

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                Text("Save your recovery key")
                    .font(.headline)
                Text("Store it offline. You need it with your password for QR restore on Verra Business (empty PIN) or username restore.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(code)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color(uiColor: .secondarySystemBackground)))
                Button("Copy to clipboard") {
                    BeamioHaptic.medium()
                    UIPasteboard.general.string = code
                }
                .buttonStyle(.borderedProminent)
                Spacer()
            }
            .padding()
            .navigationTitle("Recovery key")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") {
                        BeamioHaptic.light()
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - Home (align Android `NdefScreen`)

private struct HomeRootView: View {
    @ObservedObject var vm: POSViewModel
    @Binding var amountFlow: AmountFlow?
    @State private var walletCopied = false

    private let linkPurple = Color(red: 124 / 255, green: 58 / 255, blue: 237 / 255)
    private let brandBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)
    private let mintGreen = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)

    var body: some View {
        GeometryReader { geo in
            // Cap top scroll so dashboard/welcome cannot consume the full screen; remainder goes to four action rows (Android `weight(1f)`).
            let scrollMax = max(160, geo.size.height * 0.36)
            VStack(alignment: .leading, spacing: 0) {
                homeTopHeader
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.vertical, 8)
                if vm.homePullRefreshing {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading latest data…")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 16)
                    .background(Color(uiColor: .secondarySystemGroupedBackground))
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        dashboardBlackCard
                            .padding(.horizontal, 16)
                        if vm.hasAAAccount == false {
                            homeWelcomeNoAA
                                .padding(.horizontal, 16)
                        }
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 8)
                }
                .scrollBounceBehavior(.always, axes: .vertical)
                .frame(maxWidth: .infinity, maxHeight: scrollMax, alignment: .top)
                .refreshable {
                    await vm.refreshHomeProfilesPullToRefresh()
                }
                VStack(spacing: 8) {
                    homeActionRow(
                        title: "Link App",
                        subtitle: "Scan customer card to link",
                        systemImage: "link",
                        iconBackground: linkPurple.opacity(0.1),
                        iconTint: linkPurple,
                        iconCorner: 10
                    ) { vm.beginLinkApp() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    homeActionRow(
                        title: "Charge",
                        subtitle: "Accept NFC or QR code",
                        systemImage: "qrcode",
                        iconBackground: brandBlue.opacity(0.1),
                        iconTint: brandBlue,
                        iconCorner: 10
                    ) { amountFlow = .charge }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    homeActionRow(
                        title: "Top-Up / Mint",
                        subtitle: "Load balance or new card",
                        systemImage: "plus",
                        iconBackground: mintGreen.opacity(0.2),
                        iconTint: mintGreen,
                        iconCorner: 20
                    ) { amountFlow = .topup }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    homeActionRow(
                        title: "Check Balance",
                        subtitle: "Read member profile",
                        systemImage: "magnifyingglass",
                        iconBackground: Color(red: 0xf4 / 255, green: 0xf4 / 255, blue: 0xf5 / 255),
                        iconTint: .primary,
                        iconCorner: 20
                    ) { vm.beginReadBalance() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .background(Color(uiColor: .systemGroupedBackground))
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
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            if let admin = vm.adminProfile {
                HomeBeamioCapsuleCompact(profile: admin, fallbackAddress: admin.address)
            }
        }
    }

    /// Android `NdefScreen` title line: `@accountName` else `"\(first6)…\(last4)"` else `"Terminal"`.
    private var homeHeaderTitleLine: String {
        let tag = sanitizeProfilePart(vm.terminalProfile?.accountName)
        if !tag.isEmpty { return "@\(tag)" }
        if let a = vm.walletAddress { return homeHeaderWalletShortLine(a) }
        return "Terminal"
    }

    private var dashboardBlackCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                chargesColumn
                    .frame(maxWidth: .infinity, alignment: .leading)
                Rectangle()
                    .fill(Color.white.opacity(0.1))
                    .frame(width: 1, height: 88)
                topUpsColumn
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            if let trimmed = vm.homeMerchantProgramCardName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty {
                Text(trimmed)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.88))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
            }
            taxAndTierRow
                .padding(.top, 10)
            HStack {
                if let w = vm.walletAddress {
                    let short = homeShortAddr(w)
                    Button {
                        vm.copyWalletToPasteboard()
                        walletCopied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                            walletCopied = false
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text("ID: \(short)")
                                .font(.system(size: 12, weight: .medium))
                            Image(systemName: walletCopied ? "checkmark" : "doc.on.doc")
                                .font(.system(size: 13))
                                .foregroundStyle(walletCopied ? Color.green : .white.opacity(0.85))
                        }
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(BeamioHapticPlainButtonStyle())
                }
                Spacer()
                HStack(spacing: 6) {
                    Image(systemName: "shield.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(brandBlue)
                    Text("SECURED")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .padding(.top, 10)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.black))
    }

    private var chargesColumn: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                ZStack {
                    Circle().fill(brandBlue.opacity(0.2)).frame(width: 18, height: 18)
                    Image(systemName: "arrow.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(brandBlue)
                }
                Text("Charges")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
                Text("Today")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(brandBlue)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .background(RoundedRectangle(cornerRadius: 4).fill(brandBlue.opacity(0.15)))
            }
            homeDashboardAmount(chargesSide: true)
        }
    }

    private var topUpsColumn: some View {
        VStack(alignment: .trailing, spacing: 4) {
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                ZStack {
                    Circle().fill(mintGreen.opacity(0.2)).frame(width: 18, height: 18)
                    Image(systemName: "arrow.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(mintGreen)
                }
                Text("Top-Ups")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            homeDashboardAmount(chargesSide: false)
        }
    }

    private func homeDashboardAmount(chargesSide: Bool) -> some View {
        Group {
            if chargesSide {
                if !vm.homeStatsLoaded {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                        .frame(height: 44)
                } else if let v = vm.cardChargeAmount {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text("$")
                            .font(.system(size: 22, weight: .semibold))
                        Text(formatDashboardMain(v))
                            .font(.system(size: 44, weight: .semibold))
                        Text(formatDashboardDec(v))
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .foregroundStyle(.white)
                } else {
                    Text("—")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                }
            } else {
                if !vm.homeStatsLoaded {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.85)
                        .frame(height: 44)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                } else if let v = vm.cardTopUpAmount {
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text("$")
                            .font(.system(size: 22, weight: .semibold))
                        Text(formatDashboardMain(v))
                            .font(.system(size: 44, weight: .semibold))
                        Text(formatDashboardDec(v))
                            .font(.system(size: 14))
                            .foregroundStyle(Color.white.opacity(0.55))
                    }
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                } else {
                    Text("—")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.5))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
    }

    private func formatDashboardMain(_ v: Double) -> String {
        let s = String(format: "%.2f", v)
        guard let dot = s.firstIndex(of: ".") else { return s }
        return String(s[..<dot])
    }

    private func formatDashboardDec(_ v: Double) -> String {
        let s = String(format: "%.2f", v)
        guard let dot = s.firstIndex(of: ".") else { return "" }
        return String(s[dot...])
    }

    private var taxAndTierRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Spacer(minLength: 0)
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(brandBlue.opacity(0.22))
                        .frame(width: 24, height: 24)
                    Image(systemName: "square.3.layers.3d")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(brandBlue)
                }
                Text(vm.infraRoutingDiscountSummary ?? "—")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .multilineTextAlignment(.trailing)
            }
        }
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
        }
        .buttonStyle(BeamioHapticPlainButtonStyle())
    }

    private func homeShortAddr(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 10 else { return t }
        return "\(t.prefix(5))...\(t.suffix(5))"
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

/// Android `BeamioCapsuleCompact`: avatar + displayName + @tag
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
                } else if !hasName {
                    Text(shortFallback ?? "—")
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

/// Charge: single sheet, amount root → push tip (`NavigationStack` slide-from-trailing). Avoids closing one `.sheet` and opening another (race left `tipSubtotal` as `"0"`).
private struct ChargeAmountTipNavigationSheet: View {
    var onCancel: () -> Void
    var onChargeComplete: (String, Int) -> Void

    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            AmountPadSheet(
                title: "Charge Amount",
                continueTint: .black,
                embedNavigation: false,
                onCancel: onCancel,
                onContinue: { value in
                    path.append(value)
                }
            )
            .navigationTitle("Charge Amount")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        BeamioHaptic.light()
                        onCancel()
                    }
                }
            }
            .navigationDestination(for: String.self) { subtotal in
                TipFlowPage(subtotal: subtotal) { tipBps in
                    onChargeComplete(subtotal, tipBps)
                }
            }
        }
        .onAppear { path = NavigationPath() }
    }
}

private struct AmountPadSheet: View {
    var title: String
    var continueTint: Color
    /// When `false`, omit inner `NavigationStack` — parent supplies bar (Charge → Tip stack).
    var embedNavigation: Bool = true
    var onCancel: () -> Void
    var onContinue: (String) -> Void

    @State private var amount = "0"

    private var core: some View {
        VStack(spacing: 24) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text("$")
                    .font(.title)
                    .foregroundStyle(.secondary)
                Text(amount)
                    .font(.system(size: 56, weight: .light, design: .rounded))
            }
            .padding(.top, 8)
            keypad
            Button {
                onContinue(amount)
            } label: {
                Text("Continue")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(RoundedRectangle(cornerRadius: 12).fill(continueTint))
                    .foregroundStyle(.white)
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())
            .disabled(!canContinue)
            .opacity(canContinue ? 1 : 0.45)
            .padding(.bottom)
        }
        .padding(.horizontal)
    }

    var body: some View {
        Group {
            if embedNavigation {
                NavigationStack {
                    core
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Cancel") {
                                    BeamioHaptic.light()
                                    onCancel()
                                }
                            }
                        }
                }
            } else {
                core
            }
        }
    }

    private var canContinue: Bool {
        guard let v = Double(amount) else { return false }
        return v > 0
    }

    private var keypad: some View {
        VStack(spacing: 16) {
            ForEach(rows, id: \.self) { row in
                HStack(spacing: 16) {
                    ForEach(row, id: \.self) { key in
                        Button {
                            tap(key)
                        } label: {
                            Group {
                                if key == "⌫" {
                                    Image(systemName: "delete.left")
                                } else {
                                    Text(key).font(.title2)
                                }
                            }
                            .frame(width: 72, height: 72)
                            .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)))
                        }
                        .buttonStyle(BeamioHapticPlainButtonStyle(impact: .light))
                    }
                }
            }
        }
    }

    private let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], [".", "0", "⌫"]]

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

// MARK: - Tip (pushed inside `ChargeAmountTipNavigationSheet`)

private struct TipFlowPage: View {
    var subtotal: String
    var onConfirm: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selected: Double = 0

    /// Same as Read Balance `Top-Up Card Now` / AmountPad top-up primary.
    private let primaryBlue = Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)

    private var num: Double { Double(subtotal) ?? 0 }

    var body: some View {
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
                HStack(spacing: 6) {
                    Text("Confirm & Pay")
                        .font(.system(size: 14, weight: .semibold))
                    Image(systemName: "chevron.right")
                        .font(.system(size: 14, weight: .semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: 12).fill(primaryBlue))
                .foregroundStyle(.white)
            }
            .buttonStyle(BeamioHapticPlainButtonStyle())
            Spacer()
        }
        .padding()
        .navigationTitle("Add Tip")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Back") {
                    BeamioHaptic.light()
                    dismiss()
                }
            }
        }
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
        let shortTx = state.txHash.isEmpty ? "—" : topupShortTx(state.txHash)
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
                Text(shortTx)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(onSurface)
                    .lineLimit(1)
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
                                        topupReceiptRow(left: "TX Hash", right: topupShortTx(state.txHash), rightBlue: true)
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

                if !scanBottomCaptionHidden {
                    Text(bottomCaption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
        if vm.scanAwaitingNfcTap && vm.scanMethod == .nfc && !vm.topupQrSigningInProgress && !nfcLoading {
            ScanNfcWaitingPanel(
                subtitle: "Hold the customer's card near the top of your iPhone."
            )
            .padding(.horizontal)
        } else if nfcLoading || vm.topupQrSigningInProgress {
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
    @ViewBuilder
    private var paymentScanCenterContent: some View {
        if vm.paymentQrInterpreting {
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

    private var bottomCaption: String {
        switch action {
        case .payment: return "Total with tip: $\(vm.amountString)"
        case .topup: return "Amount: $\(vm.amountString)"
        default: return ""
        }
    }
}

#Preview {
    ContentView()
}
