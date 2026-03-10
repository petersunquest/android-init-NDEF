# Beamio Android NTAG 424 DNA Init

Android app for provisioning, repairing, and validating NTAG 424 DNA cards with Beamio SUN URLs.

## What This App Does

- Initializes `fresh` NTAG 424 DNA cards
- Repairs partially initialized or previously modified `rewritten` cards
- Writes Beamio SUN URLs under `https://beamio.app/api/sun`
- Locally decodes dynamic SUN payloads to recover:
  - `uid`
  - `counter`
  - `tagId`
- Verifies each tap against the Beamio server debug endpoint
- Compares local decode results with server-side verification

## Supported Flows

### Init

Used to provision or repair a card.

- `fresh` route:
  - authenticate with default key
  - rotate `key0` and `key2`
  - write NDEF data
  - apply SDM settings

- `rewritten` route:
  - authenticate with existing Beamio keys
  - preserve valid dynamic SDM when already active
  - otherwise repair the NDEF / SDM layout until the card reaches:
    - `rewritten_dynamic_sdm_active`

### Check

Used to verify a card after provisioning.

- reads the stored or tapped SUN URL
- locally decodes the encrypted payload using `globalKey2`
- calls:

```text
https://beamio.app/api/sun?debug=1
```

- confirms local and server results match

## Expected Success State

A healthy card should produce:

- a dynamic URL under `https://beamio.app/api/sun`
- a non-zero `counter`
- a stable `tagId`
- server response with:
  - `valid = true`
  - `macValid = true`

## Requirements

- Android device with NFC
- Android `minSdk 24`
- Internet access for server verification
- Beamio server exposing:
  - `GET /api/sun`

## Build

From this directory:

```bash
./gradlew assembleDebug
```

Debug APK output:

```text
app/build/outputs/apk/debug/
```

For a quick source-only check:

```bash
./gradlew :app:compileDebugKotlin
```

## App Permissions

Declared in `app/src/main/AndroidManifest.xml`:

- `android.permission.NFC`
- `android.permission.INTERNET`

## Project Structure

```text
Android-init-NDEF/
├── app/
│   ├── src/main/java/com/beamio/beamiondefinit/
│   │   ├── MainActivity.kt
│   │   ├── BeamioNtagProvisioner.kt
│   │   ├── BeamioNtagReader.kt
│   │   ├── BeamioLocalSunDecoder.kt
│   │   ├── AndroidNtag424Ev2.kt
│   │   └── KeyStorageManager.kt
│   └── src/main/AndroidManifest.xml
├── gradle/
├── build.gradle.kts
└── settings.gradle.kts
```

## Notes

- Some cards first fail as `fresh` and are then recoverable through the `rewritten` route.
- Success pages are intentionally compact.
- Failure pages show a short summary first and allow expanding full diagnostics.

## License

See the parent repository for license details.
