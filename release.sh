#!/bin/bash
set -euo pipefail

# ──────────────────────────────────────────────────────────
# VibeMeetings — Build & Release Script
# Usage:  ./release.sh [version]
# Example: ./release.sh 1.1.0
# ──────────────────────────────────────────────────────────

REPO="Coysh/vibe-meetings"
SCHEME="VibeMeetings"
PROJECT="VibeMeetings.xcodeproj"
BUILD_DIR="build"
ARCHIVE_PATH="$BUILD_DIR/VibeMeetings.xcarchive"

# ── Version ──────────────────────────────────────────────
if [ -z "${1:-}" ]; then
    # Auto-increment: read current version from Info.plist, bump patch
    CURRENT=$(defaults read "$(pwd)/VibeMeetings/Info.plist" CFBundleShortVersionString 2>/dev/null || echo "1.0.0")
    IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT"
    PATCH=$((PATCH + 1))
    VERSION="$MAJOR.$MINOR.$PATCH"
    echo "No version specified. Auto-incrementing: $CURRENT -> $VERSION"
else
    VERSION="$1"
fi

TAG="v$VERSION"
echo ""
echo "==> Building VibeMeetings $TAG"
echo ""

# ── Check prerequisites ─────────────────────────────────
if ! command -v gh &>/dev/null; then
    echo "ERROR: GitHub CLI (gh) is required. Install with: brew install gh"
    exit 1
fi

if ! gh auth status &>/dev/null; then
    echo "ERROR: Not authenticated with GitHub CLI. Run: gh auth login"
    exit 1
fi

# ── Update version in Info.plist ─────────────────────────
echo "==> Setting version to $VERSION in Info.plist..."
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" VibeMeetings/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" VibeMeetings/Info.plist

# ── Clean build folder ───────────────────────────────────
echo "==> Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# ── Archive ──────────────────────────────────────────────
echo "==> Archiving (Release configuration)..."
xcodebuild archive \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -quiet

echo "==> Archive succeeded."

# ── Extract .app and create zip ──────────────────────────
APP_NAME=$(ls "$ARCHIVE_PATH/Products/Applications/" | head -1)
APP_PATH="$ARCHIVE_PATH/Products/Applications/$APP_NAME"

echo "==> Packaging $APP_NAME..."
cp -R "$APP_PATH" "$BUILD_DIR/"
cd "$BUILD_DIR"
zip -r -q VibeMeetings.zip "$APP_NAME"
cd ..

ZIP_SIZE=$(du -h "$BUILD_DIR/VibeMeetings.zip" | cut -f1)
echo "==> Created $BUILD_DIR/VibeMeetings.zip ($ZIP_SIZE)"

# ── Commit version bump ─────────────────────────────────
echo "==> Committing version bump..."
git add VibeMeetings/Info.plist
git commit -m "Bump version to $VERSION" --allow-empty 2>/dev/null || true

# ── Tag and push ─────────────────────────────────────────
echo "==> Tagging $TAG and pushing..."
git tag -f "$TAG"
git push origin HEAD --quiet
git push origin "$TAG" --force --quiet

# ── Create GitHub release ────────────────────────────────
echo "==> Creating GitHub release..."
gh release create "$TAG" \
    "$BUILD_DIR/VibeMeetings.zip" \
    --repo "$REPO" \
    --title "VibeMeetings $TAG" \
    --notes "$(cat <<EOF
## VibeMeetings $TAG

### Changes
- Update from previous release

### Installation
1. Download **VibeMeetings.zip** below
2. Unzip and drag **$APP_NAME** to your Applications folder
3. Right-click > Open on first launch (macOS Gatekeeper)
EOF
)" \
    --latest

echo ""
echo "==> Done! Release published at:"
echo "    https://github.com/$REPO/releases/tag/$TAG"
echo ""
