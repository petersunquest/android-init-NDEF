# Beamio POS PWA

**唯一活跃的 POS 终端 UI。** Merchant terminals run inside **native iOS/Android WebView shells** that load this PWA — not the deprecated native POS apps (`src/CashTrees_iOS/iOS_NDEF/`, `src/android-NDEF/`).

Deployed at:

- `https://pos.conet.network/` (primary — POS WebView shells)
- `https://beamio.app/pos/` (alternate path; build with default `POS_PWA_BASE=/pos/`)

| Active shell | Path | Default URL |
|--------------|------|-------------|
| iOS WebView | `src/CashTrees_iOS/CashTrees_iOS/CashTrees_iOS/ContentView.swift` | `https://pos.conet.network/` |
| Android WebView | `src/android/softPOS/.../MainActivity.kt` | `https://pos.beamio.app/` |

## Routes

| Path | Screen | Native equivalent |
|------|--------|-------------------|
| `/pos/` | Terminal Setup (Welcome) | `VerraEntrySplashView` / `WelcomePage` |
| `/pos/onboarding` | Wallet setup (create / restore) | `OnboardingView` / `OnboardingScreen` |
| `/pos/permission` | Parent workspace approval gate | `AwaitingParentWorkspacePermissionOverlay` |
| `/pos/home` | Home KPI + action grid | `HomeRootView` / `NdefScreen` |
| `/pos/topup` | Top-up amount pad + NFC/QR + success | iOS `TopupAmountPadFullPage` → scan → `runTopup` |
| `/pos/check-balance` | Check Balance loading + result | `ReadBalanceView` |
| `/pos/native/:action` | Native action loading handoff | Charge / Top-up / History… |

**Home action flow:** Home buttons only `navigate` to a dedicated route; **never** run NFC/QR/API/native inline on `/home`. Loading-first until complete or abort — see `.cursor/rules/beamio-pos-pwa-home-action-flow.mdc`.

**Top-up (PWA):** `/topup` → amount pad + payment method → loading → NFC/QR → `nfcTopupPrepare` + admin sign + `/api/nfcTopup` (Card/Cash/Bonus); USDC/CADD → customer payment QR + session poll (aligned with iOS).

**Charge (PWA):** `/charge` → amount pad (program card / USDC / CADD) → tip (15/18/20/custom) → program card: NFC → `payByNfcUidPrepare` + `payByNfcUidSignContainer` (fiat6-only); USDC/CADD: `verra.network/usdc-charge` QR + session poll (aligned with iOS).

**Check Balance (PWA):** `/check-balance` → full-screen loading → NFC/QR/API → result or return Home with error banner.

**Native actions:** `/native/charge` etc. → loading → `BeamioPOS.navigateNative`. Native shell should return WebView to `/home` (or `nativeFlowComplete` bridge event) when dismissed.

Charge, Top-up, History, etc. use **`/native/:action`** then native via `BeamioPOS.navigateNative`.

## Dev

```bash
cd src/posPwa
npm install
npm run dev
```

Open `http://localhost:5173/pos/` (Vite dev uses `/pos/` base).

## Build & deploy

```bash
cd src/posPwa && npm run build
# pos.conet.network (root base):
POS_PWA_BASE=/ npm run build
# or from repo root:
./scripts/deployPosConetNetwork.sh
# beamio.app/pos/ (subpath base):
./scripts/deployBeamioPosPwa.sh
```

| Target | Script | Remote path |
|--------|--------|-------------|
| `https://pos.conet.network` | `./scripts/deployPosConetNetwork.sh` | `/var/www/pos.conet.network/` |
| `https://beamio.app/pos/` | `./scripts/deployBeamioPosPwa.sh` | `/var/www/beamio.app/pos/` |

Staging dirs: `posTemp/` on each host before atomic promote.

## Native bridge (`window.BeamioPOS`)

WebView shells inject **hardware / navigation** helpers — **wallet + mnemonic live in PWA IndexedDB** (`posWalletStorage.ts`), not native Keychain (see `.cursor/rules/beamio-consumer-wallet-signing-storage.mdc`).

```javascript
window.BeamioPOS = {
  platform: 'ios', // or 'android'
  // Web mode: PWA uses IndexedDB + session memory; bridge optional for NFC/camera.
  navigateNative(action) {
    // legacy handoff — prefer PWA routes /charge, /topup, /check-balance
  },
  async resendParentPermissionRequest() { /* optional; PWA uses src/conet/ */ },
}
```

Full bridge shape: `src/posPwa/src/bridge/nativeBridge.ts`. Shell rules: `.cursor/rules/beamio-pos-pwa-native-webview-shell.mdc`.

## CoNET Chat (terminal permission)

On `/pos/permission`, the PWA automatically:

1. Registers sender PGP on CoNET `AddressPGP` (`ensureRegisteredForSenderGossip`)
2. Resolves parent `@BeamioTag` → EOA via `/api/search-users`
3. Sends encrypted `beamio_pos_terminal_permission_v1` via Guardian gossip POST

Implementation: `src/conet/` — see `.cursor/rules/conet-decentralized-chat-dev.mdc`.

**Private keys must not be written to localStorage** (session memory in native only). The PWA only caches profiles, KPIs, and permission flags.

### Web wallet (IndexedDB)

Browser / dev mode mirrors SilentPassUI `createOrGetWallet` + `checkStorage`:

- BIP39 mnemonic via `ethers.Wallet.createRandom()`
- Encrypted recover blobs on `/api/addUser` (Argon2id + AES-GCM, same as bizSite `createRecover`)
- **Mnemonic** persisted in IndexedDB (`beamio_pos_wallet_v1`, doc `init`, base64 JSON — PouchDB-compatible `title` field)
- **Private key** session-only (`src/wallet/posWalletSession.ts`); reload hydrates from IndexedDB mnemonic via `bootstrapPosWalletFromIndexedDb()`

## Trusted cache

Home follows `beamio-trusted-vs-untrusted-fetch`: failed API/RPC responses do not overwrite last trusted local values (`posHomeTrustedCache`).

## Full-screen WebView layout

POS PWA runs inside **iOS / Android WebView** with notches, home indicators, and varying screen sizes. Pages must **fill the viewport**, avoid horizontal/vertical page scroll, and adapt dynamically.

- **Rule:** `.cursor/rules/beamio-pos-pwa-fullscreen-layout.mdc`
- **Home action loading:** `.cursor/rules/beamio-pos-pwa-home-action-flow.mdc`
- **Shell:** `src/components/PosScreenShell.tsx` (`PosScreenShell`, `PosScreenHeader`, `PosScreenMain`, `PosScreenFooter`)
- **Document lock:** `index.html` (`viewport-fit=cover`) + `src/index.css` (`html/body/#root` → `100dvh overflow:hidden`)
- **Native shell:** must preserve `viewport-fit=cover` and avoid double safe-area padding — see `.cursor/rules/beamio-native-webview-pwa-shell.mdc` §5
