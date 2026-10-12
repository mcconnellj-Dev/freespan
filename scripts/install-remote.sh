#!/bin/zsh
# Copies the installed /Applications/Freespan.app to another Mac over SSH, replacing its copy.
# Usage: ./scripts/install-remote.sh <ssh-host>     (run ./scripts/install.sh first)
# The remote Mac's old copy goes to its Trash, not deleted.
set -euo pipefail
HOST="${1:?usage: $0 <ssh-host>}"
ZIP="$(mktemp -d)/Freespan.zip"
ditto -c -k --keepParent /Applications/Freespan.app "$ZIP"
scp -q "$ZIP" "$HOST:/tmp/Freespan.zip"
# No Finder or AppleScript over SSH (they need a permission click on the remote Mac's screen). The old copy is
# moved into the Trash folder; a running Freespan keeps working and picks up the new version when reopened.
ssh "$HOST" '
  set -e
  if [ -d /Applications/Freespan.app ]; then
    mv /Applications/Freespan.app ~/.Trash/Freespan-$(date +%Y%m%d-%H%M%S).app
  fi
  ditto -x -k /tmp/Freespan.zip /Applications/ && rm /tmp/Freespan.zip
  codesign --verify --deep --strict /Applications/Freespan.app
  echo "Installed Freespan on $(hostname -s) (reopen it if it was running)"
'
