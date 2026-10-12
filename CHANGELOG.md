# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.4.0] - 2026-10-12

### Changed (Phase 3 item 10 — IQ3_XXS cutover, 3phase-tunning.md §3.3)

- **Model IQ3_S -> IQ3_XXS** (live cutover ~00:53 EDT, ~25 min downtime):
  SSD pair swapped (70.6 GiB XXS for 77.9 GiB S), re-packed from local SSD
  shards (engine build reused), Phase 1+2 flags carried into
  `strata-iq3_xxs.json`, `strata.service` repointed (old unit kept as
  `strata.service.bak-iq3_s`). Rollback intact: `packs/iq3_s` + HDD IQ3_S
  shards untouched.
- **Deploy script gaps fixed (§3.4):** `GGUF_STEM` parameterized via
  `--model`/`MODEL_QUANT`, `avail >= pair + 8G` capacity gate before seeding,
  `LXC_MEMORY` 56320 -> 58320 (live CT 115).

### Measured (live, 2026-10-12, first boot)

- Expert cache **15,658 slots** (was 12,598); `--kv-grow` honored (elastic KV
  16,384/131,072 cells in VRAM); prefill ring 384 slots; `--adapt-async`
  auto-off (needs `--resident-experts`; setup chose normal mode on 57 GB).
- Cold 58-token probe: prefill 31.1 tok/s, decode 29.6 tok/s, hit rate 86.9%.
- Rollback: copy IQ3_S pair back to `/strata-models`, restore
  `strata.service.bak-iq3_s`, `systemctl restart strata`.

## [0.3.0] - 2026-10-11

### Changed (Phase 2 tuning — 3phase-tunning.md)

- **Runtime flags** (live ad-hoc on LXC 115 + IaC in `configure`):
  `--pool-workers 10`, `--lookup-chain 2`, `--prompt-cache-tail`,
  `--conversation-cache-mib 4096` (tuned down from the plan's 8192 to
  protect the expert page cache).

### Measured (live, 2026-10-11)

- Decode **41.8–47.5 tok/s** on real traffic (baseline typical 34).
- 91k-token conversation parked/restored in ~0.4–0.7 s; follow-up request
  reused 91,334 of 92,226 tokens (892 fresh read in 5.2 s).
- Lookup chain accepted 15 of 34 chained drafts.
- Rollback: `/opt/strata/strata-iq3_s.json.bak-phase1` + service restart.

## [0.2.0] - 2026-10-11

### Changed (Phase 1 tuning — 3phase-tunning.md)

- **Runtime flags** (live ad-hoc on LXC 115 + IaC in `configure`):
  `--kv k8v4` (INT8 K + Q4_0 V, 816 vs 1056 B/cell), `--prefill auto:16384`,
  `--adapt-async 1`, `--expert-profile-save <profile> --expert-profile-save-every 10`,
  `--kv-grow` (engine auto-disabled it in this config — harmless).
- `configure`: new post-setup step patches the engine-only flags into the
  config JSON's args array (setup.sh only knows `--kv`); idempotent.
  Also fixed an `a += [...]` UnboundLocalError in the patch helper.

### Measured (live, 2026-10-11)

- Prefill **367–779 tok/s** (baseline 48–106) — 3.5–7x faster.
- Decode **43.5 tok/s warm** (baseline typical 34).
- Expert cache 12,598 slots (was 12,418); 0 major faults; hit rate
  90.3–90.6% while the learned profile re-adapts (was 94–95.5%) — watch.
- Rollback: `/opt/strata/strata-iq3_s.json.bak-0.1.0` + service restart.

## [0.1.0] - 2026-10-11

### Notes

- **Versioning reset: 0.1.0 is the working baseline.** The currently pushed
  state (deploy/configure scripts unchanged since the `1.0.4-strata` commit)
  is tagged **v0.1.0** — the starting point for the 3-phase tuning plan
  ([3phase-tunning.md](3phase-tunning.md)). The `1.0.x-strata` labels in
  commit messages and the entries below are historical.
- **Measured baseline (live LXC 115, 2026-10-11):** decode **34 tok/s**
  (typical range 26–43, thinking tokens), prefill 48–106 tok/s on fresh
  prompt reads, expert cache hit rate 94–95.5%, engine 0.1.41 on
  Qwen3.8-Flash-Next IQ3_S.

### Added

- `3phase-tunning.md` — 3-phase tuning plan from the 2026-10-11 engine audit
  (Phase 1 VRAM reclaim + prefill flags, Phase 2 CPU pool + speculation,
  Phase 3 model + hardware), with baseline table and rollback notes.

## [1.0.4-strata] - 2026-10-10

### Changed

- **LXC 115 memory 48 GB -> 55 GB.** Discovery on the live CT (2026-10-10):
  `memory.current == memory.max` (47.0/47.0 GiB) - the CT was AT its cgroup
  limit, not 30% idle. Strata pins ~26.7 GiB of experts page-locked
  (`--resident-experts` complement of the GPU cache) + ~2.7 GiB runtime; the
  remaining ~18 GiB is page cache for the mmap'd 78 GB expert GGUFs, and the
  engine log showed it evicting model cache to pin the tier plus 13M+ major
  faults / 73 GB of expert re-reads from SSD while serving. The extra 7 GB
  goes to that mmap cache (tier sizes are set by VRAM + model, not by RAM).
  Host budget (prox01, 61.9 GiB physical, no swap): leaves ~6.9 GiB for
  PVE/host (~4.5 GiB incl. kernel), CT 109 hlh-docker (cap 4, actual ~1) and
  VM 103 pbs4 (cap 4, actual ~1.1); ZFS ARC already capped at 6 GiB. CT115's
  non-reclaimable tier is fixed at ~29.4 GiB regardless of the cap (pinned
  experts are sized by the model, not the limit), so the raise cannot cause a
  host OOM - under PBS-backup/docker bursts the kernel reclaims ~5-6 GiB of
  CT115 expert page cache instead. 52 GiB would be the conservative pick;
  55 chosen deliberately to use all the headroom available.
  NOTE: IaC-only change; the live CT 115 still has 48 GB until rebuilt or
  `pct set 115 --memory 56320` (plus a reboot/balloon to take effect).

## [1.0.3-strata] - 2026-10-10

### Changed

- **Model shards moved to SSD (greenfield parity).** On 2026-10-09 the live CT
  115 was fixed by hand: the 78 GB IQ3_S GGUF shard pair was moved from the
  RaidZ1-6TB HDD pool (model load/pack crawled) to the SSD pool, and the repo
  was NOT updated — a rebuild would have regressed straight back to the slow
  HDD location. The IaC now reproduces the fast layout from scratch:
  - `deploy`: `[4/7]` ensures ZFS dataset `rpool/strata-models` (mountpoint
    `/strata-models`, override pool with `SSD_POOL=...`) and idempotently seeds
    the IQ3_S shard pair onto it (copies from `/srv/ai/models` if not already
    on SSD). LXC 115 is created with **`mp1 /strata-models,mp=/srv/ssd-models`**
    beside the existing `mp0 /srv/ai/models`.
  - `configure`: `--gguf-dir` now defaults to **`/srv/ssd-models`** (SSD bind)
    instead of `/srv/ai/models` (HDD). Packs/MTP/tokenizer stay on
    `/srv/ai/models/strata` (`mp0`) — matches the validated live config, and
    the SSD dataset has no headroom for a second 78 GB copy.
  - Docs (README exec summary, quick start, deployment model, rebuild notes)
    updated to the shards-on-SSD / packs-on-HDD split; model references
    corrected IQ2_XS → IQ3_S (the 1.0.2-era default change was never
    reflected in the README).

### Notes

- Since 1.0.2 (see git log): default model is IQ3_S from local shards, and the
  580 userspace pinning was hardened (base-match resolution + 6-package FATAL
  gate).
- The 78 GB IQ3_S shards + merged `IQ3_S.gguf` still sit on RaidZ1-6TB under
  `/srv/ai/models` as the seed source; delete them only if you no longer want
  a rebuild to be download-free.

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
