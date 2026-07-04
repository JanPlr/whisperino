#!/bin/bash
# One-time setup: create a stable self-signed code-signing identity so macOS
# TCC permissions (Accessibility, Screen Recording) survive rebuilds.
#
#   ./setup-signing.sh
#
# Why: build.sh normally ad-hoc signs (codesign --sign -), which gives the app a
# different code hash on every build. macOS ties Screen Recording / Accessibility
# grants to that hash, so every rebuild looks like a brand-new app and the
# permission is dropped - you have to re-approve (and relaunch) constantly.
#
# Signing with a fixed self-signed certificate gives the app a stable code
# identity, so you approve the permissions ONCE and they stick across all future
# builds. This only affects your local machine; the GitHub release build is
# unchanged.
#
# Safe to re-run: it no-ops if the identity already exists.
set -eo pipefail

IDENTITY="Whisperino Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "✓ Identity '$IDENTITY' already exists - nothing to do."
    exit 0
fi

echo "==> Creating self-signed code-signing certificate '$IDENTITY'..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cfg" <<CFG
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CFG

openssl req -x509 -newkey rsa:2048 -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -nodes -config "$TMP/cfg" >/dev/null 2>&1
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -out "$TMP/id.p12" -passout pass: -name "$IDENTITY" >/dev/null 2>&1

# Import cert + private key into the login keychain and pre-authorize codesign
# to use the key (so signing doesn't pop an "allow" dialog every build).
security import "$TMP/id.p12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign

echo ""
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
    echo "  ✓ '$IDENTITY' created."
    echo ""
    echo "  Next:"
    echo "   1. Run ./build.sh - it will now sign with this identity."
    echo "   2. Approve Accessibility + Screen Recording ONCE, then relaunch"
    echo "      Whisperino (Quit & Reopen). From then on they persist across builds."
else
    echo "  ✗ Something went wrong - identity not found after import." >&2
    exit 1
fi
