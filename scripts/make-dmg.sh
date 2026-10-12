#!/bin/zsh
# Builds Freespan (Release) and packages it as a drag-to-Applications DMG: build/Freespan-<version>.dmg
#
# Signing:
#   - If a "Developer ID Application" identity is in the keychain, the app is re-signed with it (hardened
#     runtime, secure timestamp), the DMG is signed, notarized with the "freespan-notary" keychain profile
#     (xcrun notarytool store-credentials freespan-notary), and the ticket is stapled.
#   - Otherwise the Apple Development signature from the build is kept and a warning is printed: that DMG
#     only opens cleanly on this Mac. Gatekeeper blocks it everywhere else.
#
# Usage: ./scripts/make-dmg.sh            (NOTARY_PROFILE=other-profile to use a different profile)
set -euo pipefail
cd "${0:A:h}/.."
ROOT="$PWD"
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Freespan-release"   # outside ~/Desktop: Desktop xattrs break codesign
NOTARY_PROFILE="${NOTARY_PROFILE:-freespan-notary}"
ENTITLEMENTS="$ROOT/App/Freespan.entitlements"

echo "==> Building Release"
xcodegen generate -q
xcodebuild -project Freespan.xcodeproj -scheme Freespan -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath "$DERIVED" build -quiet
BUILT="$DERIVED/Build/Products/Release/Freespan.app"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT/Contents/Info.plist")

# Work on a copy outside ~/Desktop so signing never sees Finder metadata.
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/freespan-dmg.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT
mkdir "$STAGE/root"
ditto --norsrc --noextattr "$BUILT" "$STAGE/root/Freespan.app"
APP="$STAGE/root/Freespan.app"

DEV_ID=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)

if [[ -n "$DEV_ID" ]]; then
  echo "==> Signing with $DEV_ID (hardened runtime)"
  # Inside-out: any nested code first, then the app. Xcode's development entitlements (get-task-allow)
  # are dropped because only the app's own entitlements file is applied.
  find "$APP/Contents" -depth \( -name '*.framework' -o -name '*.dylib' -o -name '*.xpc' -o -name '*.appex' \
    -o -path '*/Contents/Helpers/*' -o -path '*/Contents/MacOS/*' \) -print0 2>/dev/null |
    while IFS= read -r -d '' item; do
      [[ "$item" == "$APP/Contents/MacOS/Freespan" ]] && continue
      codesign --force --timestamp --options runtime --sign "$DEV_ID" "$item"
    done
  codesign --force --timestamp --options runtime --entitlements "$ENTITLEMENTS" --sign "$DEV_ID" "$APP"
else
  print -P "%F{red}%B"
  print "################################################################################"
  print "#  WARNING: no 'Developer ID Application' identity in the keychain.             #"
  print "#  Keeping the Apple Development signature. This DMG is NOT notarized: macOS    #"
  print "#  Gatekeeper will block it on every Mac except this one. Do not publish it.    #"
  print "################################################################################"
  print -P "%f%b"
fi
codesign --verify --deep --strict --verbose=1 "$APP"

echo "==> Creating DMG"
ln -s /Applications "$STAGE/root/Applications"
mkdir -p "$ROOT/build"
DMG="$ROOT/build/Freespan-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -quiet -volname "Freespan $VERSION" -srcfolder "$STAGE/root" -fs HFS+ -format UDZO -ov "$DMG"

if [[ -n "$DEV_ID" ]]; then
  codesign --force --timestamp --sign "$DEV_ID" "$DMG"
  echo "==> Notarizing (profile: $NOTARY_PROFILE)"
  OUT=$(xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1) || true
  print -r -- "$OUT"
  if ! print -r -- "$OUT" | grep -q 'status: Accepted'; then
    ID=$(print -r -- "$OUT" | sed -n 's/^ *id: //p' | head -1)
    echo "Notarization failed. Details: xcrun notarytool log ${ID:-<submission-id>} --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  fi
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi

echo "==> $DMG ($(du -h "$DMG" | cut -f1 | tr -d ' '))"
