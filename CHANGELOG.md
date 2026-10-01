# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0-strata] - 2026-07-11

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
