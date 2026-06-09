#!/usr/bin/env bash
# PVAutonomy Installer / Updater — add-on entrypoint.
#
# Reads the add-on options directly from /data/options.json (written by the
# Supervisor) using jq, then delegates to installer.sh.
#
# It deliberately does NOT call bashio shell functions (e.g. bashio::config):
# those are only defined after `source /usr/lib/bashio/bashio`. The /usr/bin/
# bashio *binary* exists, so a `command -v bashio` guard passes, but calling
# bashio::config unsourced fails with
#   /run.sh: line NN: bashio::config: command not found
# and the add-on never starts. Reading the options JSON has no such runtime
# dependency on a sourced function.
set -euo pipefail

# Keep in sync with config.yaml `version:`. This is the installer add-on
# version shown in the log; the PVAutonomy Ops integration version it installs
# is defined by the selected channel manifest.
ADDON_VERSION="0.1.2"

# Supervisor writes the resolved add-on options here. Overridable for tests.
OPTIONS_FILE="${PVA_OPTIONS_FILE:-/data/options.json}"

CHANNEL="stable"
FORCE="0"
if [ -f "$OPTIONS_FILE" ] && command -v jq >/dev/null 2>&1; then
  CHANNEL="$(jq -r '.channel // "stable"' "$OPTIONS_FILE" 2>/dev/null || echo stable)"
  case "$(jq -r '.force_reinstall // false' "$OPTIONS_FILE" 2>/dev/null)" in
    true | 1 | yes) FORCE="1" ;;
    *) FORCE="0" ;;
  esac
fi

# Guard the channel against the known set; fall back to stable on anything else.
case "$CHANNEL" in
  stable | beta) ;;
  *)
    echo "[pva-installer] WARN: unknown channel '${CHANNEL}', falling back to 'stable'"
    CHANNEL="stable"
    ;;
esac

BASE_URL="https://raw.githubusercontent.com/PVAutonomy/pvautonomy-addons/main/integration"

echo "[pva-installer] PVAutonomy Installer / Updater v${ADDON_VERSION}"
echo "[pva-installer] channel=${CHANNEL}  force_reinstall=${FORCE}"
echo "[pva-installer] starting installer.sh"

export PVA_MANIFEST_URL="${PVA_MANIFEST_URL:-${BASE_URL}/${CHANNEL}.json}"
export PVA_CONFIG_DIR="${PVA_CONFIG_DIR:-/config}"
export PVA_FORCE="$FORCE"

HERE="$(cd "$(dirname "$0")" && pwd)"
exec bash "${PVA_INSTALLER:-$HERE/installer.sh}"
