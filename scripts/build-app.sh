#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
APP_NAME="Migi Advanced.app"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/$APP_NAME"
BACKUP_DIR="$PROJECT_DIR/backups/dist"

swift build --package-path "$PROJECT_DIR" -c release

BUILD_DIR=$(swift build --package-path "$PROJECT_DIR" -c release --show-bin-path)
RESOURCE_BUNDLE="$BUILD_DIR/MigiAdvanced_MigiAdvanced.bundle"
FULL_SPRITE_IMAGE="$RESOURCE_BUNDLE/migi-full-spritesheet.png"
V4_ATLAS_IMAGE="$RESOURCE_BUNDLE/migi-v4-atlas.png"
V4_ATLAS_MANIFEST="$RESOURCE_BUNDLE/migi-v4-atlas.json"

if [[ ! -d "$RESOURCE_BUNDLE" || ! -r "$FULL_SPRITE_IMAGE" \
    || ! -r "$V4_ATLAS_IMAGE" || ! -r "$V4_ATLAS_MANIFEST" ]]; then
  echo "Required Migi resource bundle is incomplete: $RESOURCE_BUNDLE" >&2
  exit 1
fi
cmp "$PROJECT_DIR/Sources/MigiAdvanced/Resources/migi-v4-atlas.png" "$V4_ATLAS_IMAGE"
cmp "$PROJECT_DIR/Sources/MigiAdvanced/Resources/migi-v4-atlas.json" "$V4_ATLAS_MANIFEST"

STAGE_DIR=$(mktemp -d)
trap 'rm -rf "$STAGE_DIR"' EXIT

mkdir -p "$STAGE_DIR/$APP_NAME/Contents/MacOS"
mkdir -p "$STAGE_DIR/$APP_NAME/Contents/Resources"
cp "$BUILD_DIR/MigiAdvanced" "$STAGE_DIR/$APP_NAME/Contents/MacOS/MigiAdvanced"
cp "$PROJECT_DIR/Resources/Info.plist" "$STAGE_DIR/$APP_NAME/Contents/Info.plist"
cp -R "$RESOURCE_BUNDLE" "$STAGE_DIR/$APP_NAME/Contents/Resources/"

mkdir -p "$DIST_DIR"
if [[ -d "$APP_DIR" ]]; then
  BACKUP_STAMP=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_DIR"
  mv "$APP_DIR" "$BACKUP_DIR/Migi Advanced-$BACKUP_STAMP.app.backup"
fi
mv "$STAGE_DIR/$APP_NAME" "$APP_DIR"

# Keep only the most recent dist backups; every build otherwise leaves one behind.
if [[ -d "$BACKUP_DIR" ]]; then
  ls -1dt "$BACKUP_DIR"/*.app.backup 2>/dev/null | tail -n +4 | xargs -I{} rm -rf {} 2>/dev/null || true
fi
codesign --force --deep --sign - "$APP_DIR"

plutil -lint "$APP_DIR/Contents/Info.plist" >/dev/null
test -r "$APP_DIR/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-full-spritesheet.png"
test -r "$APP_DIR/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-v4-atlas.png"
test -r "$APP_DIR/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-v4-atlas.json"
cmp "$V4_ATLAS_IMAGE" "$APP_DIR/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-v4-atlas.png"
cmp "$V4_ATLAS_MANIFEST" "$APP_DIR/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-v4-atlas.json"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "$APP_DIR"
