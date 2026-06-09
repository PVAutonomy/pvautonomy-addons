#!/usr/bin/env bash
# Verify pvautonomy_installer/run.sh reads channel / force_reinstall from
# /data/options.json (via jq, NOT bashio) and passes the correct
# PVA_MANIFEST_URL / PVA_FORCE to the installer. Uses a stub installer
# (PVA_INSTALLER) that just echoes the exported env — no network, no Supervisor.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
RUN="$HERE/../pvautonomy_installer/run.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/stub.sh" <<'STUB'
#!/usr/bin/env bash
echo "MANIFEST=$PVA_MANIFEST_URL"
echo "CONFIG=$PVA_CONFIG_DIR"
echo "FORCE=$PVA_FORCE"
STUB
chmod +x "$WORK/stub.sh"

PASS=0
FAIL=0
want() { # want <desc> <regex> <text>
  if printf '%s\n' "$3" | grep -qE "$2"; then
    echo "  PASS: $1"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $1"
    echo "    output: $3"
    FAIL=$((FAIL + 1))
  fi
}

run_case() { # run_case <options-json-or-empty> ; empty => no options file
  if [ -n "$1" ]; then
    printf '%s' "$1" > "$WORK/options.json"
    OPT="$WORK/options.json"
  else
    OPT="$WORK/does-not-exist.json"
    rm -f "$OPT"
  fi
  PVA_OPTIONS_FILE="$OPT" PVA_INSTALLER="$WORK/stub.sh" PVA_CONFIG_DIR=/tmp/pva-x \
    bash "$RUN" 2>&1
}

echo "== beta + force_reinstall=true =="
out="$(run_case '{"channel":"beta","force_reinstall":true}')"
want "logs channel=beta"            'channel=beta'            "$out"
want "logs force_reinstall=1"       'force_reinstall=1'       "$out"
want "manifest -> beta.json"        'MANIFEST=.*/beta\.json$' "$out"
want "installer FORCE=1"            'FORCE=1$'                "$out"

echo "== stable + force_reinstall=false =="
out="$(run_case '{"channel":"stable","force_reinstall":false}')"
want "manifest -> stable.json"      'MANIFEST=.*/stable\.json$' "$out"
want "installer FORCE=0"            'FORCE=0$'                  "$out"

echo "== unknown channel -> stable fallback =="
out="$(run_case '{"channel":"weird"}')"
want "warns + falls back to stable" 'MANIFEST=.*/stable\.json$' "$out"

echo "== missing options file -> defaults (stable / 0) =="
out="$(run_case '')"
want "no file -> stable.json"       'MANIFEST=.*/stable\.json$' "$out"
want "no file -> FORCE=0"           'FORCE=0$'                  "$out"

echo "============================================================"
echo "  RESULT: $PASS passed, $FAIL failed"
echo "============================================================"
[ "$FAIL" -eq 0 ]
