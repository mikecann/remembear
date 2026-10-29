#!/usr/bin/env bash
# Quit and remove Recall It (its login item goes with the app). Recorded events and
# summaries in ~/Library/Application Support/Recall It are kept unless
# --delete-data is passed.
set -euo pipefail
APP="${RECALL_IT_APP_PATH:-$HOME/Applications/Recall It.app}"
pkill -x RecallIt 2>/dev/null || true
rm -rf "$APP"
if [[ "${1:-}" == "--delete-data" ]]; then
  rm -rf "$HOME/Library/Application Support/Recall It"
  echo "Deleted recorded events and summaries."
fi
echo "Removed $APP"
