#!/usr/bin/env bash
# Single entry for the Beamio native-shell single-ZIP gate (both shells).
# Read-only. Calls the per-shell gates:
#   scripts/verify-ios-single-zip.sh      (iOS: pre / post)
#   scripts/verify-android-single-zip.sh  (Android: prebuild / artifact)
# Rule: .cursor/rules/beamio-native-shell-single-zip.mdc
#
# Usage:
#   verify-native-single-zip.sh pre  --sha256 HEX [--ver X.Y.Z]
#       [--ios-resources DIR] [--android-app-dir DIR] [--only ios|android]
#       Before building: each shell's packaging folder holds exactly one ZIP,
#       SilentPassUI.zip, equal to the approved ZIP.
#   verify-native-single-zip.sh post --sha256 HEX --ver X.Y.Z [--only ios|android] ARTIFACT...
#       After building. iOS artifacts: .app, .xcarchive, .ipa. Android
#       artifacts: .apk, .aab. Unless --only is given, at least one artifact
#       of each shell is required, so a delivery cannot skip one shell.
#
# Exit 0 = every gate passed; 1 = a gate failed (block delivery); 2 = bad usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IOS_GATE="$SCRIPT_DIR/verify-ios-single-zip.sh"
ANDROID_GATE="$SCRIPT_DIR/verify-android-single-zip.sh"

usage() { sed -n '2,19p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }

MODE="${1:-}"
case "$MODE" in
	pre | post) shift ;;
	-h | --help | "") usage ;;
	*) echo "unknown mode: $MODE (use pre or post)" >&2; exit 2 ;;
esac

SHA=""
VER=""
ONLY=""
IOS_RES=""
ANDROID_APP=""
IOS_ARTS=()
ANDROID_ARTS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--sha256) SHA="${2:?}"; shift 2 ;;
		--ver) VER="${2:?}"; shift 2 ;;
		--only) ONLY="${2:?}"; shift 2 ;;
		--ios-resources) IOS_RES="${2:?}"; shift 2 ;;
		--android-app-dir) ANDROID_APP="${2:?}"; shift 2 ;;
		-h | --help) usage ;;
		--*) echo "unknown option: $1" >&2; exit 2 ;;
		*)
			a="${1%/}"
			case "$(printf '%s' "$a" | tr '[:upper:]' '[:lower:]')" in
				*.app | *.xcarchive | *.ipa) IOS_ARTS+=("$a") ;;
				*.apk | *.aab) ANDROID_ARTS+=("$a") ;;
				*) echo "unsupported artifact: $a (want .app .xcarchive .ipa .apk .aab)" >&2; exit 2 ;;
			esac
			shift
			;;
	esac
done

[[ "$SHA" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "--sha256 (64 hex) is required" >&2; exit 2; }
case "$ONLY" in "" | ios | android) ;; *) echo "--only must be ios or android" >&2; exit 2 ;; esac
RUN_IOS=1
RUN_ANDROID=1
[[ "$ONLY" == "android" ]] && RUN_IOS=0
[[ "$ONLY" == "ios" ]] && RUN_ANDROID=0

FAILED=()
run_gate() {
	local label="$1"
	shift
	echo "######## $label"
	if "$@"; then
		echo "######## $label: PASS"
	else
		echo "######## $label: FAIL"
		FAILED+=("$label")
	fi
}

VER_ARGS=()
[[ -n "$VER" ]] && VER_ARGS=(--ver "$VER")

if [[ "$MODE" == "pre" ]]; then
	if [[ "$RUN_IOS" -eq 1 ]]; then
		args=(pre --sha256 "$SHA" "${VER_ARGS[@]+"${VER_ARGS[@]}"}")
		[[ -n "$IOS_RES" ]] && args+=(--resources "$IOS_RES")
		run_gate "iOS pre-build" "$IOS_GATE" "${args[@]}"
	fi
	if [[ "$RUN_ANDROID" -eq 1 ]]; then
		args=(prebuild --sha256 "$SHA" "${VER_ARGS[@]+"${VER_ARGS[@]}"}")
		[[ -n "$ANDROID_APP" ]] && args+=(--app-dir "$ANDROID_APP")
		run_gate "Android pre-build" "$ANDROID_GATE" "${args[@]}"
	fi
else
	[[ -n "$VER" ]] || { echo "post mode needs --ver" >&2; exit 2; }
	if [[ "$RUN_IOS" -eq 1 ]]; then
		if [[ ${#IOS_ARTS[@]} -eq 0 ]]; then
			echo "######## iOS post-build: FAIL (no .app / .xcarchive / .ipa given)"
			FAILED+=("iOS post-build (no artifact)")
		else
			run_gate "iOS post-build" "$IOS_GATE" post --sha256 "$SHA" --ver "$VER" "${IOS_ARTS[@]}"
		fi
	elif [[ ${#IOS_ARTS[@]} -gt 0 ]]; then
		echo "iOS artifacts given with --only android" >&2; exit 2
	fi
	if [[ "$RUN_ANDROID" -eq 1 ]]; then
		if [[ ${#ANDROID_ARTS[@]} -eq 0 ]]; then
			echo "######## Android post-build: FAIL (no .apk / .aab given)"
			FAILED+=("Android post-build (no artifact)")
		else
			run_gate "Android post-build" "$ANDROID_GATE" artifact --sha256 "$SHA" --ver "$VER" "${ANDROID_ARTS[@]}"
		fi
	elif [[ ${#ANDROID_ARTS[@]} -gt 0 ]]; then
		echo "Android artifacts given with --only ios" >&2; exit 2
	fi
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
	echo "SINGLE-ZIP GATE FAILED: ${FAILED[*]} — block delivery."
	exit 1
fi
echo "SINGLE-ZIP GATE PASSED (${MODE})."
