#!/bin/zsh
# Libertty's own code-signing certificate, self-signed (no Developer ID):
#   scripts/codesign-identity.sh            unlock it; print "HASH KEYCHAIN" (exit 1 if there's none)
#   scripts/codesign-identity.sh --create   make it, once (refuses if there is one)
#   scripts/codesign-identity.sh --requirement APP_OR_BINARY
#                                           whether it's signed with it (prints the designated requirement)
#
# Why: an ad-hoc signature's designated requirement is the build's own hash
# (cdhash), so macOS takes every update for a new app and the permissions it
# gave Libertty and liberttyd (Full Disk Access, Screen Recording, Accessibility)
# don't carry over. Signed with one certificate, the requirement is
# `identifier "…" and certificate leaf = H"…"`, the same in every build.
# It isn't trusted by anyone and doesn't replace notarization: Gatekeeper asks
# as before on a first launch.
#
# The certificate and its key live in a keychain of their own beside the
# update key, ~/.config/libertty-release/codesign.keychain-db (its password in
# codesign.password), never in the login keychain. Keep that folder backed up:
# a new certificate makes everyone grant the permissions again, once.
set -euo pipefail
DIR=${LIBERTTY_CODESIGN_DIR:-$HOME/.config/libertty-release}
KEYCHAIN=$DIR/codesign.keychain-db
PASSWORD_FILE=$DIR/codesign.password
NAME="Libertty Self-Signed"

identity() { security find-identity -p codesigning $KEYCHAIN 2>/dev/null | awk -v n="\"$NAME\"" 'index($0, n) {print $2; exit}'; }

case ${1:-} in
  --create)
    [[ -e $KEYCHAIN ]] && { echo "there's one already: $KEYCHAIN"; exit 1; }
    mkdir -p $DIR
    chmod 700 $DIR
    WORK=$(mktemp -d)
    trap 'rm -rf $WORK' EXIT
    cat > $WORK/cert.cnf <<EOF
[req]
distinguished_name = dn
prompt = no
x509_extensions = ext
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
subjectKeyIdentifier = hash
EOF
    # Twenty years: the certificate is the identity; it mustn't change.
    /usr/bin/openssl req -x509 -newkey rsa:3072 -nodes -keyout $WORK/key.pem -out $WORK/cert.pem -days 7300 \
      -config $WORK/cert.cnf 2> /dev/null
    P12=$(/usr/bin/openssl rand -hex 16)
    # (macOS's own LibreSSL: a newer OpenSSL's PKCS#12 defaults are ones `security import` can't read.)
    /usr/bin/openssl pkcs12 -export -inkey $WORK/key.pem -in $WORK/cert.pem -out $WORK/id.p12 -passout pass:$P12 -name "$NAME"
    (umask 077; /usr/bin/openssl rand -hex 24 > $PASSWORD_FILE)
    security create-keychain -p "$(cat $PASSWORD_FILE)" $KEYCHAIN
    chmod 600 $KEYCHAIN
    security set-keychain-settings $KEYCHAIN  # no auto-lock timeout
    security unlock-keychain -p "$(cat $PASSWORD_FILE)" $KEYCHAIN
    security import $WORK/id.p12 -k $KEYCHAIN -P $P12 -T /usr/bin/codesign -f pkcs12 > /dev/null
    # codesign may use the key without asking.
    security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat $PASSWORD_FILE)" $KEYCHAIN > /dev/null
    echo "made $KEYCHAIN: $(identity) \"$NAME\""
    echo "keep $DIR backed up: a new certificate makes everyone grant permissions again"
    ;;
  --requirement)
    TARGET=${2:?usage: scripts/codesign-identity.sh --requirement APP_OR_BINARY}
    REQ=$(codesign -d -r- $TARGET 2>&1 | sed -n 's/^designated => //p')
    echo $REQ
    [[ $REQ == *"certificate leaf = H\""* ]]
    ;;
  "")
    [[ -f $KEYCHAIN && -f $PASSWORD_FILE ]] || exit 1
    security unlock-keychain -p "$(cat $PASSWORD_FILE)" $KEYCHAIN
    HASH=$(identity)
    [[ -n $HASH ]] || { echo "no \"$NAME\" in $KEYCHAIN" >&2; exit 1; }
    echo "$HASH $KEYCHAIN"
    ;;
  *) echo "usage: scripts/codesign-identity.sh [--create | --requirement APP_OR_BINARY]"; exit 2 ;;
esac
