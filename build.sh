#!/usr/bin/env bash
# Builds SpaceKeeper.app from the Swift package.
#   ./build.sh            → build/SpaceKeeper.app
#   ./build.sh --install  → also copies it to ~/Applications and launches it
#
# Signing: macOS ties the Accessibility permission to the app's signature. An
# ad-hoc signature changes on every build, so the permission would be lost each
# time. This script signs with a stable identity, in this order:
#   1. $SIGN_IDENTITY, if set
#   2. an "Apple Development" certificate, if you have one
#   3. "SpaceKeeper Local Signing", a self-signed certificate this script
#      creates in your login keychain the first time it runs
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SpaceKeeper"
BUNDLE_ID="com.flowerdew.SpaceKeeper"
APP="build/${APP_NAME}.app"
LOCAL_CERT="SpaceKeeper Local Signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# $2 = "-v" to list only identities macOS fully trusts. A self-signed
# certificate isn't "trusted", but codesign can still sign with it.
find_identity() {
  security find-identity ${2:-} -p codesigning 2>/dev/null \
    | grep -F "\"$1" | head -1 | sed -E 's/^ *[0-9]+\) ([0-9A-F]{40}) .*/\1/' || true
}

create_local_identity() {
  echo "▸ Creating a self-signed code-signing certificate (“${LOCAL_CERT}”)…"
  local tmp; tmp="$(mktemp -d)"
  cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $LOCAL_CERT
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$tmp/cert.cnf" -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1

  # macOS's keychain can't read PKCS#12 files made with OpenSSL 3's defaults.
  local legacy=""
  /usr/bin/openssl version | grep -q "^OpenSSL 3" && legacy="-legacy"
  /usr/bin/openssl pkcs12 -export $legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "$LOCAL_CERT" -out "$tmp/identity.p12" -passout pass:spacekeeper

  security import "$tmp/identity.p12" -k "$KEYCHAIN" -P spacekeeper -T /usr/bin/codesign >/dev/null
  rm -rf "$tmp"
  echo "  Created. If macOS asks whether codesign may use the key, click “Always Allow”."
  NEW_IDENTITY=1
}

NEW_IDENTITY=0
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  IDENTITY="$SIGN_IDENTITY"
else
  IDENTITY="$(find_identity "Apple Development" -v)"
  if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(find_identity "$LOCAL_CERT")"
    if [[ -z "$IDENTITY" ]]; then
      create_local_identity
      IDENTITY="$(find_identity "$LOCAL_CERT")"
    fi
  fi
fi
if [[ -z "$IDENTITY" ]]; then
  echo "✗ Couldn't find or create a signing certificate. Open Keychain Access and"
  echo "  check for “${LOCAL_CERT}” in the login keychain, then run this again."
  exit 1
fi

echo "▸ Building (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

echo "▸ Signing with ${IDENTITY}…"
codesign --force --options runtime --timestamp=none --sign "$IDENTITY" "$APP"
codesign --verify "$APP"

if [[ "$NEW_IDENTITY" == 1 ]]; then
  # The old permission belonged to the ad-hoc build; clear it so it can be granted once more.
  tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
  echo "▸ Cleared the old Accessibility permission — grant it once more after launch."
fi

if [[ "${1:-}" == "--install" ]]; then
  mkdir -p "$HOME/Applications"
  # Quit the running copy and wait for it to exit before replacing it.
  pkill -x "$APP_NAME" 2>/dev/null || true
  for _ in {1..25}; do pgrep -x "$APP_NAME" >/dev/null || break; sleep 0.2; done
  rm -rf "$HOME/Applications/${APP_NAME}.app"
  ditto "$APP" "$HOME/Applications/${APP_NAME}.app"
  sleep 0.5
  open "$HOME/Applications/${APP_NAME}.app" || { sleep 1; open "$HOME/Applications/${APP_NAME}.app"; }
  echo "✓ Installed to ~/Applications and launched."
else
  echo "✓ Built $APP — run: open $APP"
fi
