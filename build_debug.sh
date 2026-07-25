#!/bin/bash

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT="$PROJECT_DIR/translate.xcodeproj"
SCHEME="translate"
PRODUCT_NAME="Translate"
BUILD_NUMBER="$(git -C "$PROJECT_DIR" rev-list --count HEAD)"
GIT_COMMIT_HASH="$(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
BUILD_TIMESTAMP="$(date '+%Y%m%d.%H%M%S')"
DEBUG_IDENTIFIER="Debug-$BUILD_NUMBER-$GIT_COMMIT_HASH-$BUILD_TIMESTAMP"
DEBUG_ROOT="$PROJECT_DIR/release/local-debug/$DEBUG_IDENTIFIER"
OUTPUT_DIR="$DEBUG_ROOT/output"
DERIVED_DATA="$DEBUG_ROOT/derived-data"
APP_PATH="$OUTPUT_DIR/$PRODUCT_NAME.app"

if [[ -z "${DEVELOPER_DIR:-}" ]]; then
    if [[ -d /Applications/Xcode.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    elif [[ -d /Applications/Xcode-beta.app/Contents/Developer ]]; then
        export DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer
    fi
fi

xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Debug \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DERIVED_DATA" \
    CONFIGURATION_BUILD_DIR="$OUTPUT_DIR" \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    GIT_COMMIT_HASH="$GIT_COMMIT_HASH" \
    BUILD_TIMESTAMP="$BUILD_TIMESTAMP" \
    DEBUG_BUILD_IDENTIFIER="$DEBUG_IDENTIFIER" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    build

codesign --force --deep --sign - "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"

echo "$APP_PATH"
