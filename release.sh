#!/bin/bash
# Cut a release: bump the committed version, commit, tag, and push.
#
#   ./release.sh 1.2.0
#
# This is the ONLY thing a maintainer runs to ship. Pushing the tag triggers
# .github/workflows/release.yml, which builds the app (stamped from the tag),
# publishes a fresh-install DMG plus the updater ZIP. Installed apps pick it up
# on their next update check.
#
# We bump the committed Info.plist *and* tag the same commit, so the two
# sources build.sh reads from (git describe + Info.plist) always agree — a
# clone, a ZIP download, or a worktree all report the right version.
set -eo pipefail

VERSION="$1"
if [ -z "$VERSION" ]; then
    echo "Usage: ./release.sh <version>   e.g. ./release.sh 1.2.0"
    exit 1
fi

# Normalise: accept "v1.2.0" or "1.2.0", store the bare number.
VERSION="${VERSION#v}"
if ! echo "$VERSION" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "✗ Version must look like 1.2.0 (got: $VERSION)"
    exit 1
fi
TAG="v$VERSION"

# Refuse to release from a dirty tree or a non-main branch — avoids tagging
# half-committed work.
BRANCH=$(git rev-parse --abbrev-ref HEAD)
if [ "$BRANCH" != "main" ]; then
    echo "✗ Releases are cut from main (you're on '$BRANCH')."
    exit 1
fi
if [ -n "$(git status --porcelain)" ]; then
    echo "✗ Working tree is dirty — commit or stash first."
    git status --short
    exit 1
fi
if git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "✗ Tag $TAG already exists."
    exit 1
fi

echo "==> Releasing $TAG"

# Bump the committed version (source of truth for non-tagged builds).
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString $VERSION" \
    -c "Set :CFBundleVersion $VERSION" \
    Info.plist

git add Info.plist
git commit -m "Release $TAG"
git tag "$TAG"

echo "==> Pushing main + $TAG"
git push origin main
git push origin "$TAG"

echo ""
echo "  ✓ $TAG pushed. GitHub Actions is building the release now:"
echo "    https://github.com/JanPlr/whisperino/actions"
echo ""
