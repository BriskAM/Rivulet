#!/bin/sh
# Bundle Homebrew's aria2c (and every non-system dylib it needs) into an app bundle.
#
#   Scripts/bundle_aria2.sh [path/to/Rivulet.app]      (default: build/Rivulet.app)
#
# Environment:
#   ARIA2C_SRC     source binary (default /opt/homebrew/bin/aria2c)
#   SIGN_IDENTITY  Developer ID identity; when set, signs with hardened runtime + timestamp,
#                  otherwise signs ad hoc.
#
# Layout: Contents/Resources/aria2c, Contents/Frameworks/*.dylib. Install names are rewritten
# to @executable_path/../Frameworks/<lib> (aria2c lives in Resources). Safe to re-run.
set -eu

APP="${1:-build/Rivulet.app}"
SRC_IN="${ARIA2C_SRC:-/opt/homebrew/bin/aria2c}"

die() { echo "bundle_aria2: error: $*" >&2; exit 1; }

[ -d "$APP/Contents" ] || die "not an app bundle (no Contents/): $APP"

resolve() {
    p="$1"
    while [ -L "$p" ]; do
        l=$(readlink "$p")
        case "$l" in
            /*) p="$l" ;;
            *) p="$(dirname "$p")/$l" ;;
        esac
    done
    d=$(cd "$(dirname "$p")" && pwd -P)
    echo "$d/$(basename "$p")"
}

[ -e "$SRC_IN" ] || die "aria2c not found at $SRC_IN (brew install aria2)"
ARIA_SRC=$(resolve "$SRC_IN")

RES="$APP/Contents/Resources"
FW="$APP/Contents/Frameworks"
mkdir -p "$RES" "$FW"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/bundle_aria2.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM
QUEUE="$TMP/queue"
echo "$ARIA_SRC|$RES/aria2c" > "$QUEUE"

# aria2c loads OpenSSL's "legacy" provider at startup (Platform.cc) and aborts if it is missing.
# Bundle it too; the app must launch aria2c with OPENSSL_MODULES=<app>/Contents/Frameworks/ossl-modules.
CRYPTO_REF=$(otool -L "$ARIA_SRC" | awk '/libcrypto/ {print $1; exit}')
if [ -n "$CRYPTO_REF" ] && [ -e "$CRYPTO_REF" ]; then
    LEGACY="$(dirname "$(resolve "$CRYPTO_REF")")/ossl-modules/legacy.dylib"
    [ -e "$LEGACY" ] || die "OpenSSL legacy provider not found at $LEGACY"
    echo "$(resolve "$LEGACY")|$FW/ossl-modules/legacy.dylib" >> "$QUEUE"
fi

# Remove files from a previous run so the Frameworks folder matches the dependency closure.
rm -rf "$FW/ossl-modules"
for old in "$FW"/*.dylib; do
    [ -e "$old" ] && rm -f "$old"
done

n=1
while [ "$n" -le "$(wc -l < "$QUEUE" | tr -d ' ')" ]; do
    line=$(sed -n "${n}p" "$QUEUE")
    src=${line%%|*}
    dest=${line#*|}
    srcdir=$(dirname "$src")

    rm -f "$dest"
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    chmod 755 "$dest"
    codesign --remove-signature "$dest" >/dev/null 2>&1 || true

    case "$dest" in
        "$FW"/*) install_name_tool -id "@executable_path/../Frameworks/${dest#"$FW"/}" "$dest" ;;
    esac

    otool -L "$src" | tail -n +2 | awk '{print $1}' > "$TMP/deps"
    while IFS= read -r dep; do
        case "$dep" in
            /usr/lib/*|/System/*) continue ;;
            @executable_path/../Frameworks/*) continue ;;
        esac
        ref=$(basename "$dep")
        # Skip a dylib's reference to itself (its own id).
        [ "$(basename "$src")" = "$ref" ] && [ "$dest" != "$RES/aria2c" ] && \
            case "$dep" in "$src"|"$(resolve "$src")"|@rpath/*|@loader_path/*) continue ;; esac
        case "$dep" in
            /*) real="$dep" ;;
            @loader_path/*) real="$srcdir/${dep#@loader_path/}" ;;
            @rpath/*)
                real=""
                for dir in "$srcdir" "$srcdir/../lib" /opt/homebrew/lib; do
                    if [ -e "$dir/${dep#@rpath/}" ]; then real="$dir/${dep#@rpath/}"; break; fi
                done
                [ -n "$real" ] || die "cannot resolve $dep (needed by $src)"
                ;;
            *) die "unsupported dependency path $dep (needed by $src)" ;;
        esac
        [ -e "$real" ] || die "missing dependency $real (needed by $src)"
        real=$(resolve "$real")
        entry="$real|$FW/$ref"
        existing=$(grep -F "|$FW/$ref" "$QUEUE" || true)
        if [ -z "$existing" ]; then
            echo "$entry" >> "$QUEUE"
        elif [ "$existing" != "$entry" ]; then
            die "two different libraries map to $ref: $existing vs $entry"
        fi
        install_name_tool -change "$dep" "@executable_path/../Frameworks/$ref" "$dest"
    done < "$TMP/deps"
    n=$((n + 1))
done

# Sign dylibs first, aria2c last.
sign() {
    if [ -n "${SIGN_IDENTITY:-}" ]; then
        codesign --force --sign "$SIGN_IDENTITY" --options runtime --timestamp "$1"
    else
        codesign --force --sign - "$1"
    fi
}
find "$FW" -name '*.dylib' > "$TMP/libs"
while IFS= read -r lib; do
    sign "$lib"
done < "$TMP/libs"
sign "$RES/aria2c"

# Verify: no Homebrew or other non-system absolute paths left.
bad=0
for f in "$RES/aria2c" $(find "$FW" -name '*.dylib' | tr ' ' '?'); do
    [ -e "$f" ] || continue
    leftovers=$(otool -L "$f" | tail -n +2 | awk '{print $1}' | grep -E '^/' | grep -Ev '^(/usr/lib/|/System/)' || true)
    if [ -n "$leftovers" ]; then
        echo "bundle_aria2: $f still references:" >&2
        echo "$leftovers" >&2
        bad=1
    fi
    if otool -L "$f" | grep -q '/opt/homebrew'; then bad=1; fi
done
[ "$bad" -eq 0 ] || die "bundled binaries still reference non-system paths"

# Run the bundled copy from a temp location, with Homebrew hidden when sandbox-exec allows it.
CHECK="$TMP/check"
mkdir -p "$CHECK"
cp -R "$APP" "$CHECK/App.app"
if [ -x /usr/bin/sandbox-exec ]; then
    VERSION_LINE=$(env -i PATH=/usr/bin:/bin OPENSSL_MODULES="$CHECK/App.app/Contents/Frameworks/ossl-modules" /usr/bin/sandbox-exec \
        -p '(version 1)(allow default)(deny file-read* (subpath "/opt/homebrew"))(deny file-read* (subpath "/usr/local"))' \
        "$CHECK/App.app/Contents/Resources/aria2c" --version 2>&1 | head -n 1) || VERSION_LINE=""
    HIDDEN="homebrew hidden via sandbox-exec"
else
    VERSION_LINE=$(env -i PATH=/usr/bin:/bin OPENSSL_MODULES="$CHECK/App.app/Contents/Frameworks/ossl-modules" "$CHECK/App.app/Contents/Resources/aria2c" --version 2>&1 | head -n 1) || VERSION_LINE=""
    HIDDEN="otool check only (sandbox-exec unavailable)"
fi
case "$VERSION_LINE" in
    aria2*) ;;
    *) die "bundled aria2c failed to run: '$VERSION_LINE'" ;;
esac

KB=$(du -sk "$RES/aria2c" "$FW" | awk '{s+=$1} END {print s}')
MB=$(awk -v k="$KB" 'BEGIN {printf "%.1f", k/1024}')
COUNT=$(find "$FW" -name '*.dylib' | wc -l | tr -d ' ')

echo "----------------------------------------"
echo "aria2c bundled into: $APP"
echo "  source:    $ARIA_SRC"
echo "  version:   $VERSION_LINE"
echo "  dylibs:    $COUNT in Contents/Frameworks (incl. ossl-modules/legacy.dylib)"
echo "  NOTE:      launch aria2c with OPENSSL_MODULES=<app>/Contents/Frameworks/ossl-modules"
echo "  added:     ${MB} MB"
echo "  signed:    ${SIGN_IDENTITY:-ad hoc}"
echo "  verified:  no non-system paths; ran from temp copy ($HIDDEN)"
echo "----------------------------------------"
