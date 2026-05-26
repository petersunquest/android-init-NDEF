#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IOS_DIR="$ROOT/src/CashTrees_iOS/CashTrees_iOS"
SCHEME="CashTrees_iOS"
PROJECT="$IOS_DIR/$SCHEME.xcodeproj"
EXPORT_PLIST="$ROOT/src/CashTrees_iOS/app-store/ExportOptions-app-store-upload.plist"
ARCHIVE_DIR="$ROOT/build/CashTrees_iOS-Archives"
EXPORT_DIR="$ROOT/build/CashTrees_iOS-Export"
ARCHIVE_PATH="$ARCHIVE_DIR/${SCHEME}.xcarchive"

mkdir -p "$ARCHIVE_DIR" "$EXPORT_DIR"

echo "==> Archive $SCHEME (Release, generic iOS device)"
xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$ARCHIVE_PATH" \
  -allowProvisioningUpdates \
  clean archive

echo "==> Upload to App Store Connect"
xcodebuild \
  -exportArchive \
  -archivePath "$ARCHIVE_PATH" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist "$EXPORT_PLIST" \
  -allowProvisioningUpdates

echo "==> Done. Check App Store Connect → TestFlight for processing status."
