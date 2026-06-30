#!/bin/bash
# Ensure Prysm validator client is up (systemd conet-prysm-validator.service or legacy fallback).
# Used after listener deploy/restart and by optional systemd watchdog timer.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
"$SCRIPT_DIR/08_import_append_validator_keys.sh" --sync-import
exec "$SCRIPT_DIR/08_import_append_validator_keys.sh" --ensure-running "$@"
