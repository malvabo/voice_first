#!/usr/bin/env bash
# Creates a persistent self-signed code-signing identity named "Voi Code Signing"
# in your login keychain. Run this ONCE. After that, build-app.sh signs Voi with
# a stable signature, so the Accessibility and Input Monitoring permissions you
# grant survive every rebuild instead of resetting each time.
#
# This is a local development identity only — it is not trusted by Gatekeeper
# and is not for distribution. It exists purely to stabilize the app's TCC
# (permissions) identity.
set -euo pipefail

IDENTITY="${VOI_SIGN_IDENTITY:-Voi Code Signing}"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "Identity '$IDENTITY' already exists. Nothing to do."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

KEY="$WORK/voi.key"
CERT="$WORK/voi.crt"
P12="$WORK/voi.p12"
CONFIG="$WORK/voi.cnf"
P12_PASS="voi-local"

# x509v3 extensions: mark the cert for code signing.
cat > "$CONFIG" <<'CNF'
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3

[ dn ]
CN = Voi Code Signing

[ v3 ]
basicConstraints       = critical,CA:false
keyUsage               = critical,digitalSignature
extendedKeyUsage       = critical,codeSigning
CNF

echo "Generating self-signed code-signing certificate..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$KEY" -out "$CERT" -days 3650 \
  -config "$CONFIG" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$KEY" -in "$CERT" \
  -out "$P12" -passout "pass:$P12_PASS" -name "$IDENTITY" >/dev/null 2>&1

LOGIN_KEYCHAIN="$(security login-keychain | tr -d ' "')"
echo "Importing into login keychain ($LOGIN_KEYCHAIN)..."
security import "$P12" -k "$LOGIN_KEYCHAIN" \
  -P "$P12_PASS" -T /usr/bin/codesign -T /usr/bin/security

# Allow codesign to use the key without an interactive prompt each build.
security set-key-partition-list -S apple-tool:,apple: -s -k "" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 || \
  echo "note: could not set partition list automatically; you may be prompted by codesign on first build."

echo
echo "Done. '$IDENTITY' is now available:"
security find-identity -v -p codesigning | grep -F "$IDENTITY" || true
echo
echo "Now run ./Scripts/build-app.sh — it will sign with this identity."
echo "Grant Voi Accessibility + Input Monitoring once; the grants will persist across rebuilds."
