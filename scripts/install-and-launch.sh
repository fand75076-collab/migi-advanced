#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
"$SCRIPT_DIR/install-app.sh" "$@"

if ! command -v cua-driver >/dev/null 2>&1; then
  echo "Installed. Launch Migi Advanced from ~/Applications." >&2
  exit 0
fi

cua-driver launch_app \
  '{"bundle_id":"local.fdk.migi-advanced"}'
