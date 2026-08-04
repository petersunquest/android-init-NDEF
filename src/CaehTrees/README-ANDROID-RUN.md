# CaehTrees Android — Run / Play package id

**Google Play application id:** `com.beamio.app`  
**Launcher activity:** `com.beamio.app.MainActivity`

The Gradle module folder is named `CaehTrees`; that is **not** the install package. Do not launch with `com.beamio.caehtrees` (legacy namespace, removed).

## FCM / offline chat badge

1. Firebase Console → add Android app with package `com.beamio.app`.
2. Download `google-services.json` into `app/` (replace the placeholder).
3. On API host `~/.master.json` set FCM HTTP v1 credentials (see x402sdk `offlineChatPush.ts`):
   - `fcm_project_id`
   - `fcm_service_account_path` (or `fcm_service_account_json`)
4. PWA calls `CashTreesAndroid.bindPushIdentity(JSON.stringify({ eoa, pgpKeyId }))` after chat init.

Do **not** commit real Firebase service-account private keys. Placeholder `app/google-services.json` is for local Gradle sync only.

## Release App Bundle (Play)

Signing matches **android-NDEF / Android-init-NDEF** (same upload keystore):

- Config: `src/Android-init-NDEF/keystore.properties`
- Store: `src/Android-init-NDEF/beamio-app-release.keystore`

```bash
cd src/CaehTrees
./gradlew :app:bundleRelease
# → app/build/outputs/bundle/release/app-release.aab
```

## Quick launch (recommended)

From `src/CaehTrees`:

```bash
chmod +x run-debug.sh   # once
./run-debug.sh
```

This uninstalls the old `com.beamio.caehtrees` package (if any), installs debug, and starts the correct activity.

## Android Studio

### Recommended: **Launch Debug (adb)** (Gradle)

Toolbar run config → choose **`Launch Debug (adb)`** → Run.

This runs `:app:launchDebug` (install + `adb am start` with the correct package). It does **not** depend on IDE cached `applicationId`.

### Fix the broken **APP** / **Android App** config

Your screenshot shows a local config **APP** with **Store as project file** unchecked — that stale entry lives in `.idea/workspace.xml` and may still launch as `com.beamio.caehtrees/...`.

1. **Run → Edit Configurations…**
2. **Delete** the local **APP** entry (and any duplicate **app** / template entries you do not need).
3. Re-open the project so shared configs load:
   - **`Launch Debug (adb)`** — use this for daily Run
   - **`app`** — Android App config with **Specified Activity** `com.beamio.app.MainActivity`, Module **`CaehTrees.app`**
4. On the config you keep, check **Store as project file** so it is not recreated wrongly in `workspace.xml`.
5. **File → Sync Project with Gradle Files**
6. If **app** still fails: **File → Invalidate Caches… → Invalidate and Restart**, then delete `.idea/caches/` and Sync again.

1. Open **`src/CaehTrees`** as the Gradle project root (not the monorepo root).
2. **Build Variants** panel → **app** → **debug** (not release).

## adb (after `./gradlew :app:installDebug`)

```bash
adb shell am start -n com.beamio.app/com.beamio.app.MainActivity
```

## Wrong launch (will fail)

```bash
# ❌ legacy namespace — Activity class does not exist
adb shell am start -n com.beamio.caehtrees/com.beamio.app.MainActivity
```
