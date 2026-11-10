#!/usr/bin/env bash
# Release gate: the Beamio Android shell (src/CaehTrees) must ship exactly one
# PWA zip, at the path the shell loads (EmbeddedPwaConstants.BUNDLE_ASSET_NAME).
# Read-only: it never changes the project or the artifacts.
#
# Pre-build mode: checks the shell's asset folders before Gradle runs.
#   scripts/verify-android-single-zip.sh prebuild [--app-dir DIR] --sha256 HEX [--ver X.Y.Z]
#   - app/src/main/assets/ holds exactly one zip, named SilentPassUI.zip
#   - no other zip anywhere under app/src/*/assets (old versions, backups,
#     temp copies must live outside the packaging folders)
#
# Post-build mode: checks built APK / AAB files.
#   scripts/verify-android-single-zip.sh artifact --sha256 HEX [--ver X.Y.Z] FILE.apk|FILE.aab ...
#   - every entry is enumerated, recursively into any nested archive
#   - a zip is any entry named *.zip or starting with a zip header (PK\3\4,
#     or PK\5\6 for an empty zip)
#   - exactly one zip in the whole artifact, at assets/SilentPassUI.zip (APK)
#     or base/assets/SilentPassUI.zip (AAB), with nothing nested inside it
#
# Both modes also check the zip: SHA-256 equals --sha256 (the approved release
# zip), update.json has a "ver" (equal to --ver when given) and index.html is
# at the zip root.
#
# Exit code: 0 pass, 1 gate failed, 2 usage error.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
	sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2
	exit 2
}

[[ $# -ge 1 ]] || usage
MODE="$1"
shift
case "$MODE" in
	prebuild | artifact) ;;
	-h | --help) usage ;;
	*) echo "error: unknown mode '$MODE' (use prebuild or artifact)" >&2; exit 2 ;;
esac

APP_DIR="$REPO_ROOT/src/CaehTrees/app"
SHA=""
VER=""
FILES=()
while [[ $# -gt 0 ]]; do
	case "$1" in
		--app-dir) APP_DIR="${2:?--app-dir needs a value}"; shift 2 ;;
		--sha256) SHA="${2:?--sha256 needs a value}"; shift 2 ;;
		--ver) VER="${2:?--ver needs a value}"; shift 2 ;;
		-h | --help) usage ;;
		--*) echo "error: unknown option $1" >&2; exit 2 ;;
		*) FILES+=("$1"); shift ;;
	esac
done

SHA="$(printf '%s' "$SHA" | tr 'A-F' 'a-f')"
if [[ ! "$SHA" =~ ^[0-9a-f]{64}$ ]]; then
	echo "error: --sha256 must be the 64-hex SHA-256 of the approved release zip" >&2
	exit 2
fi
if [[ "$MODE" == artifact && ${#FILES[@]} -eq 0 ]]; then
	echo "error: artifact mode needs at least one .apk or .aab file" >&2
	exit 2
fi

# -I: isolated mode, so nothing next to the inputs can be imported.
exec python3 -I - "$MODE" "$APP_DIR" "$SHA" "$VER" "${FILES[@]+"${FILES[@]}"}" <<'PY'
import hashlib, io, json, os, sys, zipfile

mode, app_dir, want_sha, want_ver = sys.argv[1:5]
files = sys.argv[5:]
ASSET = "SilentPassUI.zip"
ZIP_MAGIC = (b"PK\x03\x04", b"PK\x05\x06")
errors = []

def fail(msg):
    errors.append(msg)
    print("FAIL: " + msg)

def is_zip(name, head):
    return name.lower().endswith(".zip") or head[:4] in ZIP_MAGIC

def check_bundle(label, data):
    """Check the approved PWA zip itself; return list of nested zip paths."""
    sha = hashlib.sha256(data).hexdigest()
    print(f"  {label}: sha256={sha} size={len(data)}")
    if sha != want_sha:
        fail(f"{label}: sha256 {sha} != approved {want_sha}")
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
    except zipfile.BadZipFile:
        fail(f"{label}: not a readable zip")
        return
    names = [i.filename for i in z.infolist()]
    if "index.html" not in names:
        fail(f"{label}: no index.html at the zip root")
    else:
        print(f"  {label}: entry index.html present")
    try:
        ver = json.loads(z.read("update.json")).get("ver")
    except KeyError:
        ver = None
        fail(f"{label}: no update.json at the zip root")
    except ValueError:
        ver = None
        fail(f"{label}: update.json is not valid JSON")
    if ver is not None:
        print(f"  {label}: update.json ver={ver}")
        if not ver:
            fail(f"{label}: update.json has no ver")
        elif want_ver and ver != want_ver:
            fail(f"{label}: update.json ver {ver} != expected {want_ver}")

def walk(z, prefix, found, depth=0):
    """Record every zip in archive z (recursively); returns nothing."""
    for info in z.infolist():
        if info.is_dir():
            continue
        path = prefix + info.filename
        with z.open(info) as h:
            head = h.read(4)
        if not is_zip(info.filename, head):
            continue
        data = z.read(info)
        found.append((path, data, depth))
        if depth >= 8:
            fail(f"{path}: archives nested too deep")
            continue
        try:
            inner = zipfile.ZipFile(io.BytesIO(data))
        except zipfile.BadZipFile:
            continue
        walk(inner, path + "!/", found, depth + 1)

if mode == "prebuild":
    main_assets = os.path.join(app_dir, "src", "main", "assets")
    src_dir = os.path.join(app_dir, "src")
    print(f"prebuild: {main_assets}")
    if not os.path.isdir(src_dir):
        fail(f"{src_dir} does not exist")
    zips = []
    if os.path.isdir(src_dir):
        for sourceset in sorted(os.listdir(src_dir)):
            adir = os.path.join(src_dir, sourceset, "assets")
            if not os.path.isdir(adir):
                continue
            for root, _dirs, names in os.walk(adir):
                for n in sorted(names):
                    p = os.path.join(root, n)
                    with open(p, "rb") as f:
                        head = f.read(4)
                    if is_zip(n, head):
                        zips.append(p)
    target = os.path.join(main_assets, ASSET)
    for p in zips:
        print(f"  zip in packaging folder: {os.path.relpath(p, app_dir)}")
    if len(zips) != 1:
        fail(f"found {len(zips)} zip(s) under app/src/*/assets, need exactly 1 ({os.path.relpath(target, app_dir)})")
    for p in zips:
        if os.path.abspath(p) != os.path.abspath(target):
            fail(f"{os.path.relpath(p, app_dir)}: extra zip in a packaging folder; move it outside app/src/*/assets")
    if os.path.isfile(target):
        with open(target, "rb") as f:
            check_bundle(os.path.relpath(target, app_dir), f.read())
    else:
        fail(f"{os.path.relpath(target, app_dir)} is missing")
else:
    for art in files:
        low = art.lower()
        if low.endswith(".apk"):
            expected = "assets/" + ASSET
        elif low.endswith(".aab"):
            expected = "base/assets/" + ASSET
        else:
            fail(f"{art}: not an .apk or .aab")
            continue
        print(f"artifact: {art}")
        try:
            with open(art, "rb") as f:
                print(f"  file sha256={hashlib.sha256(f.read()).hexdigest()}")
            z = zipfile.ZipFile(art)
        except (OSError, zipfile.BadZipFile) as e:
            fail(f"{art}: cannot read ({e})")
            continue
        print(f"  entries={len(z.infolist())}")
        found = []
        walk(z, "", found)
        for path, _data, _d in found:
            print(f"  zip found: {path}")
        if len(found) != 1:
            fail(f"{art}: found {len(found)} zip(s), need exactly 1 at {expected}")
        hits = [(p, d) for p, d, depth in found if depth == 0 and p == expected]
        for path, _data, depth in found:
            if path != expected:
                where = "nested inside another archive" if depth else "wrong location"
                fail(f"{art}: {path}: extra zip ({where}); only {expected} is allowed")
        if not hits:
            fail(f"{art}: {expected} is missing")
        elif len(hits) > 1:
            fail(f"{art}: {expected} appears {len(hits)} times")
        else:
            check_bundle(expected, hits[0][1])

if errors:
    print(f"RESULT: FAIL ({len(errors)} problem(s))")
    sys.exit(1)
print("RESULT: PASS")
PY
