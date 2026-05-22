# CashTrees_iOS (Beamio consumer shell)

Native iOS wrapper (`com.beamio.beamio`) around the Beamio consumer WebView PWA. Supports **dual deep-link entry**:

1. **Universal Links** — `https://beamio.app/...` (primary, shareable)
2. **Custom URL scheme** — `beamio://open?...` (secondary, for `/app-download` wake-up)

Implementation: `BeamioDeepLink.swift`, `CashTrees_iOSApp.swift` (`onOpenURL` + `onContinueUserActivity`), `Info.plist`, `CashTrees.entitlements`.

---

// MARK: - PWA bridge (`window.CashTreesIOS`)

Bridge is injected at `documentStart`. Results arrive on:

```javascript
window.addEventListener('cashtreesios', (event) => {
  const detail = event.detail // { action, ok, requestId, ... }
});
```

| Call | Result `action` | Success fields |
|------|-----------------|----------------|
| `scanQr({ requestId })` | `scanQr` | `text` — raw QR payload (URL, JSON, plain text) |
| `scanRecoveryQr({ requestId })` | `scanRecoveryQr` | `recoveryCode` — parsed Base62 recovery code |
| `saveRecoveryQrToPhotos({ dataUrl, filename, requestId })` | `saveRecoveryQrToPhotos` | — |
| NFC bind | (via `cashtreesnfc` event) | — |

### General QR scan UI

Both `scanQr` and `scanRecoveryQr` open the same full-screen scanner:

- Live camera with centered square frame
- Dimmed + lightly blurred surround
- **Choose Photo or File** stops the camera, then offers Photo Library or Browse Files (no time pressure while picking)
- **Cancel** returns `error: "cancelled"`

### Example — arbitrary QR text

```javascript
const requestId = String(Date.now());
window.addEventListener('cashtreesios', (e) => {
  if (e.detail.action !== 'scanQr' || e.detail.requestId !== requestId) return;
  if (e.detail.ok) console.log(e.detail.text);
  else console.log(e.detail.error);
}, { once: true });
window.CashTreesIOS?.scanQr({ requestId });
```

---

## URL organization (how to build links)

Both entry types must resolve to an **allowed HTTPS URL** that the WebView loads. Resolution logic lives in `BeamioDeepLink.resolveWebAppURL(from:)`.

### Allowed HTTPS hosts

| Host | Notes |
|------|--------|
| `beamio.app` | Canonical API / PWA domain |
| `www.beamio.app` | Optional www alias |
| `verra.network` | Legacy PWA host (default cold-start home today) |
| `www.verra.network` | Optional www alias |

Only **`https://`** targets are accepted (no `http://`).

### Universal Link paths (iOS opens the app)

These paths on `beamio.app` are declared in AASA and handled in-app:

| Path | Purpose |
|------|---------|
| `/app` | PWA root |
| `/app/*` | PWA routes + query deep links |
| `/app-download` | Smart install / open landing |
| `/app-download/*` | Same, with query |

**Examples (preferred for sharing):**

```
https://beamio.app/app/
https://beamio.app/app/?beamiocard=0x…&redeemcode=…
https://beamio.app/app-download
https://beamio.app/app-download?campaign=qr
```

If the app is **not installed**, iOS opens the link in Safari (normal HTTPS behaviour).

---

### Custom scheme `beamio://` (secondary)

Registered in `Info.plist` → `CFBundleURLSchemes` → `beamio`.

Two supported shapes:

#### A. Passthrough query → default PWA base

Maps query parameters onto `https://beamio.app/app/` (same semantics as web deep links).

```
beamio://open?beamiocard=0x82ce…&redeemcode=ABC123
→ https://beamio.app/app/?beamiocard=0x82ce…&redeemcode=ABC123
```

Also valid:

```
beamio://open/?foo=bar
beamio://?foo=bar          (host omitted)
```

#### B. Explicit HTTPS target

Use when you need a full URL (must pass allowlist):

```
beamio://open?target=<urlencode(https://beamio.app/app/?beamiocard=0x…))>
```

`target` must decode to an **allowed `https://` host** above.

**Do not** pass arbitrary third-party URLs in `target` — they are rejected.

---

### Which link type to use when

| Scenario | Recommended URL |
|----------|-----------------|
| Share redeem / coupon / marketing | `https://beamio.app/app/?…` |
| Email, SMS, QR code | `https://beamio.app/...` |
| Homepage `/app-download` “try open installed app” | `beamio://open?…` (after HTTPS attempt) |
| Internal tests / explicit app-only wake | `beamio://open?…` |

**Rule:** Publish **HTTPS** externally; use **`beamio://`** only as a supplemental wake-up path.

---

## Server: Apple App Site Association (AASA)

Draft file (repo):

```
docs/apple-app-site-association.draft.json
```

Deploy to production **without** a file extension:

```
https://beamio.app/.well-known/apple-app-site-association
```

Requirements:

- `Content-Type: application/json` (or `application/pkcs7-mime` if signed)
- No redirects on that URL
- Team ID + bundle ID in `appIDs`: `23YYTMA7YQ.com.beamio.beamio`

On `beamio.app` nginx (already has `location ^~ /.well-known/`), place the file under the site root:

```bash
# Example
cp docs/apple-app-site-association.draft.json \
  /var/www/beamio.app/.well-known/apple-app-site-association
```

Validate after deploy:

```bash
curl -sI https://beamio.app/.well-known/apple-app-site-association
# Apple CDN validator (optional):
# https://search.developer.apple.com/appsearch-validation-tool/
```

---

## Xcode / Apple Developer setup

### Already in repo

| File | Purpose |
|------|---------|
| `CashTrees_iOS/Info.plist` | `CFBundleURLTypes` → scheme `beamio` |
| `CashTrees_iOS/CashTrees.entitlements` | `applinks:beamio.app`, `applinks:www.beamio.app` |
| `project.pbxproj` | `INFOPLIST_FILE = CashTrees_iOS/Info.plist` |

### You must do in Apple Developer + App Store Connect

1. **App ID** `com.beamio.beamio` → enable **Associated Domains**
2. **Provisioning profile** must include Associated Domains (re-download after change)
3. **Ship a new build** — URL scheme + Universal Links are baked into the IPA (cannot enable from App Store Connect alone)

### Local testing

**Custom scheme (Simulator or device):**

```bash
xcrun simctl openurl booted "beamio://open?beamiocard=0x1234&redeemcode=test"
```

**Universal Links:**

- Install a build with entitlements + deployed AASA
- Tap `https://beamio.app/app/?…` in Notes/Messages (not Safari address bar — long-press link)
- Or use Apple’s validation tool

---

## Runtime flow (in app)

```
Incoming URL
    ├─ https://beamio.app/app/…     → Universal Link → BeamioDeepLink.resolve → WKWebView.load
    ├─ https://beamio.app/app-download… → same
    └─ beamio://open?…              → onOpenURL → resolve → WKWebView.load
```

Default cold start (no link): WebView loads `https://beamio.app/app/` until replaced by a resolved deep link.

---

## Related web entry

Homepage smart install page:

```
https://beamio.app/app-download
```

See `src/homepage/src/pages/AppDownloadPage.tsx` and `src/homepage/src/utils/nativeAppDownload.ts`.

After this iOS build is live, iOS `/app-download` can prefer Universal Links first, then fall back to `beamio://open?…` + App Store.

---

## Files touched for deep links

| File | Role |
|------|------|
| `BeamioDeepLink.swift` | URL resolution + allowlist |
| `CashTrees_iOSApp.swift` | `onOpenURL`, `onContinueUserActivity` |
| `ContentView.swift` | WebView loads resolved URL |
| `Info.plist` | Custom URL scheme |
| `CashTrees.entitlements` | Associated Domains |
| `docs/apple-app-site-association.draft.json` | Server AASA template |
