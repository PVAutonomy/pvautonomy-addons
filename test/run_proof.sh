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

# plant_legacy_backup <config-dir> <version> — simulate a pre-0.1.2 in-tree
# dot-dir backup (the HA-loader hazard this fix removes).
plant_legacy_backup() {
  local d="$1/custom_components/.pvautonomy_ops.bak.$2"
  mkdir -p "$d"
  printf '{"domain":"pvautonomy_ops","name":"PVAutonomy Ops","version":"%s"}\n' "$2" > "$d/manifest.json"
  printf '"""legacy backup %s"""\n' "$2" > "$d/__init__.py"
}

# dotbaks <cc> — list any in-tree dot-dir backups (must always be empty post-fix).
dotbaks() { ls -d "$1"/.pvautonomy_ops.bak.* 2>/dev/null || true; }

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
echo "== T5: update 0.4.0 -> 0.4.1 -> installs 0.4.1; backup OUTSIDE custom_components"
run_installer "$M_041_GOOD" "$CFG"
BK_SAFE="$CFG/pvautonomy_backups/pvautonomy_ops.bak.0.4.0"   # (1)+(2) safe location
LEFT="$(dotbaks "$CC")"                                       # (1) none under custom_components
if [ "$RC" -eq 0 ] && [ "$(iv "$CFG")" = "0.4.1" ] && [ -d "$BK_SAFE" ] && [ -z "$LEFT" ]; then
  ok "updated to $(iv "$CFG"); backup in pvautonomy_backups/; none under custom_components"
else
  bad "expected 0.4.1 + safe backup + no in-tree dotdir (rc=$RC, version=$(iv "$CFG"), safe_exists=$([ -d "$BK_SAFE" ] && echo y || echo n), in_tree='$LEFT')"
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
echo "== T7: legacy in-tree backup is migrated out of custom_components on update"
# Config is on 0.4.1 after T6 (forced rollback). Plant a pre-0.1.2 dot-dir backup.
plant_legacy_backup "$CFG" 0.3.9
run_installer "$M_042_GOOD" "$CFG"
GONE7=1; [ -d "$CC/.pvautonomy_ops.bak.0.3.9" ] && GONE7=0   # (3) legacy dir removed from cc
LEFT="$(dotbaks "$CC")"                                      # (3) no in-tree dotdirs at all
if [ "$RC" -eq 0 ] && [ "$(iv "$CFG")" = "0.4.2" ] && [ "$GONE7" -eq 1 ] && [ -z "$LEFT" ] \
   && echo "$OUT" | grep -q "found legacy custom_components backup" \
   && echo "$OUT" | grep -q "migrated legacy backup -> .*/pvautonomy_backups/"; then
  ok "updated to $(iv "$CFG"); legacy dotdir migrated out of custom_components"
else
  bad "expected legacy migrate on update (rc=$RC, version=$(iv "$CFG"), gone=$GONE7, in_tree='$LEFT')"
fi

echo
echo "== T8: legacy cleanup runs even when already up to date (installed==target, force=0)"
plant_legacy_backup "$CFG" 0.3.8
run_installer "$M_042_GOOD" "$CFG"      # 0.4.2 already installed, force=0 -> early return
GONE8=1; [ -d "$CC/.pvautonomy_ops.bak.0.3.8" ] && GONE8=0   # (4) cleanup despite early return
LEFT="$(dotbaks "$CC")"
if [ "$RC" -eq 0 ] && echo "$OUT" | grep -q "already installed" && [ "$GONE8" -eq 1 ] \
   && [ -z "$LEFT" ] && echo "$OUT" | grep -q "found legacy custom_components backup"; then
  ok "already-installed run still cleaned the legacy dotdir"
else
  bad "expected legacy cleanup on already-installed run (rc=$RC, gone=$GONE8, in_tree='$LEFT')"
fi

echo
echo "============================================================"
echo "  RESULT: $PASS passed, $FAIL failed"
echo "============================================================"
[ "$FAIL" -eq 0 ]
