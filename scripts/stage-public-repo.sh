#!/bin/zsh
# Stages the public GitHub repo as a fresh, single-commit history built from HEAD.
# Private history (old author email, internal notes) never leaves this machine; tasks/ is
# excluded via .gitattributes export-ignore.
#
# Usage: ./scripts/stage-public-repo.sh           stage into $OUT and run the leak check
#        ./scripts/stage-public-repo.sh --push    also create github.com/$REPO (public) and push
set -euo pipefail
cd "${0:A:h}/.."

REPO="${REPO:-mcconnellj-Dev/freespan}"
OUT="${OUT:-$HOME/Library/Developer/Freespan-public}"
AUTHOR_NAME="${AUTHOR_NAME:-McConnell Digital}"
AUTHOR_EMAIL="${AUTHOR_EMAIL:-263051840+mcconnellj-Dev@users.noreply.github.com}"
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' project.yml)

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Working tree has uncommitted changes. Commit or stash them first." >&2
  exit 1
fi

echo "==> Exporting HEAD ($(git rev-parse --short HEAD)) to $OUT"
rm -rf "$OUT"
mkdir -p "$OUT"
git archive HEAD | tar -x -C "$OUT"

echo "==> Checking for personal info"
# Fake test keys look like sk-ant-test...; anything else that looks like a key fails the check.
LEAKS=$(grep -rIn -i -E --exclude=stage-public-repo.sh 'jesse|gmail\.com|quarry|ssh mini|sk-ant-(api|admin)[0-9]{2}-' "$OUT" || true)
if [[ -n "$LEAKS" ]]; then
  echo "$LEAKS" >&2
  echo "Leak check failed. Fix the files above, commit, and run again." >&2
  exit 1
fi
[[ -d "$OUT/tasks" ]] && { echo "tasks/ was exported; check .gitattributes" >&2; exit 1; }

echo "==> Creating the single commit"
cd "$OUT"
git init -q -b main
git add -A
GIT_AUTHOR_NAME="$AUTHOR_NAME" GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
GIT_COMMITTER_NAME="$AUTHOR_NAME" GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
  git commit -q -m "Freespan $VERSION"
echo "Staged $(git ls-files | wc -l | tr -d ' ') files in $OUT"

if [[ "${1:-}" == "--push" ]]; then
  echo "==> Creating github.com/$REPO and pushing"
  gh repo create "$REPO" --public --source . --push \
    --description "Free, private disk-space cleanup for Mac. See where your space went; clean only what's safe." \
    --homepage "https://mcconnelldigital.com/freespan/"
else
  echo "Review it, then publish with: ./scripts/stage-public-repo.sh --push"
fi
