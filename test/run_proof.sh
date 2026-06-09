#!/usr/bin/env bash
# Local proof harness for pvautonomy_installer/installer.sh.
#
# Builds fixture ZIPs from the real pvautonomy_ops component (in throwaway
# copies — the source repo is never modified), serves them via local manifests,
# and exercises: sha mismatch abort, fresh install, idempotency, update,
# update-abort-preserves, and post-install rollback.
#
# No network, no Supervisor, no device access. Usage:
#   PVA_SRC=/path/to/custom_components/pvautonomy_ops bash test/run_proof.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALLER="$HERE/../pvautonomy_installer/installer.sh"
# Point PVA_SRC at a local pvautonomy_ops component dir to build the fixtures.
SRC="${PVA_SRC:-}"
WORK="$HERE/.work"
BADSHA="0000000000000000000000000000000000000000000000000000000000000000"

[ -f "$INSTALLER" ] || { echo "installer not found: $INSTALLER" >&2; exit 1; }
if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
  echo "set PVA_SRC to a local custom_components/pvautonomy_ops dir, e.g.:" >&2
  echo "  PVA_SRC=/path/to/pvautonomy_ops bash test/run_proof.sh" >&2
  exit 2
fi

rm -rf "$WORK"; mkdir -p "$WORK"

PASS=0; FAIL=0
ok()  { echo "  PASS: $*"; PASS=$((PASS + 1)); }
bad() { echo "  FAIL: $*"; FAIL=$((FAIL + 1)); }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}';
  else shasum -a 256 "$1" | awk '{print $1}'; fi
}

# build_fixture <version> <abs-out-zip> -> prints sha256
build_fixture() {
  local ver="$1" out="$2" stage="$WORK/stage-$1"
  rm -rf "$stage"; mkdir -p "$stage/custom_components"
  cp -a "$SRC" "$stage/custom_components/pvautonomy_ops"
  local mf="$stage/custom_components/pvautonomy_ops/manifest.json"
  jq --arg v "$ver" '.version=$v' "$mf" > "$mf.tmp" && mv "$mf.tmp" "$mf"
  ( cd "$stage" && zip -r -q "$out" custom_components/pvautonomy_ops -x '*__pycache__*' )
  sha256_of "$out"
}

# write_manifest <out.json> <version> <abs-zip> <sha>
write_manifest() {
  jq -n --arg v "$2" --arg url "file://$3" --arg sha "$4" \
    '{schema:1, integration:"pvautonomy_ops", channel:"test", version:$v,
      min_homeassistant:"2024.1.0",
      artifact:{url:$url, sha256:$sha, root_path:"custom_components/pvautonomy_ops"}}' > "$1"
}

iv() { # installed version in a config dir
  jq -er '.version' "$1/custom_components/pvautonomy_ops/manifest.json" 2>/dev/null || echo "none"
}

OUT=""; RC=0
run_installer() { # run_installer <manifest> <config-dir> [extra env=...]
  local murl="$1" cfg="$2"; shift 2
  set +e
  OUT="$(env "$@" PVA_MANIFEST_URL="$murl" PVA_CONFIG_DIR="$cfg" bash "$INSTALLER" 2>&1)"
  RC=$?
  set -e
}

echo "== Building fixtures from: $SRC"
ZIP_040="$WORK/pvautonomy_ops-0.4.0.zip"; SHA_040="$(build_fixture 0.4.0 "$ZIP_040")"
ZIP_041="$WORK/pvautonomy_ops-0.4.1.zip"; SHA_041="$(build_fixture 0.4.1 "$ZIP_041")"
ZIP_042="$WORK/pvautonomy_ops-0.4.2.zip"; SHA_042="$(build_fixture 0.4.2 "$ZIP_042")"
echo "   0.4.0 sha=$SHA_040"
echo "   0.4.1 sha=$SHA_041"
echo "   0.4.2 sha=$SHA_042"

# Manifests
M_040_GOOD="$WORK/m040_good.json"; write_manifest "$M_040_GOOD" 0.4.0 "$ZIP_040" "$SHA_040"
M_040_BAD="$WORK/m040_bad.json";   write_manifest "$M_040_BAD"  0.4.0 "$ZIP_040" "$BADSHA"
M_041_GOOD="$WORK/m041_good.json"; write_manifest "$M_041_GOOD" 0.4.1 "$ZIP_041" "$SHA_041"
M_041_BAD="$WORK/m041_bad.json";   write_manifest "$M_041_BAD"  0.4.1 "$ZIP_041" "$BADSHA"
M_042_GOOD="$WORK/m042_good.json"; write_manifest "$M_042_GOOD" 0.4.2 "$ZIP_042" "$SHA_042"

CFG="$WORK/config"; rm -rf "$CFG"; mkdir -p "$CFG"
CC="$CFG/custom_components"

echo
echo "== T1: fresh install, WRONG sha -> abort, nothing written"
run_installer "$M_040_BAD" "$CFG"
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "sha256 mismatch" && [ ! -d "$CC/pvautonomy_ops" ]; then
  ok "aborted (rc=$RC), no install dir created"
else
  bad "expected abort with no install (rc=$RC, version=$(iv "$CFG"))"
fi

echo
echo "== T2: fresh install, correct sha -> installs 0.4.0"
run_installer "$M_040_GOOD" "$CFG"
if [ "$RC" -eq 0 ] && [ "$(iv "$CFG")" = "0.4.0" ]; then
  ok "installed version=$(iv "$CFG")"
else
  bad "expected 0.4.0 (rc=$RC, version=$(iv "$CFG"))"
fi

echo
echo "== T3: re-run same version -> already installed, no change"
run_installer "$M_040_GOOD" "$CFG"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "already installed" && [ "$(iv "$CFG")" = "0.4.0" ]; then
  ok "idempotent (version still $(iv "$CFG"))"
else
  bad "expected 'already installed' (rc=$RC, version=$(iv "$CFG"))"
fi

echo
echo "== T4: update 0.4.0 -> 0.4.1 with WRONG sha -> abort, 0.4.0 preserved"
run_installer "$M_041_BAD" "$CFG"
if [ "$RC" -ne 0 ] && [ "$(iv "$CFG")" = "0.4.0" ]; then
  ok "aborted (rc=$RC), still on $(iv "$CFG")"
else
  bad "expected 0.4.0 preserved (rc=$RC, version=$(iv "$CFG"))"
fi

echo
echo "== T5: update 0.4.0 -> 0.4.1 correct sha -> installs 0.4.1 + backup kept"
run_installer "$M_041_GOOD" "$CFG"
BK_040="$(ls -d "$CC"/.pvautonomy_ops.bak.0.4.0 2>/dev/null || true)"
if [ "$RC" -eq 0 ] && [ "$(iv "$CFG")" = "0.4.1" ] && [ -n "$BK_040" ] && [ -d "$BK_040" ]; then
  ok "updated to $(iv "$CFG"), backup at $(basename "$BK_040")"
else
  bad "expected 0.4.1 + backup (rc=$RC, version=$(iv "$CFG"), backup='$BK_040')"
fi

echo
echo "== T6: update 0.4.1 -> 0.4.2, forced sanity failure -> rollback to 0.4.1"
run_installer "$M_042_GOOD" "$CFG" PVA_TEST_FORCE_SANITY_FAIL=1
if [ "$RC" -ne 0 ] && echo "$OUT" | grep -q "rolled back" && [ "$(iv "$CFG")" = "0.4.1" ]; then
  ok "rolled back, version restored to $(iv "$CFG")"
else
  bad "expected rollback to 0.4.1 (rc=$RC, version=$(iv "$CFG"))"
fi

echo
echo "============================================================"
echo "  RESULT: $PASS passed, $FAIL failed"
echo "============================================================"
[ "$FAIL" -eq 0 ]
