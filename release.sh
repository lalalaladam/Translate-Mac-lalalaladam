#!/bin/bash

# Build and package a macOS Release from an Xcode archive.
#
# This project currently has no Apple Developer account. The workflow
# therefore does not perform Developer ID signing, notarization, or stapling.
# It applies an ad hoc signature only so codesign can verify the exported app's
# internal integrity; this is not an Apple-trusted distribution signature.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$PROJECT_DIR/translate.xcodeproj"
SCHEME="translate"
PRODUCT_NAME="Translate"
VERSION="${1:-}"

# Prefer the full Xcode installation over CommandLineTools when available.
if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
    fi
fi

if [[ -z "$VERSION" ]]; then
    VERSION="$(xcodebuild \
        -project "$PROJECT" \
        -scheme "$SCHEME" \
        -configuration Release \
        -showBuildSettings 2>/dev/null \
        | awk -F ' = ' '/^[[:space:]]*MARKETING_VERSION = / { print $2; exit }')"
fi

if [[ -z "$VERSION" ]]; then
    echo "Unable to determine MARKETING_VERSION. Usage: ./release.sh 1.0.1" >&2
    exit 1
fi

if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Version must use semantic versioning, for example 1.0.1: $VERSION" >&2
    exit 1
fi

XCODEBUILD=(xcodebuild -project "$PROJECT" -scheme "$SCHEME")
RELEASE_ROOT="$PROJECT_DIR/release/$VERSION"
ARCHIVE_PATH="$RELEASE_ROOT/$PRODUCT_NAME.xcarchive"
EXPORT_DIR="$RELEASE_ROOT/exported"
OUTPUT_DIR="$RELEASE_ROOT/output"
EXPORT_OPTIONS="$RELEASE_ROOT/ExportOptions.plist"
ZIP_NAME="$PRODUCT_NAME-v$VERSION.zip"
SHA_NAME="$PRODUCT_NAME-v$VERSION.sha256"
ZIP_PATH="$OUTPUT_DIR/$ZIP_NAME"
SHA_PATH="$OUTPUT_DIR/$SHA_NAME"

mkdir -p "$RELEASE_ROOT" "$OUTPUT_DIR"
rm -rf "$ARCHIVE_PATH" "$EXPORT_DIR"
rm -f "$EXPORT_OPTIONS" "$ZIP_PATH" "$SHA_PATH"

echo "==> Clean Build Folder"
"${XCODEBUILD[@]}" \
    -configuration Release \
    -derivedDataPath "$RELEASE_ROOT/derived-data" \
    clean

echo "==> Archive Release $VERSION"
"${XCODEBUILD[@]}" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE_PATH" \
    -derivedDataPath "$RELEASE_ROOT/derived-data" \
    MARKETING_VERSION="$VERSION" \
    CURRENT_PROJECT_VERSION=1 \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    archive

if [[ ! -d "$ARCHIVE_PATH" ]]; then
    echo "Archive was not created: $ARCHIVE_PATH" >&2
    exit 1
fi

echo "==> Prepare export options"
plutil -create xml1 "$EXPORT_OPTIONS"
plutil -insert method -string mac-application "$EXPORT_OPTIONS"
plutil -insert signingStyle -string manual "$EXPORT_OPTIONS"

echo "==> Export app from archive"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    CODE_SIGNING_ALLOWED=NO

APP_PATH="$EXPORT_DIR/$PRODUCT_NAME.app"
if [[ ! -d "$APP_PATH" ]]; then
    echo "Exported app was not created: $APP_PATH" >&2
    exit 1
fi

VERSION_IN_APP="$(plutil -extract CFBundleShortVersionString raw \
    "$APP_PATH/Contents/Info.plist")"
if [[ "$VERSION_IN_APP" != "$VERSION" ]]; then
    echo "App version mismatch: expected $VERSION, got $VERSION_IN_APP" >&2
    exit 1
fi

echo "==> Apply non-Developer-ID integrity signature"
codesign --force --deep --sign - "$APP_PATH"

echo "==> Verify app integrity"
codesign --verify --deep --strict "$APP_PATH"

echo "==> Create ZIP"
ditto -c -k --keepParent "$APP_PATH" "$ZIP_PATH"

echo "==> Create SHA-256 checksum"
(cd "$OUTPUT_DIR" && shasum -a 256 "$ZIP_NAME" > "$SHA_NAME")

echo
echo "Release files:"
echo "  Archive: $ARCHIVE_PATH"
echo "  App:     $APP_PATH"
echo "  ZIP:     $ZIP_PATH"
echo "  SHA-256: $SHA_PATH"
