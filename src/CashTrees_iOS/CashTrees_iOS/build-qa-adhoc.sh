#!/bin/zsh
# QA Ad Hoc build (Release configuration, production APNs) for device call debugging.
#
# Differences from a normal Ad Hoc build, all set on this command line only
# (the project file and Info.plist are not changed):
#   - Swift flag BEAMIO_QA: BeamioQALog writes the call path (incoming, answer,
#     accept uplink, CallKit Video intent, incall link, PWA bridge) to
#     Documents/qa-call.log, and BeamioCallTiming writes Documents/call-timing.log.
#     Ids, stages and ok/fail only: no keys, mnemonics, session keys or message text.
#   - UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace, so the logs can be
#     read without a debug-signed app:
#       xcrun devicectl device copy from --device <udid> --domain-type appDataContainer \
#         --domain-identifier com.beamio.beamio --source Documents/qa-call.log --destination ./qa-call.log
#     (also voice-qa.log, busy-qa-breadcrumb.log), or Finder > device > Files, or the Files app.
# Never ship this build: it is for test devices only.
#
# usage: ./build-qa-adhoc.sh <output-dir>
set -euo pipefail
cd "$(dirname "$0")"
OUT="${1:?usage: build-qa-adhoc.sh <output-dir>}"
mkdir -p "$OUT"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

QA_PLIST="$OUT/Info-QA.plist"
cp CashTrees_iOS/Info.plist "$QA_PLIST"
/usr/libexec/PlistBuddy -c "Add :UIFileSharingEnabled bool true" "$QA_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :UIFileSharingEnabled true" "$QA_PLIST"
/usr/libexec/PlistBuddy -c "Add :LSSupportsOpeningDocumentsInPlace bool true" "$QA_PLIST" 2>/dev/null \
  || /usr/libexec/PlistBuddy -c "Set :LSSupportsOpeningDocumentsInPlace true" "$QA_PLIST"

rm -rf "$OUT/qa.xcarchive" "$OUT/qa-adhoc"
xcodebuild -project CashTrees_iOS.xcodeproj -scheme CashTrees_iOS -configuration Release \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData-QARel -allowProvisioningUpdates \
  archive -archivePath "$OUT/qa.xcarchive" \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) BEAMIO_QA' \
  INFOPLIST_FILE="$QA_PLIST"
xcodebuild -exportArchive -archivePath "$OUT/qa.xcarchive" \
  -exportOptionsPlist ExportOptions-ad-hoc.plist -exportPath "$OUT/qa-adhoc" -allowProvisioningUpdates
echo "QA ipa: $OUT/qa-adhoc/CashTrees_iOS.ipa"
