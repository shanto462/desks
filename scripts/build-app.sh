#!/bin/bash
# Builds build/Desks.app from the Swift package.
#
# Usage: scripts/build-app.sh
#
# Signing: uses the "Desks Dev" identity from scripts/make-signing-identity.sh when it
# exists, so the Accessibility permission survives rebuilds. Without it the build is
# signed ad-hoc and macOS forgets the permission after every rebuild.
#   DESKS_SIGN_IDENTITY=<name or SHA-1>   use another identity from your keychains
#   DESKS_SIGN_IDENTITY=-                 force ad-hoc
#   CI=true or DESKS_CI=1                 CI mode: always ad-hoc, never touches any keychain
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

APP="$ROOT/build/Desks.app"
SIGN_KEYCHAIN="${DESKS_SIGN_KEYCHAIN:-$HOME/Library/Keychains/desks-dev.keychain-db}"
SIGN_PASSFILE="${DESKS_SIGN_DIR:-$HOME/Library/Application Support/Desks/signing}/keychain-password"

# 1. Swift app
swift build -c release --arch arm64 --product Desks
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

# 2. Bundle. Recreate Resources so stale files do not stay; the path stays the same.
mkdir -p "$APP/Contents/MacOS"
rm -rf "$APP/Contents/Resources"
mkdir -p "$APP/Contents/Resources"
cp -f "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
cp -f "$BIN_DIR/Desks" "$APP/Contents/MacOS/Desks"
chmod 755 "$APP/Contents/MacOS/Desks"
# MIT requires the notices to travel with binaries.
cp -f "$ROOT/LICENSE" "$APP/Contents/Resources/LICENSE.txt"
cp -f "$ROOT/THIRD_PARTY_NOTICES.md" "$APP/Contents/Resources/THIRD_PARTY_NOTICES.md"
# SwiftPM resource bundles (KeyboardShortcuts localizations). Bundle.module looks for
# them in Contents/Resources of the app.
shopt -s nullglob
for b in "$BIN_DIR"/*.bundle; do
    cp -R "$b" "$APP/Contents/Resources/"
    echo "Resource bundle: $(basename "$b")"
done
shopt -u nullglob

# 3. Sign with the hardened runtime.
# The default designated requirement for a certificate signature is
# `identifier "<id>" and certificate leaf = H"<cert SHA-1>"`, which is what TCC stores.
KEYCHAIN_ARGS=()
LOCK_AFTER=""
if [[ -n "${DESKS_SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$DESKS_SIGN_IDENTITY"
elif [[ "${CI:-}" == "true" || "${DESKS_CI:-}" == "1" ]]; then
    # CI machines have no signing identity. Do not look at or unlock any keychain.
    IDENTITY="-"
    echo "CI mode: signing ad-hoc, no keychain is used."
elif [[ -f "$SIGN_KEYCHAIN" && -f "$SIGN_PASSFILE" ]]; then
    # Unlock only for the signing, with the password on stdin (not in argv, so `ps`
    # cannot see it). The key's partition list allows codesign, so no dialog appears.
    # Do not call `security show-keychain-info` here: on a locked keychain it opens a dialog.
    out="$(printf 'unlock-keychain -p %s %s\n' "$(<"$SIGN_PASSFILE")" "$SIGN_KEYCHAIN" | security -i 2>&1)"
    if grep -qiE "returned -|not correct" <<<"$out"; then
        echo "Could not unlock $SIGN_KEYCHAIN with the stored password." >&2
        echo "Move that keychain and the signing folder away, then run scripts/make-signing-identity.sh." >&2
        exit 1
    fi
    LOCK_AFTER="$SIGN_KEYCHAIN"
    trap 'security lock-keychain "$LOCK_AFTER" 2>/dev/null || true' EXIT
    # SHA-1 of the "Desks Dev" identity (self-signed, so not "valid", which is fine).
    IDENTITY="$(security find-identity -p codesigning "$SIGN_KEYCHAIN" | awk '/"Desks Dev"/ {print $2; exit}')"
    [[ -n "$IDENTITY" ]] || { echo "No \"Desks Dev\" identity in $SIGN_KEYCHAIN" >&2; exit 1; }
    KEYCHAIN_ARGS=(--keychain "$SIGN_KEYCHAIN")
elif [[ -f "$SIGN_KEYCHAIN" ]]; then
    IDENTITY="-"
    echo "WARNING: $SIGN_KEYCHAIN exists but the password file is missing:" >&2
    echo "WARNING: $SIGN_PASSFILE" >&2
    echo "WARNING: signing AD-HOC, so macOS will forget the Accessibility permission." >&2
    echo "WARNING: Fix: run scripts/make-signing-identity.sh --reset, then build again." >&2
else
    IDENTITY="-"
    echo "warning: no \"Desks Dev\" identity, signing ad-hoc. macOS will forget the" >&2
    echo "warning: Accessibility permission after each rebuild. Run scripts/make-signing-identity.sh." >&2
fi

codesign --force --sign "$IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} \
    --options runtime --identifier io.github.desks.app "$APP"
if [[ -n "$LOCK_AFTER" ]]; then security lock-keychain "$LOCK_AFTER"; LOCK_AFTER=""; trap - EXIT; fi
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated

echo "Built $APP"
