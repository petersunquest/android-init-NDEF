#!/usr/bin/env bash
# Copy the approved SilentPassUI release ZIP into the Consumer native shells
# (bootstrap bundle), as the one fixed-name file each shell loads:
#   iOS      src/CashTrees_iOS/CashTrees_iOS/CashTrees_iOS/SilentPassUI.zip
#   Android  src/CaehTrees/app/src/main/assets/SilentPassUI.zip
#
# Single-ZIP rule (.cursor/rules/beamio-native-shell-single-zip.mdc): each
# shell's packaging folder holds exactly one ZIP, SilentPassUI.zip. The iOS
# target is a file-system synchronized folder, so any other ZIP there (an old
# version, a backup, a temp copy) ships inside the app. This script never
# writes a versioned ZIP into a shell folder and never downloads anything: you
# pass the approved ZIP and its SHA-256 explicitly.
#
# Usage:
#   scripts/syncEmbeddedPwaZipToNativeShells.sh --zip PATH --sha256 HEX [--ver X.Y.Z]
#       [--archive-dir DIR] [--ios-resources DIR] [--android-app-dir DIR]
#
#   --zip            the approved release ZIP (for example the file downloaded
#                    from https://beamio.app/app/SilentPassUI-<ver>.zip, or a
#                    local candidate the PM approved)
#   --sha256         its approved SHA-256; the copy is refused if it differs
#   --ver            expected update.json "ver" inside the ZIP (optional; when
#                    omitted, the ZIP's own ver is used for the gates)
#   --archive-dir    also keep a copy named SilentPassUI-<ver>.zip in this
#                    existing folder; it must be outside this repository
#   --ios-resources  iOS packaging folder (default: the shell's resource folder;
#                    also IOS_RESOURCES_DIR)
#   --android-app-dir Android app module folder holding src/*/assets (default:
#                    src/CaehTrees/app; also ANDROID_APP_DIR)
#
# Steps: check the ZIP (SHA-256, index.html and update.json at the root, no
# nested ZIP), refuse to write when either packaging folder already holds a ZIP
# other than SilentPassUI.zip, write the fixed-name copies, then run the
# pre-build gates (verify-ios-single-zip.sh pre, verify-android-single-zip.sh
# prebuild). Exit 0 = written and both gates pass; 1 = refused or gate failed;
# 2 = bad usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
ZIP_NAME="SilentPassUI.zip"

IOS_DIR="${IOS_RESOURCES_DIR:-$REPO_ROOT/src/CashTrees_iOS/CashTrees_iOS/CashTrees_iOS}"
ANDROID_APP="${ANDROID_APP_DIR:-$REPO_ROOT/src/CaehTrees/app}"
SRC_ZIP=""
SHA=""
VER=""
ARCHIVE_DIR=""

usage() { sed -n '2,37p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2; }
die() { echo "REFUSED: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--zip) SRC_ZIP="${2:?--zip needs a value}"; shift 2 ;;
		--sha256) SHA="${2:?--sha256 needs a value}"; shift 2 ;;
		--ver) VER="${2:?--ver needs a value}"; shift 2 ;;
		--archive-dir) ARCHIVE_DIR="${2:?--archive-dir needs a value}"; shift 2 ;;
		--ios-resources) IOS_DIR="${2:?--ios-resources needs a value}"; shift 2 ;;
		--android-app-dir) ANDROID_APP="${2:?--android-app-dir needs a value}"; shift 2 ;;
		-h | --help) usage ;;
		*) echo "unknown argument: $1" >&2; usage ;;
	esac
done

[[ -n "$SRC_ZIP" && -n "$SHA" ]] || { echo "--zip and --sha256 are required" >&2; usage; }
[[ "$SHA" =~ ^[0-9a-fA-F]{64}$ ]] || { echo "--sha256 must be 64 hex characters" >&2; exit 2; }
SHA="$(printf '%s' "$SHA" | tr 'A-F' 'a-f')"
[[ -f "$SRC_ZIP" ]] || die "ZIP not found: $SRC_ZIP"
[[ -d "$IOS_DIR" ]] || die "iOS resource folder not found: $IOS_DIR"
[[ -d "$ANDROID_APP/src/main/assets" ]] || die "Android assets folder not found: $ANDROID_APP/src/main/assets"

# --- 1. The ZIP itself -------------------------------------------------------
GOT_SHA="$(shasum -a 256 "$SRC_ZIP" | awk '{print $1}')"
echo "==> ZIP: $SRC_ZIP"
echo "    sha256: $GOT_SHA"
[[ "$GOT_SHA" == "$SHA" ]] || die "SHA-256 mismatch: got $GOT_SHA, approved $SHA"

LISTING="$(unzip -Z1 "$SRC_ZIP" 2>/dev/null)" || die "not a readable ZIP: $SRC_ZIP"
printf '%s\n' "$LISTING" | grep -qx 'index.html' || die "index.html missing at the ZIP root"
printf '%s\n' "$LISTING" | grep -qx 'update.json' || die "update.json missing at the ZIP root"
if printf '%s\n' "$LISTING" | grep -qi '\.zip$'; then
	die "the ZIP contains nested .zip entries"
fi
INNER_VER="$(unzip -p "$SRC_ZIP" update.json | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("ver",""))' 2>/dev/null || true)"
[[ -n "$INNER_VER" ]] || die "update.json inside the ZIP has no ver"
if [[ -n "$VER" && "$INNER_VER" != "$VER" ]]; then
	die "update.json ver $INNER_VER != --ver $VER"
fi
VER="$INNER_VER"
echo "    update.json ver: $VER; index.html present; no nested ZIP"

# --- 2. Refuse to write next to a stray ZIP ----------------------------------
is_zip_file() {
	local f="$1" magic
	case "$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')" in
		*.zip) return 0 ;;
	esac
	[[ -f "$f" && ! -L "$f" ]] || return 1
	magic="$(head -c 4 "$f" 2>/dev/null | xxd -p)"
	case "$magic" in
		504b0304 | 504b0506 | 504b0708) return 0 ;;
	esac
	return 1
}

STRAY=""
scan_stray() {
	# $1 = folder to scan, $2 = the one allowed path
	local root="$1" allowed="$2" f
	while IFS= read -r -d '' f; do
		if is_zip_file "$f" && [[ "$f" != "$allowed" ]]; then
			STRAY="${STRAY}    - ${f}"$'\n'
		fi
	done < <(find "$root" \( -type f -o -type l \) -print0)
}
scan_stray "$IOS_DIR" "$IOS_DIR/$ZIP_NAME"
for assets in "$ANDROID_APP"/src/*/assets; do
	[[ -d "$assets" ]] || continue
	scan_stray "$assets" "$ANDROID_APP/src/main/assets/$ZIP_NAME"
done
if [[ -n "$STRAY" ]]; then
	printf 'Packaging folders hold other ZIP files; move them outside the repository first:\n%s' "$STRAY" >&2
	die "stray ZIP files in the packaging folders (nothing was written)"
fi

# --- 3. Archive copy (outside the repository only) ---------------------------
if [[ -n "$ARCHIVE_DIR" ]]; then
	[[ -d "$ARCHIVE_DIR" ]] || die "--archive-dir must be an existing folder outside the repository: $ARCHIVE_DIR"
	ARCHIVE_REAL="$(cd "$ARCHIVE_DIR" && pwd -P)"
	case "$ARCHIVE_REAL/" in
		"$REPO_ROOT"/*) die "--archive-dir must be outside the repository: $ARCHIVE_REAL" ;;
	esac
	cp "$SRC_ZIP" "$ARCHIVE_REAL/SilentPassUI-${VER}.zip"
	echo "==> Archived: $ARCHIVE_REAL/SilentPassUI-${VER}.zip"
fi

# --- 4. Write the fixed-name copies ------------------------------------------
TMP_FILES=()
cleanup() {
	local t
	for t in "${TMP_FILES[@]+"${TMP_FILES[@]}"}"; do
		[[ -e "$t" ]] && rm -f -- "$t"
	done
	return 0
}
trap cleanup EXIT

write_fixed() {
	local dir="$1" tmp
	tmp="$(mktemp "$dir/.sync-SilentPassUI.XXXXXX")"
	TMP_FILES+=("$tmp")
	cp "$SRC_ZIP" "$tmp"
	chmod 644 "$tmp"
	mv -f "$tmp" "$dir/$ZIP_NAME"
	[[ "$(shasum -a 256 "$dir/$ZIP_NAME" | awk '{print $1}')" == "$SHA" ]] || die "copy check failed: $dir/$ZIP_NAME"
	echo "==> Wrote $dir/$ZIP_NAME"
}
write_fixed "$IOS_DIR"
write_fixed "$ANDROID_APP/src/main/assets"

# --- 5. Pre-build gates ------------------------------------------------------
GATE_FAIL=0
echo "==> Gate: iOS pre-build"
"$SCRIPT_DIR/verify-ios-single-zip.sh" pre --resources "$IOS_DIR" --sha256 "$SHA" --ver "$VER" || GATE_FAIL=1
echo "==> Gate: Android pre-build"
"$SCRIPT_DIR/verify-android-single-zip.sh" prebuild --app-dir "$ANDROID_APP" --sha256 "$SHA" --ver "$VER" || GATE_FAIL=1
if [[ "$GATE_FAIL" -ne 0 ]]; then
	echo "FAILED: a pre-build single-ZIP gate failed; do not build or deliver." >&2
	exit 1
fi
echo "==> Synced SilentPassUI.zip ver=${VER} sha256=${SHA}; both pre-build gates pass."
echo "==> Next: build the shells, then run scripts/verify-native-single-zip.sh post on the artifacts."
