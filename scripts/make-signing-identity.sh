#!/bin/bash
# Creates a self-signed "Desks Dev" code signing identity, once per Mac.
#
# Why: an ad-hoc signature changes on every build, so macOS forgets the Accessibility
# permission. With a fixed certificate the designated requirement stays
# `identifier "io.github.desks.app" and certificate leaf = H"..."`, and the
# permission survives rebuilds.
#
# The identity lives in its own keychain (never the login keychain), with a random
# password in a file only you can read (mode 600). scripts/build-app.sh unlocks the
# keychain with it, signs, and locks it again. Passwords go to `security` on stdin
# (`security -i`) and to openssl as a file, never as command arguments that `ps` shows.
#
# No password dialog can appear: every command that touches the keychain runs while it
# is unlocked with the stored password, and the key's partition list allows codesign.
# Never call `security show-keychain-info` on a locked keychain: that one opens a dialog.
set -euo pipefail

NAME="Desks Dev"
DIR="${DESKS_SIGN_DIR:-$HOME/Library/Application Support/Desks/signing}"
KEYCHAIN="${DESKS_SIGN_KEYCHAIN:-$HOME/Library/Keychains/desks-dev.keychain-db}"
PASSFILE="$DIR/keychain-password"

# Runs `security` subcommands read from stdin, so secrets are not in argv.
# Fails if any of them reports an error.
sec() {
    local out
    out="$(security -i 2>&1)"
    if grep -qiE "error|returned -|not correct|could not" <<<"$out"; then
        echo "$out" | tr '>' '\n' | grep -v '^security$' >&2
        return 1
    fi
}

# --reset deletes the signing keychain and the password file, then creates both again.
# No dialog: delete-keychain on a path needs no password. Accessibility must be granted again.
if [[ "${1:-}" == "--reset" ]]; then
    [[ -e "$KEYCHAIN" ]] && security delete-keychain "$KEYCHAIN" 2>/dev/null
    rm -f "$KEYCHAIN" "$PASSFILE"
    echo "Removed the old signing keychain and password file."
elif [[ -n "${1:-}" ]]; then
    echo "Usage: $0 [--reset]" >&2
    exit 2
fi

if [[ -f "$KEYCHAIN" && -f "$PASSFILE" ]]; then
    echo "Signing keychain already exists: $KEYCHAIN"
    exit 0
fi
if [[ -e "$KEYCHAIN" ]]; then
    echo "The keychain $KEYCHAIN exists, but the password file $PASSFILE is missing." >&2
    echo "Without it the keychain cannot be unlocked. Fix: run  $0 --reset" >&2
    echo "(this deletes that keychain and creates a new one, then grant Accessibility again)." >&2
    exit 1
fi

mkdir -p "$DIR"
chmod 700 "$DIR"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

( umask 077; openssl rand -hex 24 | tr -d '\n' > "$PASSFILE" )
chmod 600 "$PASSFILE"
PASS="$(<"$PASSFILE")"

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -name "$NAME" -out "$WORK/id.p12" -passout "file:$PASSFILE"

# Lock after 5 minutes idle and on sleep. The build unlocks it only while it signs.
sec <<EOT
create-keychain -p $PASS $KEYCHAIN
set-keychain-settings -l -t 300 $KEYCHAIN
unlock-keychain -p $PASS $KEYCHAIN
import $WORK/id.p12 -k $KEYCHAIN -P $PASS -T /usr/bin/codesign
set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PASS $KEYCHAIN
EOT

# Prove the stored password really opens the keychain before relying on it.
security lock-keychain "$KEYCHAIN"
sec <<EOT
unlock-keychain -p $PASS $KEYCHAIN
EOT
security find-identity -p codesigning "$KEYCHAIN" | grep -q "\"$NAME\"" \
    || { echo "The new identity is not usable." >&2; exit 1; }
security lock-keychain "$KEYCHAIN"

echo "Created \"$NAME\" in $KEYCHAIN (locked)."
