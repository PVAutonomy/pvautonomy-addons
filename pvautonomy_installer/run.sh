#!/usr/bin/env bash
# PVAutonomy Installer / Updater — add-on entrypoint.
#
# Thin wrapper: reads add-on options via bashio (when present), resolves the
# channel manifest URL, and delegates to installer.sh. All real work lives in
# installer.sh so it can be proven locally without the Supervisor.

set -euo pipefail

CHANNEL="stable"
FORCE="0"

if command -v bashio >/dev/null 2>&1; then
  CHANNEL="$(bashio::config 'channel')"
  if bashio::config.true 'force_reinstall'; then
    FORCE="1"
  fi
fi

BASE_URL="https://raw.githubusercontent.com/PVAutonomy/pvautonomy-addons/main/integration"

export PVA_MANIFEST_URL="${PVA_MANIFEST_URL:-$BASE_URL/${CHANNEL}.json}"
export PVA_CONFIG_DIR="${PVA_CONFIG_DIR:-/config}"
export PVA_FORCE="$FORCE"

HERE="$(cd "$(dirname "$0")" && pwd)"
exec bash "$HERE/installer.sh"
