#!/usr/bin/env bash
#
# create-local-signing-cert.sh
#
# Creates a stable, self-signed code-signing certificate named
# "VoiceInk Local Signing" in the user's login keychain.
#
# WHY THIS EXISTS
# ---------------
# `make local` previously signed ad-hoc (CODE_SIGN_IDENTITY="-"). Ad-hoc
# signatures have NO stable designated requirement — the requirement is
# literally `cdhash H"<content hash>"`. macOS TCC keys Accessibility and
# Input Monitoring grants to that requirement, so EVERY rebuild produced a
# new cdhash and silently revoked all permission grants. Symptom: you enable
# Accessibility, the app still says it's not granted, and the global-hotkey
# event tap (which needs Accessibility) never fires.
#
# Signing with a fixed self-signed cert changes the designated requirement to
# `identifier "com.prakashjoshipax.VoiceInk" and certificate leaf = H"<cert>"`,
# which is STABLE across rebuilds. Grant the permissions once; they stick.
#
# This is a one-time setup per machine. Re-running is safe (idempotent-ish:
# it will add a second cert if the name already exists, so it checks first).
#
# Requirements: Homebrew openssl (openssl 3.x) OR LibreSSL. Uses -legacy p12
# format so macOS `security import` can read it.

set -euo pipefail

CERT_NAME="VoiceInk Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Bail if a valid identity already exists.
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "✓ '$CERT_NAME' already exists and is valid. Nothing to do."
  security find-identity -v -p codesigning | grep "$CERT_NAME"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cd "$WORK"

P12PASS="voiceink-local"

cat > cert.cnf <<'EOF'
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = VoiceInk Local Signing
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

echo "Generating self-signed code-signing certificate (10-year validity)..."
openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem \
  -days 3650 -nodes -sha256 -config cert.cnf >/dev/null 2>&1

# -legacy: emit RC2/3DES + SHA1-MAC p12 that macOS `security` can import.
# (OpenSSL 3 defaults to AES-256 MAC, which `security import` rejects.)
LEGACY_FLAG="-legacy"
if ! openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
  LEGACY_FLAG=""   # LibreSSL has no -legacy and already emits a compatible format
fi

openssl pkcs12 -export $LEGACY_FLAG \
  -inkey key.pem -in cert.pem \
  -out identity.p12 -passout pass:"$P12PASS" \
  -name "$CERT_NAME" >/dev/null 2>&1

echo "Importing into login keychain..."
security import identity.p12 -k "$KEYCHAIN" -P "$P12PASS" -T /usr/bin/codesign

echo ""
echo ">>> macOS will prompt for your LOGIN password to TRUST the cert for code signing."
echo ""
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" cert.pem

echo ""
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
  echo "✓ Done. '$CERT_NAME' is installed and valid for code signing."
  echo "  Run 'make local' — it will detect and use this identity automatically."
else
  echo "✗ Cert was imported but is not showing as valid. Check Keychain Access" >&2
  echo "  → login keychain → '$CERT_NAME' → Trust → Code Signing = Always Trust." >&2
  exit 1
fi
