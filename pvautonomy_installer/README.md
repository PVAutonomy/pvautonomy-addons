# PVAutonomy Installer / Updater

Installs and updates the **PVAutonomy Ops** integration into
`/config/custom_components/pvautonomy_ops` — **no GitHub account, no HACS**.

> **Requirement:** Home Assistant **OS** or **Supervised**. (Add-ons need the
> Supervisor; Container/Core are not supported in this MVP.)

> **Versions:** the add-on's own version (e.g. `0.1.x`) is the *installer*
> version. The **PVAutonomy Ops integration** it installs is a separate version
> defined by the channel manifest — currently **0.4.1**.

## What it does

1. Reads a channel manifest (`stable` or `beta`) that pins an exact version,
   a deterministic download URL, and a SHA‑256.
2. Downloads the public PVAutonomy Ops release ZIP.
3. **Verifies the SHA‑256 before writing anything.** On mismatch it aborts and
   leaves your current install untouched.
4. Backs up any existing install, then installs the new files.
5. Verifies the result; on any failure it **rolls back** to the previous version.
6. Tells you to **restart Home Assistant** (required to load the new code).

## Options

| Option | Default | Meaning |
|--------|---------|---------|
| `channel` | `stable` | Which channel manifest to use (`stable` or `beta`). |
| `force_reinstall` | `false` | Reinstall even if the installed version already matches. |

## Customer flow

1. **Start** the add-on (Add-on page → *Start*).
2. Watch the **Log** tab — it prints the version, the verified checksum, and the
   result.
3. **Restart Home Assistant** (Settings → System → power menu → *Restart*).
4. Add/configure the integration: Settings → Devices & Services → *Add
   Integration* → **PVAutonomy**.
5. To update later: **Start** the add-on again. It only changes anything when a
   newer version is published, then asks you to restart.

> The first restart after a fresh install may take a little longer and needs
> internet access: Home Assistant installs the integration's Python dependency
> (`pyhpke`) from the integration manifest on load.

## Safety

- HTTPS-only downloads; plain `http://` is refused.
- SHA‑256 verified **before** any file is written.
- Automatic backup + rollback around every change (last 2 backups kept under
  `/config/pvautonomy_backups/pvautonomy_ops.bak.<version>`). Backups live
  **outside** `custom_components/` on purpose: Home Assistant's loader scans
  every sub-directory there (including dot-prefixed ones), so an in-tree backup
  would collide with the loader and break the integration import. Any legacy
  `custom_components/.pvautonomy_ops.bak.*` from older installer versions is
  migrated to the safe location automatically on the next run.
- No secrets, no account, no customer data leaves the device.
- Failures are fatal with a clear message — never "success with warnings".

## MVP limitations (tracked as follow-ups)

- No `auto_restart`: the restart is a manual, clearly-instructed step.
- HA Container / Core not supported (no add-on store) — separate follow-up.
