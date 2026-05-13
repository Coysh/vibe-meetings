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
CHANGELOG="CHANGELOG.md"

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
TODAY=$(date +%Y-%m-%d)
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

# ── Update CHANGELOG ────────────────────────────────────
echo "==> Updating CHANGELOG.md..."
if [ -f "$CHANGELOG" ]; then
    # Extract the [Unreleased] section content.
    UNRELEASED_CONTENT=$(awk '/^## \[Unreleased\]/{found=1; next} /^## \[/{found=0} found{print}' "$CHANGELOG")

    if [ -n "$UNRELEASED_CONTENT" ]; then
        # Create the new version header and prepend it.
        # Replace [Unreleased] content with empty, insert new version section.
        TEMP=$(mktemp)
        awk -v version="$VERSION" -v date="$TODAY" '
        /^## \[Unreleased\]/ {
            print $0
            print ""
            # Skip old unreleased content
            while ((getline line) > 0) {
                if (line ~ /^## \[/) {
                    # Insert the new version section before this line
                    print "## [" version "] - " date
                    for (i in unreleased) print unreleased[i]
                    print ""
                    print line
                    break
                }
                unreleased[++count] = line
            }
            next
        }
        { print }
        ' "$CHANGELOG" > "$TEMP"
        mv "$TEMP" "$CHANGELOG"

        # Update the compare links at the bottom.
        # Add new version link and update [Unreleased] compare base.
        sed -i '' "s|\[Unreleased\]: .*|[Unreleased]: https://github.com/$REPO/compare/$TAG...HEAD|" "$CHANGELOG"
        # Insert the new version compare link if not already present.
        if ! grep -q "\[$VERSION\]:" "$CHANGELOG"; then
            # Find the previous version tag from the changelog.
            PREV_TAG=$(grep -o '^\[[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\]' "$CHANGELOG" | head -2 | tail -1 | tr -d '[]')
            if [ -n "$PREV_TAG" ]; then
                sed -i '' "/^\[Unreleased\]:/a\\
[$VERSION]: https://github.com/$REPO/compare/v$PREV_TAG...$TAG" "$CHANGELOG"
            fi
        fi
        echo "    Moved [Unreleased] items to [$VERSION] - $TODAY"
    else
        echo "    No [Unreleased] content found — skipping CHANGELOG update."
    fi
else
    echo "    CHANGELOG.md not found — skipping."
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

# ── Re-sign embedded frameworks ─────────────────────────
# Sparkle.framework ships with its own Team ID. Since we sign ad-hoc,
# macOS will refuse to load a framework whose Team ID differs from the
# host app. Re-sign the framework (and then the whole app) with the
# same ad-hoc identity so the Team IDs match.
echo "==> Re-signing embedded frameworks..."
if [ -d "$BUILD_DIR/$APP_NAME/Contents/Frameworks/Sparkle.framework/Versions/B" ]; then
    # Sign nested bundles inside-out, then the versioned framework bundle
    # (using Versions/B avoids "ambiguous bundle format" errors).
    for nested in "$BUILD_DIR/$APP_NAME/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app" \
                   "$BUILD_DIR/$APP_NAME/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/"*.xpc \
                   "$BUILD_DIR/$APP_NAME/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"; do
        [ -e "$nested" ] && /usr/bin/codesign --force --sign "-" "$nested"
    done
    /usr/bin/codesign --force --sign "-" \
        "$BUILD_DIR/$APP_NAME/Contents/Frameworks/Sparkle.framework/Versions/B"
fi
/usr/bin/codesign --force --sign "-" "$BUILD_DIR/$APP_NAME"

cd "$BUILD_DIR"
zip -r -q VibeMeetings.zip "$APP_NAME"
cd ..

ZIP_SIZE=$(du -h "$BUILD_DIR/VibeMeetings.zip" | cut -f1)
echo "==> Created $BUILD_DIR/VibeMeetings.zip ($ZIP_SIZE)"

# ── Sparkle: sign the update and regenerate appcast ──────
SPARKLE_BIN="$HOME/Library/Developer/Xcode/DerivedData/Sparkle-*/SourcePackages/artifacts/sparkle/Sparkle.framework/../bin"
SPARKLE_SIGN=$(ls $SPARKLE_BIN/sign_update 2>/dev/null | head -1 || true)
SPARKLE_APPCAST=$(ls $SPARKLE_BIN/generate_appcast 2>/dev/null | head -1 || true)

# Also check Homebrew location and /usr/local
if [ -z "$SPARKLE_SIGN" ]; then
    SPARKLE_SIGN=$(which sign_update 2>/dev/null || true)
fi
if [ -z "$SPARKLE_APPCAST" ]; then
    SPARKLE_APPCAST=$(which generate_appcast 2>/dev/null || true)
fi

SIGNATURE=""
if [ -n "$SPARKLE_SIGN" ] && [ -x "$SPARKLE_SIGN" ]; then
    echo "==> Signing update with Sparkle..."
    SIGNATURE=$("$SPARKLE_SIGN" "$BUILD_DIR/VibeMeetings.zip" 2>/dev/null || true)
    if [ -n "$SIGNATURE" ]; then
        # sign_update outputs: sparkle:edSignature="..." length="..."
        ED_SIGNATURE=$(echo "$SIGNATURE" | grep -o 'sparkle:edSignature="[^"]*"' | sed 's/sparkle:edSignature="//;s/"//')
        echo "    Sparkle signature generated."
    else
        echo "    WARNING: sign_update failed. Run 'generate_keys' first to create a Sparkle EdDSA key pair."
    fi
else
    echo "    Sparkle sign_update not found — skipping signing."
    echo "    To enable: install Sparkle tools or run from DerivedData after building."
fi

# ── Generate appcast.xml with GitHub Release download URL ─
echo "==> Generating appcast.xml..."
ZIP_BYTES=$(stat -f%z "$BUILD_DIR/VibeMeetings.zip")
BUILD_NUMBER=$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" VibeMeetings/Info.plist)
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$TAG/VibeMeetings.zip"
PUB_DATE=$(date -R)

# Build the new <item> entry
NEW_ITEM="        <item>
            <title>$VERSION</title>
            <pubDate>$PUB_DATE</pubDate>
            <sparkle:version>$BUILD_NUMBER</sparkle:version>
            <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
            <enclosure url=\"$DOWNLOAD_URL\" length=\"$ZIP_BYTES\" type=\"application/octet-stream\""

if [ -n "$ED_SIGNATURE" ]; then
    NEW_ITEM="$NEW_ITEM sparkle:edSignature=\"$ED_SIGNATURE\""
fi
NEW_ITEM="$NEW_ITEM/>
        </item>"

# If appcast.xml exists, insert new item at the top of the channel (after the language tag)
if [ -f appcast.xml ]; then
    # Remove any existing entry for this version, then insert the new one
    TEMP_APPCAST=$(mktemp)
    awk -v new_item="$NEW_ITEM" -v version="$VERSION" '
    BEGIN { inserted=0; skip=0 }
    # Skip existing entries for this same version
    /<item>/ {
        # Read ahead to check if this item matches our version
        line = $0
        if (getline nextline > 0) {
            if (nextline ~ "<title>" version "</title>") {
                skip = 1
                next
            } else {
                # Not our version — print both lines
                if (!inserted && line ~ /<item>/) {
                    # Insert before the first <item>
                    print new_item
                    inserted = 1
                }
                print line
                print nextline
                next
            }
        }
    }
    skip && /<\/item>/ { skip=0; next }
    skip { next }
    # Insert before the first <item> if we havent yet
    !inserted && /<item>/ {
        print new_item
        inserted = 1
    }
    { print }
    ' appcast.xml > "$TEMP_APPCAST"
    mv "$TEMP_APPCAST" appcast.xml
else
    # Create a fresh appcast.xml
    cat > appcast.xml <<APPCAST_EOF
<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0">
    <channel>
        <title>VibeMeetings Updates</title>
        <language>en</language>
$NEW_ITEM
    </channel>
</rss>
APPCAST_EOF
fi
echo "    appcast.xml updated with download URL: $DOWNLOAD_URL"

# ── Extract release notes from CHANGELOG ─────────────────
RELEASE_NOTES=""
if [ -f "$CHANGELOG" ]; then
    RELEASE_NOTES=$(awk -v version="$VERSION" '
    $0 ~ "^## \\[" version "\\]" { found=1; next }
    /^## \[/ { if (found) exit }
    found { print }
    ' "$CHANGELOG" | sed '/^$/d')
fi

if [ -z "$RELEASE_NOTES" ]; then
    RELEASE_NOTES="- Update from previous release"
fi

# ── Commit version bump + changelog ──────────────────────
echo "==> Committing version bump..."
git add VibeMeetings/Info.plist
[ -f "$CHANGELOG" ] && git add "$CHANGELOG"
[ -f appcast.xml ] && git add appcast.xml
git commit -m "Release $VERSION" --allow-empty 2>/dev/null || true

# ── Tag and push ─────────────────────────────────────────
echo "==> Tagging $TAG and pushing..."
git tag -f "$TAG"
git push origin HEAD --quiet
git push origin HEAD:main --quiet
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
$RELEASE_NOTES

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
