#!/bin/zsh
set -euo pipefail
snapshot_root="${0:A:h:h}"
exec zsh "$snapshot_root/backend/scripts/build-app.sh" "$snapshot_root/frontend"
