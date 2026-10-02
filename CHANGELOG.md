# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2-strata] - 2026-10-02

### Fixed

- **Silent bootstrap crash in `[1/6]` (CUDA repo key 404)** — the in-container
  bootstrap fetched its GPG key from
  `https://developer.download.nvidia.com/compute/cuda/12.8/keys/cuda-12.8_prod.asc`,
  which now returns **404**. Because that `wget` ran with `-q` under
  `set -euo pipefail`, the whole bootstrap died with **zero output** — the
  deploy appeared to stop right after the base `apt-get install` finished.
  Now uses the noble repo key
  `https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub`
  (verified to sign the ubuntu2404 repo's InRelease: "cudatools
  <cudatools@nvidia.com>", RSA fingerprint EB69 3B30 35CD 5710 E231 E123
  A4B4 6996 3BF8 63CC) and a `|| fatal` guard so any future key-fetch failure
  prints a real error instead of dying silently.

- **CUDA toolkit package name** — `cuda-toolkit-12.8=12.8.0-1` is not a valid
  apt package on noble (would have been the *next* silent crash, after the key
  fix, at `E: Unable to locate package`). The real metapackage is
  `cuda-toolkit-12-8=12.8.0-1` (dashes, not dots). The script now derives it
  from `$CUDA_MAJOR` (`cuda-toolkit-${CUDA_MAJOR//./-}`). Verified live against
  the ubuntu2404 repo's Packages index.

## [1.0.1-strata] - 2026-10-01

### Fixed

- **Template ensure (PVE 9.2)** — `[1/7]` used the nonexistent `pveam install`
  and then a filesystem check on `/var/lib/vz/template/ct/` (that directory does
  not exist on PVE 9.2; `local` vztmpl archives live under
  `/var/lib/vz/template/cache/`). Now uses `pveam update && pveam download local
  <template>` and verifies storage membership via `pveam list local`.
  Verified live: template present at `local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst`.

  PVE 9.2 `pct create` notes (already handled by the script): template is a
  **positional** argument (`pct create <vmid> <ostemplate> ...`), the volume ID
  carries the `vztmpl/` prefix, and there is **no `--name` parameter** (passing
  one triggers a bogus `nameserver: invalid format` 400 on 9.2.20).

## [1.0.0-strata] - 2026-10-01

### Added

- **Initial release: Strata AI engine on the V100 (LXC 115, 192.168.1.15).**
  - `deploy-hlh-ai-engine-strata.sh` (host-side): host driver check (R580 580.65.06
    / CUDA 12.8 pin, greenfield `.run --dkms` path included), template ensure,
    stale LXC 115 cleanup, **V100 cutover: stop LXC 111 (hlh-ai-engine-egpu) +
    onboot 0 (config kept for revert)**, privileged LXC 115 (12 cores, 48 GB RAM,
    64 GB rootfs on RaidZ1-6TB, /srv/ai/models mp0, IP .15, onboot 1), V100
    cgroup + /dev/nvidia* bind wiring, bootstrap push + run.
  - `configure-hlh-ai-engine-strata.sh`: CUDA 12.8 (final sm_70 toolkit) +
    userspace 580.65.06 apt-pinned with exact-match FATAL gate, Strata 0.1.32
    pinned `c499bd1`, engine build **`-DSTRATA_EXPERIMENTAL_SM60=ON`** (Volta
    sm_70 community path, Strata #295/#236), IQ2_XS install (~68 GB download +
    pack) into /srv/ai/models/strata, 128 K context / int8 KV / vision off,
    systemd `strata.service` on port 80 (drop-in for the old llama.cpp :80
    endpoint).

### Notes

- Strata requires CUDA 12.x for sm_70 (CUDA 13 dropped sm_60/sm_70) and driver
  ≤ R580 (590+ drops Volta). Host stays on 580.65.06 / 6.14.11-9-pve.
- Performance is below Strata README benchmarks (cc 7.0 experimental build,
  Gen3 x2 link) — see README.
