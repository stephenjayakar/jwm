#!/bin/sh
# Creates a self-signed code-signing identity "jwm Local Signing" in its own keychain.
# A stable signature lets macOS keep the Accessibility grant across rebuilds
# (ad-hoc signatures change every build, so macOS treats each build as a new app).
# The keychain has a fixed password and no auto-lock, so codesign never prompts.
set -e
NAME="jwm Local Signing"
KC="$HOME/Library/Keychains/jwm-signing.keychain-db"
PW=jwm

if security find-identity -p codesigning "$KC" 2>/dev/null | grep -q "$NAME"; then
    echo "identity \"$NAME\" already exists in $KC"
    exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cert.cnf" <<CNF
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
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
    -days 3650 -config "$TMP/cert.cnf" 2>/dev/null
openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -out "$TMP/id.p12" \
    -passout pass:$PW -name "$NAME" 2>/dev/null

[ -e "$KC" ] || security create-keychain -p $PW "$KC"
security set-keychain-settings "$KC"
security unlock-keychain -p $PW "$KC"
security import "$TMP/id.p12" -k "$KC" -P $PW -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k $PW "$KC" >/dev/null
# Add the keychain to the search list, keeping the existing ones.
EXISTING=$(security list-keychains -d user | tr -d '"')
case "$EXISTING" in *jwm-signing*) ;; *) security list-keychains -d user -s $EXISTING "$KC" ;; esac
echo "created \"$NAME\" in $KC"
