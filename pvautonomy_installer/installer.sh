#!/usr/bin/env bash
# PVAutonomy Ops — installer / updater core logic.
#
# Pure bash, no bashio dependency, so it can be driven both from run.sh (inside
# the add-on) and from the local proof harness (test/run_proof.sh).
#
# Inputs (environment):
#   PVA_MANIFEST_URL   required   channel manifest (https:// for production, or a
#                                 local path / file:// for the test harness)
#   PVA_CONFIG_DIR     default /config   Home Assistant config directory
#   PVA_FORCE          default 0   reinstall even if installed version == target
#   PVA_ALLOW_WITH_HACS default 0  proceed even if HACS already manages this
#                                 integration (override the canonical-path guard;
#                                 see issue config #58)
#
# Test-only hook:
#   PVA_TEST_FORCE_SANITY_FAIL=1  force the post-install sanity check to fail,
#                                 to exercise the rollback path.
#
# Exit codes: 0 = installed or already up to date; non-zero = fatal (no
# "success with warnings"). Any failure after the backup step rolls back.
#
# Backups live OUTSIDE custom_components (in $PVA_CONFIG_DIR/pvautonomy_backups).
# Home Assistant's loader scans every subdirectory of custom_components/ that has
# a manifest.json — including dot-prefixed ones — and builds the import path as
# "custom_components.<dirname>". A backup placed inside custom_components as
# ".pvautonomy_ops.bak.<ver>" therefore yields the import path
# "custom_components..pvautonomy_ops.bak.<ver>" (empty segment) and crashes setup
# with: No module named 'custom_components.'. Keeping backups outside the scanned
# tree avoids that loader collision entirely.

set -euo pipefail

PVA_CONFIG_DIR="${PVA_CONFIG_DIR:-/config}"
PVA_FORCE="${PVA_FORCE:-0}"
PVA_ALLOW_WITH_HACS="${PVA_ALLOW_WITH_HACS:-0}"
COMPONENT="pvautonomy_ops"
KEEP_BACKUPS=2
# Backup root: a sibling of custom_components, never scanned by the HA loader.
BACKUP_RELDIR="pvautonomy_backups"

# File-scope work dir so the EXIT trap can see it after main() returns.
work=""
_cleanup() { [ -n "${work:-}" ] && rm -rf "$work"; return 0; }
trap _cleanup EXIT

log()   { echo "[pva-installer] $*"; }
fatal() { echo "[pva-installer] FATAL: $*" >&2; exit 1; }

sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# fetch <src> <dest> — https:// via curl (TLS enforced), or a local path/file://
# for the test harness. Plain http:// is refused.
fetch() {
  local src="$1" dest="$2"
  case "$src" in
    https://*)
      curl -fsSL --proto '=https' --tlsv1.2 --max-time 120 -o "$dest" "$src" \
        || fatal "download failed: $src" ;;
    http://*)
      fatal "refusing insecure http:// URL: $src" ;;
    file://*)
      cp -- "${src#file://}" "$dest" || fatal "copy failed: $src" ;;
    *)
      cp -- "$src" "$dest" || fatal "copy failed: $src" ;;
  esac
}

# read_json <file> <jq-filter> — fails (non-zero) on null/missing via jq -e.
read_json() { jq -er "$2" "$1" 2>/dev/null; }

installed_version() {
  local mf="$PVA_CONFIG_DIR/custom_components/$COMPONENT/manifest.json"
  if [ -f "$mf" ]; then
    jq -er '.version' "$mf" 2>/dev/null || echo "unknown"
  else
    echo "none"
  fi
}

# hacs_manages_component — returns 0 (true) if HACS already manages (has
# installed) this integration on this system. Read from HACS's own storage so the
# add-on never dual-manages the same files as HACS: issue config #58 makes HACS
# the canonical install/update path, and running both lets their version trackers
# diverge into a "split-brain". Recurses the HACS store and matches the repo
# full_name with an installed flag; tolerant of HACS storage-schema differences
# (modern hacs.data vs. legacy hacs.repositories). Unparseable/missing stores ->
# treated as "not managed" so a system without HACS installs normally.
hacs_manages_component() {
  local f
  for f in "$PVA_CONFIG_DIR/.storage/hacs.data" "$PVA_CONFIG_DIR/.storage/hacs.repositories"; do
    [ -f "$f" ] || continue
    if jq -e '
          [ .. | objects
            | select((.full_name? // "" | tostring | ascii_downcase) == "pvautonomy/pvautonomy-ops")
            | select(.installed? == true) ]
          | length > 0
        ' "$f" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

verify_install() {
  local dir="$1" want="$2" got
  [ -f "$dir/manifest.json" ] || { log "missing manifest.json"; return 1; }
  [ -f "$dir/__init__.py" ]   || { log "missing __init__.py"; return 1; }
  got="$(jq -er '.version' "$dir/manifest.json" 2>/dev/null)" \
    || { log "unreadable installed manifest"; return 1; }
  [ "$got" = "$want" ] || { log "installed version $got != target $want"; return 1; }
  [ "${PVA_TEST_FORCE_SANITY_FAIL:-0}" = "1" ] && { log "test hook: forced sanity failure"; return 1; }
  return 0
}

prune_backups() {
  local bkroot="$1" pattern
  pattern="$bkroot/${COMPONENT}.bak."
  local -a backups=()
  local f
  # shellcheck disable=SC2012  # names are controlled; ls -t gives newest-first by mtime
  while IFS= read -r f; do backups+=("$f"); done < <(ls -dt "${pattern}"* 2>/dev/null || true)
  [ "${#backups[@]}" -gt 0 ] || return 0
  local i=0
  for f in "${backups[@]}"; do
    i=$((i + 1))
    if [ "$i" -gt "$KEEP_BACKUPS" ]; then
      log "pruning old backup: $f"
      rm -rf "$f"
    fi
  done
}

# legacy_backup_cleanup <cc> <bkroot> — migrate/remove pre-0.1.2 backups that
# were written as dot-dirs INSIDE custom_components (the HA-loader hazard). Runs
# on every installer invocation, even when already up to date. Each legacy dir
# is moved into the safe backup root (leading dot stripped from the name); if a
# same-named safe backup already exists, the legacy copy is removed instead.
legacy_backup_cleanup() {
  local cc="$1" bkroot="$2" f base target found=0
  # Pattern starts with a literal dot, so it matches hidden dirs without dotglob.
  for f in "$cc/.${COMPONENT}.bak."*; do
    [ -e "$f" ] || continue          # no match -> literal pattern, skip
    found=$((found + 1))
    base="$(basename "$f")"          # .pvautonomy_ops.bak.<ver>[.<pid>]
    base="${base#.}"                 # -> pvautonomy_ops.bak.<ver>[.<pid>]
    log "found legacy custom_components backup: $f"
    mkdir -p "$bkroot"
    target="$bkroot/$base"
    if [ -e "$target" ]; then
      rm -rf "$f"
      log "removed legacy backup (safe copy already present): $f"
    elif mv "$f" "$target" 2>/dev/null; then
      log "migrated legacy backup -> $target"
    else
      rm -rf "$f"
      log "removed legacy backup (migration failed): $f"
    fi
  done
  [ "$found" -gt 0 ] && prune_backups "$bkroot"
  return 0
}

print_restart_notice() {
  local from="$1" to="$2"
  echo
  echo "============================================================"
  if [ "$from" = "none" ]; then
    echo " PVAutonomy Ops $to was INSTALLED."
  else
    echo " PVAutonomy Ops updated: $from -> $to"
  fi
  echo
  echo " NEXT STEP (required): restart Home Assistant"
  echo "   Settings -> System -> (power menu, top right) -> Restart Home Assistant"
  echo
  echo " After the restart, add or reconfigure the integration under"
  echo "   Settings -> Devices & Services -> Add Integration -> PVAutonomy"
  echo "============================================================"
}

main() {
  [ -n "${PVA_MANIFEST_URL:-}" ] || fatal "PVA_MANIFEST_URL not set"
  command -v jq    >/dev/null 2>&1 || fatal "jq not available"
  command -v unzip >/dev/null 2>&1 || fatal "unzip not available"

  # Canonical-path guard (issue config #58). HACS is the canonical install/update
  # path for this integration; if HACS already manages it on this system, refuse
  # before doing anything — running the add-on too would diverge the two version
  # trackers (split-brain). The genuine no-HACS-edge / firmware-bootstrap case can
  # override with allow_with_hacs. This runs before any side effect (no manifest
  # fetch, no legacy backup migration, no writes).
  if hacs_manages_component; then
    if [ "$PVA_ALLOW_WITH_HACS" = "1" ]; then
      log "WARN: HACS manages PVAutonomy Ops on this system; proceeding anyway (allow_with_hacs=1). You are responsible for keeping HACS and this add-on consistent."
    else
      fatal "HACS already manages PVAutonomy Ops on this system. HACS is the canonical install/update path — update the integration via HACS, not this add-on (this add-on is for systems WITHOUT HACS). No changes were made. To override intentionally, set the add-on option 'allow_with_hacs: true'. See https://github.com/PVAutonomy/pvautonomy-config/issues/58"
    fi
  fi

  work="$(mktemp -d)"

  log "fetching channel manifest: $PVA_MANIFEST_URL"
  fetch "$PVA_MANIFEST_URL" "$work/manifest.json"

  local target url sha root_path
  target="$(read_json "$work/manifest.json" '.version')"               || fatal "manifest: missing .version"
  url="$(read_json "$work/manifest.json" '.artifact.url')"             || fatal "manifest: missing .artifact.url"
  sha="$(read_json "$work/manifest.json" '.artifact.sha256')"          || fatal "manifest: missing .artifact.sha256"
  root_path="$(read_json "$work/manifest.json" '.artifact.root_path')" || fatal "manifest: missing .artifact.root_path"

  local cc="$PVA_CONFIG_DIR/custom_components"
  local dest="$cc/$COMPONENT"
  local bkroot="$PVA_CONFIG_DIR/$BACKUP_RELDIR"
  log "backup location = $bkroot"

  # Always migrate/remove legacy in-tree dot-dir backups first — even when we are
  # already up to date and will return early below.
  legacy_backup_cleanup "$cc" "$bkroot"

  local current
  current="$(installed_version)"
  log "installed=$current target=$target force=$PVA_FORCE"

  if [ "$current" = "$target" ] && [ "$PVA_FORCE" != "1" ]; then
    log "PVAutonomy Ops $target is already installed — nothing to do."
    return 0
  fi

  log "downloading artifact: $url"
  fetch "$url" "$work/artifact.zip"

  local got
  got="$(sha256_of "$work/artifact.zip")"
  if [ "$got" != "$sha" ]; then
    fatal "sha256 mismatch (expected $sha, got $got) — aborting, no changes made."
  fi
  log "sha256 verified: $got"

  mkdir -p "$work/stage"
  unzip -q "$work/artifact.zip" -d "$work/stage" || fatal "unzip failed"
  local src_dir="$work/stage/$root_path"
  [ -d "$src_dir" ]                  || fatal "artifact missing expected path: $root_path"
  [ -f "$src_dir/manifest.json" ]    || fatal "artifact missing manifest.json"

  mkdir -p "$cc"

  # Back up an existing install before we touch it — OUTSIDE custom_components so
  # the HA loader never enumerates it as an integration (see header note).
  local backup=""
  if [ -d "$dest" ]; then
    mkdir -p "$bkroot"
    backup="$bkroot/.${COMPONENT}.bak.${current}.$$"
    log "backing up existing $current -> $backup"
    mv "$dest" "$backup" || fatal "backup move failed"
  fi

  # Install. Any failure from here rolls back to the backup.
  if ! mv "$src_dir" "$dest"; then
    [ -n "$backup" ] && mv "$backup" "$dest"
    fatal "install move failed — rolled back."
  fi

  if ! verify_install "$dest" "$target"; then
    rm -rf "$dest"
    if [ -n "$backup" ]; then
      mv "$backup" "$dest"
      fatal "post-install verification failed — rolled back to $current."
    fi
    fatal "post-install verification failed — removed broken install."
  fi

  # Success. Give the backup a stable name and prune old ones (in the safe root).
  if [ -n "$backup" ]; then
    mv "$backup" "$bkroot/${COMPONENT}.bak.${current}" 2>/dev/null || true
    prune_backups "$bkroot"
  fi

  log "PVAutonomy Ops $target installed at $dest"
  print_restart_notice "$current" "$target"
  return 0
}

main "$@"
