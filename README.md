# PVAutonomy Add-ons

Home Assistant **add-on repository** for PVAutonomy. It provides a
customer-friendly install/update path for the PVAutonomy Ops integration that
needs **no GitHub account and no HACS**.

> **Requirement:** Home Assistant **OS** or **Supervised** (the Supervisor is
> required to run add-ons). Home Assistant **Container / Core** are not
> supported by this path in the MVP — they have no add-on store.

## Add this repository

Settings → Add-ons → Add-on Store → ⋮ (top-right) → **Repositories** → paste:

```
https://github.com/PVAutonomy/pvautonomy-addons
```

→ **Add** → close. The store now lists **PVAutonomy Installer / Updater**.

## Add-ons

| Add-on | Purpose |
|--------|---------|
| [PVAutonomy Installer / Updater](pvautonomy_installer/) | Downloads the public PVAutonomy Ops release artifact, verifies its SHA‑256, and installs/updates `custom_components/pvautonomy_ops`. |

## How distribution works

```
PVAutonomy/pvautonomy-ops (public)        PVAutonomy/pvautonomy-addons (public)
  release vX.Y.Z                            integration/stable.json  ── version + URL + sha256
   ├── pvautonomy_ops-X.Y.Z.zip   ◄─────────┘ (pinned, deterministic download URL)
   └── pvautonomy_ops-X.Y.Z.zip.sha256
                                            pvautonomy_installer  ── reads manifest, verifies, installs
```

The release ZIP and its checksum live on `pvautonomy-ops` releases (single
source of truth for the integration). The channel manifests here pin an exact
version + deterministic download URL + SHA‑256 so the installer never depends
on a release redirect.

## Channels

- `integration/stable.json` — production channel.
- `integration/beta.json` — early-access channel.

## Scope / boundary

This repository contains **only** public distribution assets (add-on + channel
manifests). It does not contain integration source code, secrets, customer
data, or anything targeting private household systems.
