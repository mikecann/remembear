#!/usr/bin/env bash
# Quit and remove RememBear (its login item goes with the app). Recorded events and
# summaries in ~/Library/Application Support/RememBear are kept unless
# --delete-data is passed.
set -euo pipefail
APP="${REMEMBEAR_APP_PATH:-$HOME/Applications/RememBear.app}"
pkill -x remembear 2>/dev/null || true
rm -rf "$APP"
if [[ "${1:-}" == "--delete-data" ]]; then
  rm -rf "$HOME/Library/Application Support/RememBear"
  echo "Deleted recorded events and summaries."
fi
echo "Removed $APP"
