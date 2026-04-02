//
//  ContentView.swift
//  iOS_NDEF
//
//  Beamio POS: welcome / onboarding / home / amount / tip / NFC+QR scan (aligns with Android MainActivity flows).
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var vm = POSViewModel()
    @State private var amountFlow: AmountFlow?
    @State private var showTipSheet = false
    @State private var tipSubtotal: String = "0"
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

            if let s = vm.sheet {
                SheetHost(vm: vm, sheet: s, amountFlow: $amountFlow)
                    .transition(.move(edge: .trailing))
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.32), value: vm.sheet?.id)
        .fullScreenCover(item: Binding(
            get: { vm.topupSuccess },
            set: { vm.topupSuccess = $0 }
        )) { state in
            TopupSuccessView(state: state) {
                vm.dismissTopupSuccess()
                Task { await vm.refreshHomeProfiles() }
            }
        }
        .fullScreenCover(item: Binding(
            get: { vm.chargeSuccess },
            set: { vm.chargeSuccess = $0 }
        )) { state in
            PaymentSuccessView(state: state) {
                vm.dismissChargeSuccess()
                Task { await vm.refreshHomeProfiles() }
            }
        }
        .sheet(item: $amountFlow) { flow in
            AmountPadSheet(
                title: flow == .charge ? "Charge Amount" : "Top-Up Amount",
                continueTint: flow == .charge ? .black : Color(red: 0.08, green: 0.38, blue: 0.94),
                onCancel: { amountFlow = nil },
                onContinue: { value in
                    amountFlow = nil
                    switch flow {
                    case .charge:
                        tipSubtotal = value
                        showTipSheet = true
                    case .topup:
                        vm.amountString = value
                        vm.beginTopUp()
                    }
                }
            )
        }
        .sheet(isPresented: $showTipSheet) {
            TipSheet(
                subtotal: tipSubtotal,
                onBack: {
                    showTipSheet = false
                    tipSubtotal = "0"
                },
                onConfirm: { bps in
                    showTipSheet = false
                    let amt = tipSubtotal
                    tipSubtotal = "0"
                    vm.beginCharge(amount: amt, tipBps: bps)
                }
            )
        }
        .onChange(of: vm.homeToast) { _, new in
            toastPresented = new != nil
        }
        .alert("Notice", isPresented: $toastPresented) {
            Button("OK", role: .cancel) { vm.homeToast = nil }
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
        .buttonStyle(.plain)
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
                    Button("Back") { onBack() }
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
                        .buttonStyle(.plain)
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
            .buttonStyle(.plain)
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
                    Button("Done") { dismiss() }
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
                    VStack(spacing: 8) {
                        homeActionRow(
                            title: "Link App",
                            subtitle: "Scan customer card to link",
                            systemImage: "link",
                            iconBackground: linkPurple.opacity(0.1),
                            iconTint: linkPurple,
                            iconCorner: 10
                        ) { vm.beginLinkApp() }
                        homeActionRow(
                            title: "Charge",
                            subtitle: "Accept NFC or QR code",
                            systemImage: "qrcode",
                            iconBackground: brandBlue.opacity(0.1),
                            iconTint: brandBlue,
                            iconCorner: 10
                        ) { amountFlow = .charge }
                        homeActionRow(
                            title: "Top-Up / Mint",
                            subtitle: "Load balance or new card",
                            systemImage: "plus",
                            iconBackground: mintGreen.opacity(0.2),
                            iconTint: mintGreen,
                            iconCorner: 20
                        ) { amountFlow = .topup }
                        homeActionRow(
                            title: "Check Balance",
                            subtitle: "Read member profile",
                            systemImage: "magnifyingglass",
                            iconBackground: Color(red: 0xf4 / 255, green: 0xf4 / 255, blue: 0xf5 / 255),
                            iconTint: .primary,
                            iconCorner: 20
                        ) { vm.beginReadBalance() }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                }
            }
            .refreshable {
                await vm.refreshHomeProfilesPullToRefresh()
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .task {
            await vm.refreshHomeProfiles()
        }
        .task {
            await vm.pollInfraRoutingIfStillOnHome()
        }
    }

    private var homeTopHeader: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "app.fill")
                .font(.system(size: 22))
                .foregroundStyle(brandBlue)
                .frame(width: 40, height: 40)
                .background(Circle().fill(Color(uiColor: .secondarySystemGroupedBackground)))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(displayTagLine)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.primary)
            }
            Spacer(minLength: 8)
            if let admin = vm.adminProfile {
                HomeBeamioCapsuleCompact(profile: admin, fallbackAddress: admin.address)
            }
        }
    }

    private var displayTagLine: String {
        let tag = sanitizeProfilePart(vm.terminalProfile?.accountName)
        if !tag.isEmpty { return "@\(tag)" }
        if let a = vm.walletAddress { return homeShortAddr(a) }
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
                    .buttonStyle(.plain)
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
            HStack(spacing: 6) {
                ZStack {
                    Circle()
                        .fill(Color(red: 1, green: 0.76, blue: 0.03).opacity(0.22))
                        .frame(width: 24, height: 24)
                    Image(systemName: "percent")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color(red: 1, green: 0.76, blue: 0.03))
                }
                Text(vm.infraRoutingTaxPercent.map { String(format: "%.2f%%", $0) } ?? "—")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            Spacer(minLength: 8)
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
            .frame(maxWidth: .infinity, alignment: .trailing)
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
            HStack(spacing: 12) {
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
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .systemBackground)))
        }
        .buttonStyle(.plain)
    }

    private func homeShortAddr(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.count >= 10 else { return t }
        return "\(t.prefix(5))...\(t.suffix(5))"
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

    @ViewBuilder
    private func avatarView(image: String?, fallbackUrl: URL?) -> some View {
        if let s = image?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty, let u = URL(string: s) {
            AsyncImage(url: u) { phase in
                switch phase {
                case .success(let img): img.resizable().scaledToFill()
                case .failure: fallbackDice(fallbackUrl)
                case .empty: ProgressView().scaleEffect(0.6)
                @unknown default: fallbackDice(fallbackUrl)
                }
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

private struct AmountPadSheet: View {
    var title: String
    var continueTint: Color
    var onCancel: () -> Void
    var onContinue: (String) -> Void

    @State private var amount = "0"

    var body: some View {
        NavigationStack {
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
                Button("Continue") {
                    onContinue(amount)
                }
                .buttonStyle(.borderedProminent)
                .tint(continueTint)
                .disabled(!canContinue)
                .padding(.bottom)
            }
            .padding(.horizontal)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
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
                        .buttonStyle(.plain)
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

// MARK: - Tip

private struct TipSheet: View {
    var subtotal: String
    var onBack: () -> Void
    var onConfirm: (Int) -> Void

    @State private var selected: Double = 0

    private var num: Double { Double(subtotal) ?? 0 }

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Subtotal")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("$\(String(format: "%.2f", num))")
                    .font(.system(size: 44, weight: .light, design: .rounded))
                tipGrid
                Button("Confirm & Pay") {
                    let bps = Int((selected * 10_000).rounded())
                    onConfirm(bps)
                }
                .buttonStyle(.borderedProminent)
                .tint(.black)
                Spacer()
            }
            .padding()
            .navigationTitle("Add Tip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Back") { onBack() }
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
                    .strokeBorder(on ? Color(red: 0.08, green: 0.38, blue: 0.94) : Color.black.opacity(0.08), lineWidth: on ? 2 : 1)
                    .background(RoundedRectangle(cornerRadius: 24).fill(on ? Color(red: 0.08, green: 0.38, blue: 0.94).opacity(0.08) : Color.white))
            )
        }
        .buttonStyle(.plain)
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

/// Align Android `ReadScreen` success / error layout (`MainActivity.kt` ReadScreen).
private struct ReadBalanceView: View {
    let assets: UIDAssets?
    let rawResponseJson: String?
    let error: String?
    @Binding var amountFlow: AmountFlow?
    var onDismissSheet: () -> Void

    private let pageBg = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    private let accentGreen = Color(red: 0x6E / 255, green: 0xD0 / 255, blue: 0x88 / 255)
    private let labelGrey = Color(red: 0xBB / 255, green: 0xBB / 255, blue: 0xBB / 255)
    private let checkGreen = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
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
            GeometryReader { geo in
                let compact = geo.size.height < 560
                let sidePad: CGFloat = compact ? 12 : 16
                let gapSm: CGFloat = compact ? 6 : 8
                ZStack {
                    pageBg.ignoresSafeArea()
                    if let err = error, !err.isEmpty {
                        VStack(spacing: 12) {
                            Text("❌ \(err)")
                                .font(.subheadline)
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.center)
                                .padding()
                            Button("Done") { onDismissSheet() }
                                .buttonStyle(.borderedProminent)
                        }
                        .padding(.top, 56)
                    } else if let a = assets, a.ok {
                        VStack(spacing: 0) {
                            ScrollView {
                                VStack(alignment: .leading, spacing: 0) {
                                balanceLoadedHeader(compact: compact)
                                VStack(alignment: .leading, spacing: gapSm) {
                                    readBalanceAccountSection(assets: a, compact: compact, sidePad: sidePad, gapSm: gapSm)
                                    readBalanceUsdcCard(assets: a, compact: compact, sidePad: sidePad, gapSm: gapSm)
                                    readBalancePassSection(assets: a, compact: compact, sidePad: sidePad, gapSm: gapSm, geoWidth: geo.size.width)
                                    readBalanceResponseSection(compact: compact, sidePad: sidePad, gapSm: gapSm)
                                }
                                .padding(.horizontal, sidePad)
                                .padding(.top, 44)
                                .padding(.bottom, compact ? 120 : 132)
                            }
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
                            .buttonStyle(.plain)
                            .disabled(!topupButtonEnabled)
                            .opacity(topupButtonEnabled ? 1 : 0.45)

                            Button {
                                onDismissSheet()
                            } label: {
                                Text("Done")
                                    .font(.system(size: compact ? 13 : 14, weight: .semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, compact ? 12 : 14)
                                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
                                    .foregroundStyle(.white)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, sidePad)
                        .padding(.top, 10)
                        .padding(.bottom, compact ? 10 : 14)
                        .background(pageBg)
                    }
                } else {
                    Text("No data")
                        .foregroundStyle(.secondary)
                        .padding(.top, 56)
                }
            }
            }
            SheetCircularBackButton(action: onDismissSheet)
                .padding(.leading, 12)
                .safeAreaPadding(.top, 6)
        }
        .toolbar(.hidden, for: .navigationBar)
        .task(id: balanceLoadIdentity) {
            topupButtonEnabled = true
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            if !Task.isCancelled { topupButtonEnabled = false }
        }
    }

    private func balanceLoadedHeader(compact: Bool) -> some View {
        readBalanceStyleSuccessHeader(title: "Balance Loaded", compact: compact)
    }

    @ViewBuilder
    private func readBalanceAccountSection(assets: UIDAssets, compact: Bool, sidePad: CGFloat, gapSm: CGFloat) -> some View {
        let displayBeamioTag = assets.beamioTag?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let rawUid = assets.uid?.nilIfEmpty
        let uidForDisplay = rawUid.flatMap { readBalanceLooksLikeEthereumAddress($0) ? nil : $0 }
        let tagId = assets.tagIdHex?.nilIfEmpty
        let counterVal = assets.counter
        if displayBeamioTag != nil || uidForDisplay != nil || tagId != nil || counterVal != nil {
            VStack(alignment: .leading, spacing: compact ? 6 : 8) {
                HStack {
                    Text("Account")
                        .font(.system(size: compact ? 11 : 12, weight: .bold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let cnt = counterVal, cnt >= 0 {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11))
                                .foregroundStyle(.gray)
                            Text("\(cnt)")
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.06)))
                    }
                }
                HStack(alignment: .center, spacing: 8) {
                    if let tag = displayBeamioTag {
                        ReadBalanceBeamioTagCapsule(beamioTag: tag)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else if let uid = uidForDisplay {
                        ReadBalanceHexCopyCapsule(
                            value: uid,
                            copyLabel: "uid",
                            leadingSystemImage: "touchid"
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if let tid = tagId {
                        ReadBalanceHexCopyCapsule(
                            value: tid,
                            copyLabel: "tagId",
                            leadingSystemImage: "tag"
                        )
                    } else {
                        HStack(spacing: 4) {
                            Image(systemName: "tag")
                                .font(.system(size: 11))
                                .foregroundStyle(Color(red: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255))
                            Text("—")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.black.opacity(0.06)))
                    }
                }
            }
            .padding(compact ? 10 : 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: compact ? 12 : 16).fill(Color(uiColor: .systemBackground)))
            .shadow(color: Color.black.opacity(compact ? 0.04 : 0.06), radius: compact ? 2 : 4, y: 1)
        }
    }

    private func readBalanceUsdcCard(assets: UIDAssets, compact: Bool, sidePad _: CGFloat, gapSm: CGFloat) -> some View {
        let usdcBal = Double(assets.usdcBalance ?? "0") ?? 0
        let usdcPadH: CGFloat = compact ? 12 : 16
        let usdcPadV: CGFloat = compact ? 10 : 14
        let usdcTitle: CGFloat = compact ? 13 : 14
        let usdcAmt: CGFloat = compact ? 16 : 17
        let parts = readBalanceFormatMoney(usdcBal, currency: "USDC")
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("USDC on Base")
                    .font(.system(size: usdcTitle, weight: .medium))
                    .foregroundStyle(Color.white.opacity(0.9))
                Spacer()
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text(parts.mid)
                        .font(.system(size: usdcAmt, weight: .bold))
                        .foregroundStyle(.white)
                    Text(parts.suffix)
                        .font(.system(size: compact ? 10 : 11, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                }
            }
            .padding(.horizontal, usdcPadH)
            .padding(.vertical, usdcPadV)
            .background(RoundedRectangle(cornerRadius: compact ? 14 : 18).fill(Color(red: 0x1c / 255, green: 0x1c / 255, blue: 0x1e / 255)))
        }
        .padding(.top, gapSm)
    }

    @ViewBuilder
    private func readBalancePassSection(assets: UIDAssets, compact: Bool, sidePad: CGFloat, gapSm: CGFloat, geoWidth: CGFloat) -> some View {
        if let cardList = readBalanceCardList(from: assets), !cardList.isEmpty {
            let passRowH: CGFloat = compact ? 142 : 176
            let pageCardW = max(160, geoWidth - sidePad * 2 - 20)
            Group {
                Text("\(cardList.count) Pass\(cardList.count == 1 ? "" : "es")")
                    .font(.system(size: compact ? 10 : 11, weight: .bold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
                    .padding(.top, gapSm)
                if cardList.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(cardList) { card in
                                ReadBalancePassCard(card: card, compact: true)
                                    .frame(width: pageCardW)
                            }
                        }
                        .padding(.trailing, 4)
                    }
                    .frame(height: passRowH)
                    .padding(.top, compact ? 4 : 6)
                } else {
                    ReadBalancePassCard(card: cardList[0], compact: compact)
                        .padding(.top, compact ? 4 : 6)
                }
            }
        }
    }

    @ViewBuilder
    private func readBalanceResponseSection(compact: Bool, sidePad _: CGFloat, gapSm: CGFloat) -> some View {
        if let raw = rawResponseJson, !raw.isEmpty {
            Button {
                responseExpanded.toggle()
            } label: {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text("Response Data")
                            .font(.system(size: compact ? 13 : 15, weight: .semibold))
                            .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                        Spacer()
                        Text(responseExpanded ? "▼" : "▶")
                            .font(.system(size: 11))
                            .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                    }
                    .padding(compact ? 10 : 14)
                    if responseExpanded {
                        ScrollView {
                            Text(raw)
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
                .background(RoundedRectangle(cornerRadius: compact ? 12 : 16).fill(Color(uiColor: .systemBackground)))
                .overlay(RoundedRectangle(cornerRadius: compact ? 12 : 16).stroke(Color.black.opacity(0.05), lineWidth: 1))
            }
            .buttonStyle(.plain)
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
            primaryMemberTokenId: nil
        ),
    ]
}

private func readBalanceLooksLikeEthereumAddress(_ value: String) -> Bool {
    let t = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard t.hasPrefix("0x"), t.count == 42 else { return false }
    let hex = t.dropFirst(2)
    return hex.allSatisfy(\.isASCIIHexDigit)
}

private extension Character {
    var isASCIIHexDigit: Bool {
        isASCII && ((self >= "0" && self <= "9") || (self >= "a" && self <= "f") || (self >= "A" && self <= "F"))
    }
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

/// `ReadBalancePassCard` — Android `ReadBalancePassCard`.
private struct ReadBalancePassCard: View {
    let card: CardItem
    let compact: Bool

    private let accentGreen = Color(red: 0x6E / 255, green: 0xD0 / 255, blue: 0x88 / 255)
    private let labelGrey = Color(red: 0xBB / 255, green: 0xBB / 255, blue: 0xBB / 255)

    var body: some View {
        let balanceNum = Double(card.points) ?? 0
        let memberNo = readBalanceMemberNo(from: card)
        let bgColor = readBalanceParseHexColor(card.cardBackground) ?? Color(red: 0x2C / 255, green: 0x55 / 255, blue: 0x35 / 255)
        let padS: CGFloat = compact ? 12 : 18
        let padT: CGFloat = compact ? 10 : 18
        let padB: CGFloat = compact ? 10 : 14
        let padE: CGFloat = compact ? 12 : 18
        let imgW: CGFloat = compact ? 100 : 152
        let imgH: CGFloat = compact ? 80 : 118
        let iconSz: CGFloat = compact ? 30 : 40
        let titleFs: CGFloat = compact ? 13 : 15
        let subFs: CGFloat = compact ? 10 : 12
        let memFs: CGFloat = compact ? 12 : 15
        let balLblFs: CGFloat = compact ? 9 : 11
        let balSideFs: CGFloat = compact ? 11 : 14
        let balMainFs: CGFloat = compact ? 17 : 22
        let corner: CGFloat = compact ? 16 : 22
        let gap: CGFloat = compact ? 12 : 16
        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                if let u = card.cardImage?.nilIfEmpty, let url = URL(string: u) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(img): img.resizable().scaledToFill()
                        case .failure: Image(systemName: "heart.fill").foregroundStyle(accentGreen)
                        case .empty: ProgressView().scaleEffect(0.7)
                        @unknown default: Image(systemName: "heart.fill").foregroundStyle(accentGreen)
                        }
                    }
                    .frame(width: imgW, height: imgH)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                } else {
                    Image(systemName: "heart.fill")
                        .font(.system(size: iconSz))
                        .foregroundStyle(accentGreen)
                        .frame(width: imgW, height: imgH, alignment: .center)
                }
                VStack(alignment: .trailing, spacing: 2) {
                    Text(card.cardName.replacingOccurrences(of: " CARD", with: "").replacingOccurrences(of: " Card", with: ""))
                        .font(.system(size: titleFs, weight: .bold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.trailing)
                        .lineLimit(2)
                    let sub = readBalancePassTierSubtitle(for: card)
                    if !sub.isEmpty, sub.caseInsensitiveCompare("Card") != .orderedSame {
                        Text(sub)
                            .font(.system(size: subFs))
                            .foregroundStyle(labelGrey)
                            .multilineTextAlignment(.trailing)
                            .lineLimit(compact ? 3 : 4)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            Spacer().frame(height: gap)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Member No.")
                        .font(.system(size: balLblFs))
                        .foregroundStyle(labelGrey)
                    Text(memberNo.isEmpty ? "—" : memberNo)
                        .font(.system(size: memFs, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text("Balance")
                        .font(.system(size: balLblFs))
                        .foregroundStyle(labelGrey)
                    let parts = readBalanceFormatMoney(balanceNum, currency: card.cardCurrency)
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        if !parts.prefix.isEmpty {
                            Text(parts.prefix)
                                .font(.system(size: balSideFs, weight: .medium))
                                .foregroundStyle(accentGreen)
                        }
                        Text(parts.mid)
                            .font(.system(size: balMainFs, weight: .bold))
                            .foregroundStyle(accentGreen)
                        if !parts.suffix.isEmpty {
                            Text(parts.suffix)
                                .font(.system(size: balSideFs, weight: .medium))
                                .foregroundStyle(accentGreen)
                        }
                    }
                }
            }
        }
        .padding(.leading, padS)
        .padding(.top, padT)
        .padding(.trailing, padE)
        .padding(.bottom, padB)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: corner).fill(bgColor))
    }
}

private struct ReadBalanceBeamioTagCapsule: View {
    let beamioTag: String
    @State private var copied = false

    private var normalized: String {
        beamioTag.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "^@+", with: "", options: .regularExpression)
    }

    var body: some View {
        let display = "@\(normalized)"
        let short = display.count >= 14 ? "\(display.prefix(8))…\(display.suffix(4))" : display
        HStack(spacing: 6) {
            Image(systemName: "storefront")
                .font(.system(size: 11))
                .foregroundStyle(Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255))
            Text(short)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
                .foregroundStyle(copied ? checkGreenCopy : Color.black.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.06)))
        .contentShape(Capsule())
        .onTapGesture {
            UIPasteboard.general.string = normalized
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                copied = false
            }
        }
    }

    private var checkGreenCopy: Color { Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255) }
}

// MARK: - Receipt detail rows (Top-up / Payment success)

@ViewBuilder
private func beamioReceiptDetailRow(left: String, right: String, rightBlue: Bool = false) -> some View {
    HStack {
        Text(left)
            .font(.system(size: 13))
            .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
        Spacer()
        Text(right)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(rightBlue ? Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255) : .primary)
    }
    .padding(.vertical, 6)
}

// MARK: - Payment success (Android `PaymentSuccessContent`)

/// Same header row as `ReadBalanceView.balanceLoadedHeader` (green check + title).
private func readBalanceStyleSuccessHeader(title: String, compact: Bool) -> some View {
    let headerBox: CGFloat = compact ? 36 : 46
    let headerIcon: CGFloat = compact ? 22 : 30
    let checkGreen = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)
    return HStack(spacing: 8) {
        ZStack {
            Circle().fill(Color.white)
                .frame(width: headerBox, height: headerBox)
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: headerIcon))
                .foregroundStyle(checkGreen)
        }
        Text(title)
            .font(.system(size: compact ? 17 : 19, weight: .semibold))
            .foregroundStyle(.primary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, compact ? 12 : 16)
    .padding(.vertical, compact ? 4 : 6)
}

private struct PaymentSuccessView: View {
    let state: ChargeSuccessState
    var onDone: () -> Void

    private let pageBg = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    private let accentGreen = Color(red: 0x6E / 255, green: 0xD0 / 255, blue: 0x88 / 255)
    private let labelGrey = Color(red: 0xBB / 255, green: 0xBB / 255, blue: 0xBB / 255)
    private let checkGreen = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)

    var body: some View {
        let currency = state.cardCurrency ?? "CAD"
        let amountNum = Double(state.amount) ?? 0
        let amtParts = readBalanceFormatMoney(amountNum, currency: currency)
        let postNum = Double(state.postBalance ?? "") ?? nil
        let shortPayee = paymentShortAddr(state.payee)
        let memRaw = state.memberNo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayMemberNo = memRaw.isEmpty ? (shortPayee ?? "—") : memRaw
        let cardBg = readBalanceParseHexColor(state.cardBackground) ?? Color(red: 0x2C / 255, green: 0x55 / 255, blue: 0x35 / 255)
        let dateStr = topupFormatReceiptDate(Date())
        let subtotalNum = Double(state.subtotal ?? "") ?? nil

        ZStack(alignment: .topLeading) {
            pageBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                readBalanceStyleSuccessHeader(title: "Approved", compact: false)
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("−")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                    if !amtParts.prefix.isEmpty {
                        Text(amtParts.prefix)
                            .font(.system(size: 10))
                            .foregroundStyle(.primary)
                    }
                    Text(amtParts.mid)
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.primary)
                    if !amtParts.suffix.isEmpty {
                        Text(amtParts.suffix)
                            .font(.system(size: 10))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 12) {
                    paymentPassVoucherCard(
                        state: state,
                        displayMemberNo: displayMemberNo,
                        postBalance: postNum,
                        currency: currency,
                        cardBg: cardBg
                    )

                    if let sub = subtotalNum {
                        paymentSmartRoutingCard(state: state, subtotal: sub, currency: currency)
                    }

                    VStack(spacing: 0) {
                        beamioReceiptDetailRow(left: "Date", right: dateStr)
                        topupThinDividerPayment
                        if let t = state.tableNumber?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
                            beamioReceiptDetailRow(left: "Table number", right: t)
                            topupThinDividerPayment
                        }
                        beamioReceiptDetailRow(left: "Member No.", right: displayMemberNo)
                        if !state.txHash.isEmpty {
                            topupThinDividerPayment
                            beamioReceiptDetailRow(left: "TX Hash", right: topupShortTx(state.txHash), rightBlue: true)
                        }
                        topupThinDividerPayment
                        HStack {
                            Text("Settlement")
                                .font(.system(size: 13))
                                .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.shield.fill")
                                    .font(.system(size: 12))
                                Text(state.settlementViaQr ? "App Validator" : "NTAG 424 DNA")
                                    .font(.system(size: 13, weight: .medium))
                            }
                            .foregroundStyle(checkGreen)
                        }
                        .padding(.vertical, 6)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .systemBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.05), lineWidth: 1))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                VStack(spacing: 8) {
                    Button {
                        chargePrintReceipt(state: state, dateString: dateStr)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "printer.fill")
                                .font(.system(size: 14))
                            Text("Print Receipt")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.black.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    Button(action: onDone) {
                        Text("Done")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .padding(.bottom, 24)
                }
                .padding(.top, 44)
            }
            SheetCircularBackButton(action: onDone)
                .padding(.leading, 12)
                .safeAreaPadding(.top, 6)
        }
    }

    private var topupThinDividerPayment: some View {
        Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
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
            if let u = pass?.cardImage?.nilIfEmpty, let url = URL(string: u) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case let .success(img): img.resizable().scaledToFill()
                    case .failure: Image(systemName: "heart.fill").foregroundStyle(accentGreen)
                    case .empty: ProgressView().scaleEffect(0.7)
                    @unknown default: Image(systemName: "heart.fill").foregroundStyle(accentGreen)
                    }
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
            VStack(alignment: .leading, spacing: 2) {
                Text("Member No.")
                    .font(.system(size: 11))
                    .foregroundStyle(labelGrey)
                Text(displayMemberNo)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
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
    let discAmt = discP.map { subtotal * Double($0) / 100.0 }
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
            paymentRoutingMoneyRow(label: "Tier discount (\(d)%)", amount: da, currency: currency, negative: true, discount: true)
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
    var lines: [String] = [
        "PAYMENT APPROVED",
        "",
        "Amount: \(topupFormatForReceipt(amount: state.amount, currency: currency))",
        "Card Balance: \(topupFormatForReceipt(amount: state.postBalance ?? "—", currency: currency))",
    ]
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

private struct TopupSuccessView: View {
    let state: TopupSuccessState
    var onDone: () -> Void

    private let pageBg = Color(red: 245 / 255, green: 245 / 255, blue: 247 / 255)
    private let accentGreen = Color(red: 0x6E / 255, green: 0xD0 / 255, blue: 0x88 / 255)
    private let labelGrey = Color(red: 0xBB / 255, green: 0xBB / 255, blue: 0xBB / 255)
    private let checkGreen = Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255)

    var body: some View {
        let currency = state.cardCurrency ?? "CAD"
        let amountNum = Double(state.amount) ?? 0
        let amtParts = readBalanceFormatMoney(amountNum, currency: currency)
        let postNum = Double(state.postBalance ?? "") ?? nil
        let shortAddr = topupShortAddr(state.address)
        let memRaw = state.memberNo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayMemberNo = memRaw.isEmpty ? (shortAddr ?? "—") : memRaw
        let cardBg = readBalanceParseHexColor(state.cardBackground) ?? Color(red: 0x2C / 255, green: 0x55 / 255, blue: 0x35 / 255)
        let isFirstMint = memRaw.isEmpty
        let dateStr = topupFormatReceiptDate(Date())

        ZStack(alignment: .topLeading) {
            pageBg.ignoresSafeArea()
            ScrollView {
                VStack(spacing: 0) {
                readBalanceStyleSuccessHeader(
                    title: isFirstMint ? "Card Minted" : "Top-Up Complete",
                    compact: false
                )
                HStack(alignment: .lastTextBaseline, spacing: 2) {
                    Text("+")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                    if !amtParts.prefix.isEmpty {
                        Text(amtParts.prefix)
                            .font(.system(size: 10))
                            .foregroundStyle(.primary)
                    }
                    Text(amtParts.mid)
                        .font(.system(size: 36, weight: .light))
                        .foregroundStyle(.primary)
                    if !amtParts.suffix.isEmpty {
                        Text(amtParts.suffix)
                            .font(.system(size: 10))
                            .foregroundStyle(.primary)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 4)
                .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 12) {
                    topupVoucherCard(
                        state: state,
                        displayMemberNo: displayMemberNo,
                        postBalance: postNum,
                        currency: currency,
                        cardBg: cardBg
                    )

                    VStack(spacing: 0) {
                        beamioReceiptDetailRow(left: "Date", right: dateStr)
                        topupThinDivider
                        beamioReceiptDetailRow(left: "Member No.", right: displayMemberNo)
                        if !state.txHash.isEmpty {
                            topupThinDivider
                            beamioReceiptDetailRow(left: "TX Hash", right: topupShortTx(state.txHash), rightBlue: true)
                        }
                        topupThinDivider
                        HStack {
                            Text("Settlement")
                                .font(.system(size: 13))
                                .foregroundStyle(Color(red: 0x86 / 255, green: 0x86 / 255, blue: 0x8b / 255))
                            Spacer()
                            HStack(spacing: 4) {
                                Image(systemName: "checkmark.shield.fill")
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
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(uiColor: .systemBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.black.opacity(0.05), lineWidth: 1))
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

                VStack(spacing: 8) {
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
                        .foregroundStyle(.primary)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.black.opacity(0.3), lineWidth: 1)
                        )
                    }
                    .buttonStyle(.plain)

                    Button(action: onDone) {
                        Text("Done")
                            .font(.system(size: 14, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.black))
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .padding(.bottom, 24)
                }
                .padding(.top, 44)
            }
            SheetCircularBackButton(action: onDone)
                .padding(.leading, 12)
                .safeAreaPadding(.top, 6)
        }
    }

    private var topupThinDivider: some View {
        Rectangle().fill(Color.black.opacity(0.06)).frame(height: 1)
    }

    private func topupVoucherCard(
        state: TopupSuccessState,
        displayMemberNo: String,
        postBalance: Double?,
        currency: String,
        cardBg: Color
    ) -> some View {
        let pass = state.passCard
        let titleRaw: String? = {
            if let p = pass {
                let n = p.cardName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !n.isEmpty { return n }
            }
            let t = state.tierName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return t.isEmpty ? nil : t
        }()
        let titleTxt = (titleRaw ?? "Card")
            .replacingOccurrences(of: " CARD", with: "")
            .replacingOccurrences(of: " Card", with: "")
        let subtitle: String = {
            if let p = pass {
                let s = readBalancePassTierSubtitle(for: p)
                if !s.isEmpty { return s }
            }
            let d = state.tierDescription?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !d.isEmpty, d.caseInsensitiveCompare("Card") != .orderedSame { return d }
            return ""
        }()

        return VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                if let u = pass?.cardImage?.nilIfEmpty, let url = URL(string: u) {
                    AsyncImage(url: url) { phase in
                        switch phase {
                        case let .success(img): img.resizable().scaledToFill()
                        case .failure: Image(systemName: "heart.fill").foregroundStyle(accentGreen)
                        case .empty: ProgressView().scaleEffect(0.7)
                        @unknown default: Image(systemName: "heart.fill").foregroundStyle(accentGreen)
                        }
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
                VStack(alignment: .leading, spacing: 2) {
                    Text("Member No.")
                        .font(.system(size: 11))
                        .foregroundStyle(labelGrey)
                    Text(displayMemberNo)
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                }
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

private struct ReadBalanceHexCopyCapsule: View {
    let value: String
    let copyLabel: String
    var leadingSystemImage: String?
    @State private var copied = false

    var body: some View {
        let short = value.count >= 10 ? "\(value.prefix(6))…\(value.suffix(4))" : value
        HStack(spacing: 6) {
            if let s = leadingSystemImage {
                Image(systemName: s)
                    .font(.system(size: 11))
                    .foregroundStyle(leadingTint)
            }
            Text(short)
                .font(.system(size: 11, design: .monospaced))
            Spacer(minLength: 0)
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .font(.system(size: 12))
                .foregroundStyle(copied ? Color(red: 0x34 / 255, green: 0xC7 / 255, blue: 0x59 / 255) : Color.black.opacity(0.6))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.black.opacity(0.06)))
        .contentShape(Capsule())
        .onTapGesture {
            guard !value.isEmpty else { return }
            UIPasteboard.general.string = value
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                copied = false
            }
        }
    }

    private var leadingTint: Color {
        if copyLabel == "tagId" { return Color(red: 0x7C / 255, green: 0x3A / 255, blue: 0xED / 255) }
        return Color(red: 0x15 / 255, green: 0x62 / 255, blue: 0xf0 / 255)
    }
}

private struct ScanSheet: View {
    @ObservedObject var vm: POSViewModel
    let action: ScanPendingAction
    @State private var qrArmed = false

    var body: some View {
        VStack(spacing: 0) {
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

            VStack(spacing: 16) {
                if action != .linkApp {
                    Picker("Method", selection: Binding(
                        get: { vm.scanMethod },
                        set: { new in
                            Task { @MainActor in
                                if new == .qr {
                                    let ok = await vm.requestCameraIfNeeded()
                                    if ok {
                                        vm.setScanMethod(.qr)
                                        qrArmed = true
                                    } else {
                                        vm.homeToast = "Camera access denied"
                                        vm.setScanMethod(.nfc)
                                        qrArmed = false
                                    }
                                } else {
                                    vm.setScanMethod(.nfc)
                                    qrArmed = false
                                }
                            }
                        }
                    )) {
                        Text("Tap Card").tag(ScanMethod.nfc)
                        Text("Scan QR").tag(ScanMethod.qr)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)
                }

                ZStack {
                    RoundedRectangle(cornerRadius: 24)
                        .strokeBorder(Color.black.opacity(0.1), lineWidth: 2)
                        .frame(height: 280)
                        .background(RoundedRectangle(cornerRadius: 24).fill(Color.white))

                    if vm.scanMethod == .qr, qrArmed {
                        BeamioQRScannerView { text in
                            Task { await vm.onQrScanned(text) }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .padding(6)
                        .frame(height: 268)
                    } else {
                        VStack(spacing: 12) {
                            if vm.isNfcBusy {
                                ProgressView()
                                Text(vm.scanBanner).font(.footnote).multilineTextAlignment(.center).foregroundStyle(.secondary)
                            } else if action == .linkApp, !vm.linkDeepLink.isEmpty {
                                Text("Link ready").font(.headline)
                                Text(vm.linkDeepLink).font(.caption).lineLimit(3)
                                Button("Copy link") {
                                    UIPasteboard.general.string = vm.linkDeepLink
                                }
                                .buttonStyle(.bordered)
                            } else if vm.showLinkCancel {
                                Text(vm.scanBanner).foregroundStyle(.red).multilineTextAlignment(.center)
                                Button("Cancel link lock") {
                                    Task { await vm.cancelLinkLock() }
                                }
                                .disabled(vm.opRunning)
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

                Text(bottomCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .onAppear {
            qrArmed = false
            if vm.scanMethod == .nfc {
                vm.setScanMethod(.nfc)
            } else {
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
        case .topup: return "Hold the card for top-up, or switch to QR."
        case .payment: return "Hold the card to pay, or switch to QR."
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
