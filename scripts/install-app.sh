#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
PROJECT_DIR=${SCRIPT_DIR:h}
BUILT_APP="$PROJECT_DIR/dist/Migi Advanced.app"
INSTALL_ROOT="$HOME/Applications"
INSTALLED_APP="$INSTALL_ROOT/Migi Advanced.app"
BACKUP_ROOT="$HOME/Library/Application Support/Migi Advanced/Backups"
SHOULD_BUILD=1

if [[ ${1:-} == "--no-build" ]]; then
  SHOULD_BUILD=0
  shift
fi

if (( $# > 0 )); then
  echo "Unknown argument: $1" >&2
  exit 2
fi

if (( SHOULD_BUILD )); then
  "$SCRIPT_DIR/build-app.sh"
elif [[ ! -d "$BUILT_APP" ]]; then
  echo "Built app not found: $BUILT_APP" >&2
  exit 1
fi

# Ask every old installed or development copy to terminate before replacing
# the canonical bundle. This avoids leaving a process alive from a bundle that
# has just been moved into Backups, and releases the cross-path instance lock.
/usr/bin/swift -e '
import AppKit
import Foundation

let bundleID = "local.fdk.migi-advanced"
let applications = NSRunningApplication.runningApplications(
    withBundleIdentifier: bundleID
)
for application in applications {
    _ = application.terminate()
}
let deadline = Date().addingTimeInterval(5)
while Date() < deadline {
    if NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleID
    ).isEmpty {
        exit(EXIT_SUCCESS)
    }
    RunLoop.current.run(until: Date().addingTimeInterval(0.1))
}
fputs("Migi Advanced did not terminate within 5 seconds.\n", stderr)
exit(EXIT_FAILURE)
'

mkdir -p "$INSTALL_ROOT"
if [[ -d "$INSTALLED_APP" ]]; then
  BACKUP_STAMP=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_ROOT"
  mv "$INSTALLED_APP" "$BACKUP_ROOT/Migi Advanced-$BACKUP_STAMP.app.backup"
fi
ditto "$BUILT_APP" "$INSTALLED_APP"

test -r "$INSTALLED_APP/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-parts.png"
test -r "$INSTALLED_APP/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-full-spritesheet.png"
test -r "$INSTALLED_APP/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-v4-atlas.png"
test -r "$INSTALLED_APP/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-v4-atlas.json"
codesign --verify --deep --strict --verbose=2 "$INSTALLED_APP"
cmp "$BUILT_APP/Contents/MacOS/MigiAdvanced" "$INSTALLED_APP/Contents/MacOS/MigiAdvanced"
cmp "$BUILT_APP/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-v4-atlas.png" \
    "$INSTALLED_APP/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-v4-atlas.png"
cmp "$BUILT_APP/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-v4-atlas.json" \
    "$INSTALLED_APP/Contents/Resources/MigiAdvanced_MigiAdvanced.bundle/migi-v4-atlas.json"

LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
  "$LSREGISTER" -u "$BUILT_APP" >/dev/null 2>&1 || true
  "$LSREGISTER" -f "$INSTALLED_APP" >/dev/null
fi

echo "$INSTALLED_APP"
