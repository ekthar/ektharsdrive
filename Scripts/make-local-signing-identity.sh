#!/bin/bash
# Creates a local, self-signed code-signing identity "Ekthar Drive Local" in your login keychain.
#
# Why: ad-hoc signed builds get a new identity on every rebuild, so macOS asks for your password
# again for the app's Keychain item each time. Signing every build with the same local certificate
# lets "Always Allow" stick across rebuilds.
#
# This only affects builds on this Mac. It is not an Apple Developer ID and does not notarize.
# Undo:  security delete-identity -c "Ekthar Drive Local"
set -euo pipefail
NAME="Ekthar Drive Local"
if security find-identity -v -p codesigning | grep -q "$NAME"; then
  echo "\"$NAME\" already exists."; exit 0
fi
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
cat > "$WORK/cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cfg" 2>/dev/null
PASS="$(openssl rand -hex 16)"
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -out "$WORK/id.p12" -passout "pass:$PASS" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" -out "$WORK/id.p12" -passout "pass:$PASS"
security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" -P "$PASS" -T /usr/bin/codesign
echo "Created \"$NAME\". Rebuild with Scripts/build-app.sh; it is used automatically."
