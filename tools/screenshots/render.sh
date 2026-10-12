#!/bin/zsh
# Renders the marketing screenshots offscreen into docs/screenshots. Never launches Freespan or scans anything.
# Usage: tools/screenshots/render.sh [name ...]   (names: clean overview overview-dark cleanup-sheet apps uninstall-sheet explore)
set -euo pipefail
HERE=${0:A:h}
REPO=${HERE:h:h}
DERIVED=~/Library/Developer/Xcode/DerivedData/Freespan-shots
OUT=$REPO/docs/screenshots
xcodegen generate --spec "$HERE/project.yml" --quiet
xcodebuild -project "$HERE/FreespanShots.xcodeproj" -scheme FreespanShots -configuration Debug \
  -derivedDataPath "$DERIVED" -quiet build
"$DERIVED/Build/Products/Debug/FreespanShots.app/Contents/MacOS/FreespanShots" "$OUT" "$@"
if [[ $# -eq 0 ]]; then
  cp "$REPO/App/Resources/Assets.xcassets/AppIcon.appiconset/icon_256@2x.png" "$OUT/icon.png"
  echo "wrote $OUT/icon.png"
fi
