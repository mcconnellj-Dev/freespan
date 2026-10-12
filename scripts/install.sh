#!/bin/zsh
# Builds Freespan (Release) and installs it to /Applications, replacing any older copy.
# The old copy goes to the Trash, not deleted. Quits a running Freespan first.
set -euo pipefail
cd "${0:A:h}/.."
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/Freespan-release"   # outside ~/Desktop: Desktop xattrs break codesign
xcodegen generate -q
xcodebuild -project Freespan.xcodeproj -scheme Freespan -configuration Release \
  -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DERIVED" build -quiet
APP="$DERIVED/Build/Products/Release/Freespan.app"
codesign --verify --deep --strict "$APP"
osascript -e 'if application "Freespan" is running then tell application "Freespan" to quit' >/dev/null 2>&1 || true
sleep 1
if [[ -d /Applications/Freespan.app ]]; then
  osascript -e 'tell application "Finder" to delete POSIX file "/Applications/Freespan.app"' >/dev/null
fi
ditto "$APP" /Applications/Freespan.app
echo "Installed /Applications/Freespan.app ($(defaults read /Applications/Freespan.app/Contents/Info.plist CFBundleShortVersionString))"
