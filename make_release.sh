#!/usr/bin/env bash
# ======================================================================
# make_release.sh - makes the easy-install DMG and (optionally) publishes it
# ======================================================================
#   bash make_release.sh 1.0.0
#
# What it does, step by step:
#   1. Checks everything is committed and already on GitHub, so the
#      download matches the published code exactly.
#   2. Builds SpaceKeeper for both Apple silicon and Intel Macs, signed with
#      your SpaceKeeper certificate (you'll type the signing keychain password).
#   3. Makes build/release/SpaceKeeper-1.0.0.dmg: a window with the app, an
#      Applications shortcut to drag it onto, and the illustrated
#      "First time opening SpaceKeeper" guide.
#   4. Checks the DMG: opens it, makes sure the app inside is complete and
#      correctly signed, and closes it again.
#   5. Writes SHA256SUMS.txt (a fingerprint people can use to check their
#      download) and the release notes.
#   6. Asks before publishing them as a GitHub Release.
#
# The first run also downloads dmgbuild (the tool that arranges the DMG
# window) into build/dmg-tools. Its exact files are pinned by checksum in
# Resources/dmg/requirements.txt.
# ======================================================================
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${1:-}"
VERSION="${VERSION#v}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: bash make_release.sh 1.0.0"
  exit 1
fi
TAG="v${VERSION}"
OUT="build/release"
DMG="${OUT}/SpaceKeeper-${VERSION}.dmg"

# ---------------------------------------------------------------- 1. checks
[[ "$(uname)" == "Darwin" ]] || { echo "✗ This needs to run on a Mac."; exit 1; }
command -v gh >/dev/null 2>&1 || { echo "✗ GitHub's gh tool isn't installed. Run bash publish_to_github.sh once first."; exit 1; }
REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
[[ -n "$REPO" ]] || { echo "✗ Couldn't find this project on GitHub. Run bash publish_to_github.sh first."; exit 1; }

if [[ -n "$(git status --porcelain)" ]]; then
  echo "✗ Some changes aren't committed yet:"
  git status --short
  echo "  Commit them and run bash publish_to_github.sh, then try again."
  exit 1
fi
git fetch --quiet origin
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse '@{u}' 2>/dev/null || echo none)" ]]; then
  echo "✗ This Mac's copy isn't the same as GitHub's. Run bash publish_to_github.sh first."
  exit 1
fi
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null || gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  echo "✗ ${TAG} already exists. Choose a higher version number."
  exit 1
fi

# ---------------------------------------------------------------- 2. build
echo "▸ Building SpaceKeeper ${VERSION} for Apple silicon and Intel Macs…"
APP_VERSION="$VERSION" UNIVERSAL=1 ./build.sh
APP="$PWD/build/SpaceKeeper.app"

# ---------------------------------------------------------------- 3. DMG
TOOLS="build/dmg-tools"
if [[ ! -x "$TOOLS/bin/dmgbuild" ]]; then
  echo "▸ Setting up dmgbuild (first time only)…"
  rm -rf "$TOOLS"
  /usr/bin/python3 -m venv "$TOOLS"
  "$TOOLS/bin/pip" install --quiet --disable-pip-version-check \
    --require-hashes --no-deps --only-binary=:all: -r Resources/dmg/requirements.txt
fi

echo "▸ Making ${DMG}…"
rm -rf "$OUT"; mkdir -p "$OUT"
"$TOOLS/bin/dmgbuild" -s Resources/dmg/dmg_settings.py \
  -D app="$APP" -D here="$PWD/Resources/dmg" \
  "SpaceKeeper" "$DMG"

# ---------------------------------------------------------------- 4. check it
echo "▸ Checking the DMG…"
hdiutil verify -quiet "$DMG"
MOUNT="$(mktemp -d)"
hdiutil attach -quiet -readonly -nobrowse -mountpoint "$MOUNT" "$DMG"
detach() { hdiutil detach -quiet "$MOUNT" 2>/dev/null || hdiutil detach -quiet -force "$MOUNT" 2>/dev/null || true; rmdir "$MOUNT" 2>/dev/null || true; }
trap detach EXIT
for item in "SpaceKeeper.app" "Applications" "First time opening SpaceKeeper.pdf"; do
  [[ -e "$MOUNT/$item" ]] || { echo "✗ The DMG is missing “${item}”."; exit 1; }
done
codesign --verify --strict "$MOUNT/SpaceKeeper.app"
SHOWN="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$MOUNT/SpaceKeeper.app/Contents/Info.plist")"
[[ "$SHOWN" == "$VERSION" ]] || { echo "✗ The app inside says version ${SHOWN}, not ${VERSION}."; exit 1; }
echo "  OK: app signed and complete, version ${SHOWN}, runs on $(lipo -archs "$MOUNT/SpaceKeeper.app/Contents/MacOS/SpaceKeeper")."
detach; trap - EXIT

# ---------------------------------------------------------------- 5. checksum and notes
( cd "$OUT" && shasum -a 256 "SpaceKeeper-${VERSION}.dmg" > SHA256SUMS.txt )
SUM="$(cut -d' ' -f1 "$OUT/SHA256SUMS.txt")"
cat > "$OUT/notes.md" <<NOTES
## Install

1. Download **SpaceKeeper-${VERSION}.dmg** below and double-click it.
2. Drag the **SpaceKeeper** icon onto the **Applications** folder.
3. The first time you open it, macOS asks you to confirm. Double-click **First time opening SpaceKeeper** in the same window for the step-by-step guide (about a minute, once only).

Needs macOS 26 or later. Works on Apple silicon and Intel Macs.

**Already have SpaceKeeper?** Quit it from its menu bar panel, then drag the new version onto Applications and choose **Replace**. Your names, colours and pins are kept.

## Why does macOS ask me to confirm?

SpaceKeeper is free and isn't registered with Apple's paid developer programme, so macOS can't check it for you. Its code is all here on GitHub for anyone to read. Only download it from this page.

## Check your download (optional)

In Terminal, run \`shasum -a 256 ~/Downloads/SpaceKeeper-${VERSION}.dmg\`. The result should be:

\`${SUM}\`
NOTES

echo ""
echo "✓ Made:"
ls -lh "$OUT" | sed '1d;s/^/    /'
echo ""
echo "  Try it first: double-click ${DMG} in Finder."
echo ""

# ---------------------------------------------------------------- 6. publish
read -r -p "Publish SpaceKeeper ${VERSION} on GitHub now (anyone will be able to download it)? [y/N] " answer
case "$answer" in
  [yY]*)
    gh release create "$TAG" "$DMG" "$OUT/SHA256SUMS.txt" \
      --repo "$REPO" --target "$(git rev-parse HEAD)" \
      --title "SpaceKeeper ${VERSION}" --notes-file "$OUT/notes.md"
    git fetch --quiet --tags origin
    echo "✓ Published: https://github.com/${REPO}/releases/tag/${TAG}"
    echo "  Always-latest download link: https://github.com/${REPO}/releases/latest"
    ;;
  *) echo "Not published. Run this again when you're ready (it will rebuild)." ;;
esac
