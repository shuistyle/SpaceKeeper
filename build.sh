#!/usr/bin/env bash
# Builds SpaceKeeper.app from the Swift package.
#   ./build.sh            → build/SpaceKeeper.app
#   ./build.sh --install  → also copies it to ~/Applications and launches it
#
# SIGNING — why it matters
# macOS ties SpaceKeeper's Accessibility permission (which lets it watch the
# keyboard and press keys) to the certificate the app is signed with. Anyone
# who can sign with that certificate can make an app that macOS treats as
# SpaceKeeper — and that inherits the permission.
#
# So the signing certificate lives in its OWN keychain,
#   ~/Library/Keychains/spacekeeper-signing.keychain-db
# protected by a password you choose. It's unlocked only while this script
# signs the app, then locked again straight away (and it locks itself after
# 5 minutes or when the Mac sleeps). A program running in the background
# can't use a locked keychain, so it can't sign as SpaceKeeper.
#
# You'll be asked for that keychain password each time you build. (It isn't
# your Mac login password unless you choose to make it the same — better not.)
#
# Advanced: set SIGN_IDENTITY to sign with a certificate of your own instead.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SpaceKeeper"
BUNDLE_ID="com.flowerdew.SpaceKeeper"
APP="build/${APP_NAME}.app"
SIGN_CERT="SpaceKeeper Signing"
SIGN_KEYCHAIN="$HOME/Library/Keychains/spacekeeper-signing.keychain-db"
LOGIN_KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
OLD_CERT="SpaceKeeper Local Signing"   # earlier versions kept this in the login keychain

# Finds the SHA-1 fingerprint of a code-signing identity by name (in one keychain).
find_identity() {
  security find-identity -p codesigning "$2" 2>/dev/null \
    | grep -F "\"$1\"" | head -1 | sed -E 's/^ *[0-9]+\) ([0-9A-F]{40}) .*/\1/' || true
}

# Everything that must happen however the script ends (success, error, Ctrl-C):
#   • lock the signing keychain again
#   • delete the temporary folder that briefly holds a new private key
SIGNING_TMP=""
cleanup() {
  [[ -n "$SIGNING_TMP" ]] && rm -rf "$SIGNING_TMP"
  SIGNING_TMP=""
  [[ -f "$SIGN_KEYCHAIN" ]] && security lock-keychain "$SIGN_KEYCHAIN" 2>/dev/null
  return 0
}
trap cleanup EXIT

create_signing_keychain() {
  echo "▸ Setting up a protected keychain for SpaceKeeper's signing certificate."
  echo "  Choose a password for it (you'll type it each time you build)."
  security create-keychain "$SIGN_KEYCHAIN"          # asks for the new password twice
  security set-keychain-settings -l -u -t 300 "$SIGN_KEYCHAIN"  # auto-lock: 5 min / sleep

  echo "▸ Creating a self-signed code-signing certificate (“${SIGN_CERT}”)…"
  local tmp
  tmp="$(umask 077; mktemp -d)"   # only you can read the folder
  SIGNING_TMP="$tmp"
  local p12pass; p12pass="$(/usr/bin/openssl rand -hex 16)"  # one-time, never stored
  cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $SIGN_CERT
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
  (umask 077; /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -config "$tmp/cert.cnf" -keyout "$tmp/key.pem" -out "$tmp/cert.pem" >/dev/null 2>&1)

  # macOS's keychain can't read PKCS#12 files made with OpenSSL 3's defaults.
  local legacy=""
  /usr/bin/openssl version | grep -q "^OpenSSL 3" && legacy="-legacy"
  /usr/bin/openssl pkcs12 -export $legacy -inkey "$tmp/key.pem" -in "$tmp/cert.pem" \
    -name "$SIGN_CERT" -out "$tmp/identity.p12" -passout "pass:${p12pass}"

  security import "$tmp/identity.p12" -k "$SIGN_KEYCHAIN" -P "$p12pass" -T /usr/bin/codesign >/dev/null
  rm -rf "$tmp"; SIGNING_TMP=""
  echo "  Created. If macOS asks whether codesign may use the key, click “Allow”."
  NEW_IDENTITY=1
}

# Offers to delete the old, unprotected certificate from the login keychain.
remove_old_certificate() {
  [[ -n "$(find_identity "$OLD_CERT" "$LOGIN_KEYCHAIN")" ]] || return 0
  echo ""
  echo "▸ Your login keychain still has the old, unprotected “${OLD_CERT}” certificate."
  echo "  SpaceKeeper no longer uses it; deleting it closes the security gap."
  read -r -p "  Delete it now? [Y/n] " answer
  case "${answer:-y}" in
    [nN]*) echo "  Kept. Run this script again any time to delete it." ;;
    *) security delete-identity -c "$OLD_CERT" "$LOGIN_KEYCHAIN" >/dev/null 2>&1 \
         && echo "  Deleted." \
         || echo "  Couldn't delete it — open Keychain Access › login › My Certificates and delete “${OLD_CERT}”." ;;
  esac
}

NEW_IDENTITY=0
KEYCHAIN_ARGS=()

# Picks the signing identity. Called just before signing, so the keychain is
# unlocked only for the few seconds codesign needs — not during the build.
prepare_signing() {
  if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    IDENTITY="$SIGN_IDENTITY"
    return
  fi
  if [[ ! -f "$SIGN_KEYCHAIN" ]]; then
    create_signing_keychain
  else
    echo "▸ Unlocking SpaceKeeper's signing keychain (type its password)…"
    security unlock-keychain "$SIGN_KEYCHAIN"
  fi
  IDENTITY="$(find_identity "$SIGN_CERT" "$SIGN_KEYCHAIN")"
  if [[ -z "$IDENTITY" ]]; then
    echo "✗ The signing keychain has no “${SIGN_CERT}” certificate."
    echo "  Delete ~/Library/Keychains/spacekeeper-signing.keychain-db and run this again to recreate it."
    exit 1
  fi
  KEYCHAIN_ARGS=(--keychain "$SIGN_KEYCHAIN")
}

echo "▸ Building (release)…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ Assembling ${APP}…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/$APP_NAME" "$APP/Contents/MacOS/$APP_NAME"
cp Resources/Info.plist "$APP/Contents/Info.plist"

prepare_signing
echo "▸ Signing with ${IDENTITY}…"
codesign --force --options runtime --timestamp=none ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --sign "$IDENTITY" "$APP"
# Signed — lock the keychain again now rather than at the end of the script.
[[ -f "$SIGN_KEYCHAIN" ]] && security lock-keychain "$SIGN_KEYCHAIN" 2>/dev/null || true
codesign --verify "$APP"
[[ -z "${SIGN_IDENTITY:-}" ]] && remove_old_certificate

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
