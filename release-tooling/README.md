# Release tooling (draft — for the `pvautonomy-ops` repo)

These files are **design drafts**. They do not belong to this add-on repository
at runtime; they describe a change to be made in **`PVAutonomy/pvautonomy-ops`**.

## `package-release-asset.yml`

Target location (in the other repo):
`.github/workflows/package-release-asset.yml`

On every published release it builds:

- `pvautonomy_ops-<version>.zip` — contains `custom_components/pvautonomy_ops/…`
  (the `root_path` the installer expects), excluding `__pycache__` and `tests`.
- `pvautonomy_ops-<version>.zip.sha256`

…and uploads both as release assets, giving the installer a deterministic,
checksummed download URL.

## After a release (manual step for now)

1. Read the new SHA‑256 from the workflow log (or the `.sha256` asset).
2. Update `integration/stable.json` here:
   - `version` → new version
   - `artifact.url` → `…/releases/download/v<version>/pvautonomy_ops-<version>.zip`
   - `artifact.sha256` → new checksum
3. Commit (as `gshubi`, with a separate GO).

A follow-up can automate step 2 (the release workflow opens a PR against this
repo). Out of scope for the proof-only scaffold.

## Not done here

No push, no release, no tag, no workflow activation. Activating this requires
`gshubi` auth and a separate GO.
