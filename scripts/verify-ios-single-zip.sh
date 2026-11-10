#!/usr/bin/env bash
# Single-ZIP gate for the Beamio iOS shell (src/CashTrees_iOS). Read-only.
#
# The shell loads exactly one embedded PWA: SilentPassUI.zip at the app bundle
# root (CashTreesPWABundleStore.swift: Bundle.main.url(forResource: "SilentPassUI",
# withExtension: "zip")). The Xcode target uses a file-system synchronized
# folder, so every file in the resource folder is copied into the app. Any extra
# ZIP there ships with the app.
#
# Usage:
#   verify-ios-single-zip.sh pre  [--resources DIR] [--sha256 HEX] [--ver X.Y.Z]
#       Before a build: DIR (default: the shell's resource folder) must hold
#       exactly one ZIP, ./SilentPassUI.zip. Old versions, backups and temp
#       ZIPs must live outside DIR.
#   verify-ios-single-zip.sh post --sha256 HEX --ver X.Y.Z ARTIFACT...
#       After a build. ARTIFACT is a .app, an .xcarchive (checks
#       Products/Applications/*.app) or an .ipa (checks Payload/*.app).
#       Each app must hold exactly one ZIP, at <app>/SilentPassUI.zip, whose
#       SHA256 equals HEX, whose update.json has "ver" X.Y.Z, which contains
#       index.html and has no nested .zip entries.
#
# A ZIP is any file named *.zip (any case) or any file starting with a ZIP
# signature (PK\x03\x04, PK\x05\x06 or PK\x07\x08), whatever its name.
# Exit 0 = pass. Exit 1 = gate failed (reasons printed). Exit 2 = bad usage.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_RESOURCES="$REPO_ROOT/src/CashTrees_iOS/CashTrees_iOS/CashTrees_iOS"
ZIP_NAME="SilentPassUI.zip"

FAILS=0
fail() { echo "FAIL: $*"; FAILS=$((FAILS + 1)); }
info() { echo "  $*"; }
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

TMP_ROOT=""
cleanup() {
	if [[ -n "$TMP_ROOT" && -d "$TMP_ROOT" && "$TMP_ROOT" == "${TMPDIR:-/tmp}"* ]]; then
		rm -rf "$TMP_ROOT"
	fi
}
trap cleanup EXIT

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

# Prints every ZIP under $1, one path per line (relative to $1).
list_zips() {
	local root="$1" f
	while IFS= read -r -d '' f; do
		if is_zip_file "$f"; then
			printf '%s\n' "${f#"$root"/}"
		fi
	done < <(find "$root" \( -type f -o -type l \) -print0)
}

# Checks content of one embedded ZIP. $1 = path, $2 = expected sha (may be empty), $3 = expected ver (may be empty)
check_zip_content() {
	local z="$1" want_sha="$2" want_ver="$3" sha listing ver nested
	sha="$(shasum -a 256 "$z" | awk '{print $1}')"
	info "sha256: $sha"
	if [[ -n "$want_sha" ]]; then
		if [[ "$sha" != "$(printf '%s' "$want_sha" | tr '[:upper:]' '[:lower:]')" ]]; then
			fail "SHA256 mismatch: got $sha, approved $want_sha"
		fi
	fi
	if ! listing="$(unzip -Z1 "$z" 2>/dev/null)"; then
		fail "$ZIP_NAME is not a readable ZIP"
		return
	fi
	info "entries: $(printf '%s\n' "$listing" | grep -c .)"
	if printf '%s\n' "$listing" | grep -qx 'index.html'; then
		info "entry: index.html"
	else
		fail "index.html missing at ZIP root"
	fi
	if printf '%s\n' "$listing" | grep -qx 'update.json'; then
		ver="$(unzip -p "$z" update.json | /usr/bin/python3 -I -c 'import json,sys; print(json.load(sys.stdin).get("ver",""))' 2>/dev/null || true)"
		info "update.json ver: ${ver:-<none>}"
		if [[ -z "$ver" ]]; then
			fail "update.json has no ver"
		elif [[ -n "$want_ver" && "$ver" != "$want_ver" ]]; then
			fail "update.json ver $ver != expected $want_ver"
		fi
	else
		fail "update.json missing at ZIP root"
	fi
	nested="$(printf '%s\n' "$listing" | grep -ci '\.zip$' || true)"
	info "nested .zip entries: $nested"
	if [[ "$nested" != "0" ]]; then
		fail "embedded ZIP contains $nested nested .zip entries"
	fi
}

# Checks one directory that must contain exactly ./SilentPassUI.zip. $1 = dir, $2 = label
check_tree() {
	local dir="$1" label="$2" want_sha="$3" want_ver="$4" zips count
	echo "== $label: $dir"
	zips="$(list_zips "$dir")"
	count="$(printf '%s' "$zips" | grep -c . || true)"
	info "ZIP files found: $count"
	if [[ -n "$zips" ]]; then
		printf '%s\n' "$zips" | sed 's/^/    - /'
	fi
	if [[ "$count" == "0" ]]; then
		fail "$label: no ZIP found; expected exactly one $ZIP_NAME"
		return
	fi
	if [[ "$count" != "1" ]]; then
		fail "$label: $count ZIP files found; expected exactly one"
	fi
	if ! printf '%s\n' "$zips" | grep -qx "$ZIP_NAME"; then
		fail "$label: $ZIP_NAME not at the load path ($dir/$ZIP_NAME)"
		return
	fi
	check_zip_content "$dir/$ZIP_NAME" "$want_sha" "$want_ver"
}

check_apps_in() {
	# $1 = dir holding *.app, $2 = label
	local holder="$1" label="$2" found=0 app
	for app in "$holder"/*.app; do
		[[ -d "$app" ]] || continue
		found=1
		check_tree "$app" "$label: $(basename "$app")" "$SHA" "$VER"
	done
	if [[ "$found" == "0" ]]; then
		fail "$label: no .app found in $holder"
	fi
}

MODE="${1:-}"
[[ -n "$MODE" ]] || usage
shift
RESOURCES="$DEFAULT_RESOURCES"
SHA=""
VER=""
ARTIFACTS=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--resources) RESOURCES="${2:?}"; shift 2 ;;
		--sha256) SHA="${2:?}"; shift 2 ;;
		--ver) VER="${2:?}"; shift 2 ;;
		-h | --help) usage ;;
		--*) echo "unknown option $1" >&2; exit 2 ;;
		*) ARTIFACTS+=("$1"); shift ;;
	esac
done
if [[ -n "$SHA" && ! "$SHA" =~ ^[0-9a-fA-F]{64}$ ]]; then
	echo "--sha256 must be 64 hex characters" >&2
	exit 2
fi

case "$MODE" in
	pre)
		[[ -d "$RESOURCES" ]] || { echo "resource folder not found: $RESOURCES" >&2; exit 2; }
		check_tree "$RESOURCES" "pre-build resources" "$SHA" "$VER"
		;;
	post)
		if [[ -z "$SHA" || -z "$VER" || ${#ARTIFACTS[@]} -eq 0 ]]; then
			echo "post mode needs --sha256, --ver and at least one artifact" >&2
			exit 2
		fi
		for a in "${ARTIFACTS[@]}"; do
			a="${a%/}"
			case "$a" in
				*.app)
					[[ -d "$a" ]] || { fail "not found: $a"; continue; }
					check_tree "$a" "app" "$SHA" "$VER"
					;;
				*.xcarchive)
					[[ -d "$a" ]] || { fail "not found: $a"; continue; }
					check_apps_in "$a/Products/Applications" "xcarchive $(basename "$a")"
					;;
				*.ipa)
					[[ -f "$a" ]] || { fail "not found: $a"; continue; }
					[[ -n "$TMP_ROOT" ]] || TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/verify-ios-zip.XXXXXX")"
					ex="$(mktemp -d "$TMP_ROOT/ipa.XXXXXX")"
					if ! unzip -q "$a" -d "$ex"; then
						fail "cannot unpack $a"
						continue
					fi
					check_apps_in "$ex/Payload" "ipa $(basename "$a")"
					;;
				*) fail "unsupported artifact (want .app, .xcarchive or .ipa): $a" ;;
			esac
		done
		;;
	*) usage ;;
esac

if [[ "$FAILS" -gt 0 ]]; then
	echo "RESULT: FAIL ($FAILS problem(s))"
	exit 1
fi
echo "RESULT: PASS"
