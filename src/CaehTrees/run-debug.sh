#!/usr/bin/env bash
# Install debug APK and launch with the correct Play package id (com.beamio.app).
set -euo pipefail
cd "$(dirname "$0")"

echo "Removing legacy package com.beamio.caehtrees (if installed)..."
adb uninstall com.beamio.caehtrees 2>/dev/null || true

echo "Installing debug build..."
./gradlew :app:installDebug

echo "Launching com.beamio.app/com.beamio.app.MainActivity ..."
adb shell am start -n com.beamio.app/com.beamio.app.MainActivity
