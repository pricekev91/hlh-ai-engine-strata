# Changelog

All notable changes to this repository are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.5.0] - 2026-10-15

### Added (vision — the engine can read pictures)

- **`--vision` defaults to `gpu`** (`configure-…sh: STRATA_VISION`,
  `deploy-…sh: VISION_MODE`). The IaC had always passed `--vision no`, so
  `strata-vision` was never compiled and the mmproj encoder never fetched:
  `/health` reported `"images": false`, `/v1/models` reported
  `"input_modalities": ["text"]`, and every image request died with
  `this server was started without the vision encoder` (HTTP 400).
- New flags: `--vision gpu|cpu|no` and `--vision-tokens N` on the bootstrap,
  `--vision gpu|cpu|no` and `--vision-tokens N` on the deploy script. Both are
  forwarded into the container (`--bootstrap-inside` re-parses argv inside the
  CT, so a flag that is not forwarded is silently lost). `yes` is accepted as a
  synonym for `gpu` because `setup.sh` speaks yes/no.
- What the GPU path costs here: `mmproj-Qwen3.8-Flash-Next-BF16.gguf`
  (907,543,008 B, sha256 `b1a82259…49bd0`, ISTA-DASLab) into
  `/srv/ai/models/strata/models` — **mp0, the HDD pool**, because
  `rpool/strata-models` has no room and the encoder is read once at start, not
  per token — plus a ~10–20 min `strata-vision` compile in `build-vision-cuda12`
  with the *same* `CMAKE_CUDA_ARCHITECTURES` as the engine (sm_70, CUDA 12.8),
  installed next to it in `engine-cuda12/` (`engine_dir()` picks that folder for
  toolkit 12 — not `engine/`).
  The encoder holds ~1.2 GB at 1024 image tokens → ~1,000 fewer expert slots
  (upstream: 2–8 % slower text; here the 94–95 % hit rate is the decode lever).
- Pre-flight says which of setup's three mmproj paths it takes (already in
  `<data-dir>/models` / in `--gguf-dir`, used in place / download 0.9 GB).

### Fixed

- **`deploy-…sh --model` never reached the bootstrap.** `[6/7]` pushed the
  bootstrap and ran it with only `--bootstrap-inside`, so `--model IQ3_XXS`
  seeded the SSD dataset with XXS and then packed the compiled-in default
  IQ3_S. `--model` and `--vision` are now forwarded explicitly.
- **The LXC description ignored the CLI.** `LXC_DESC` was built *before* option
  parsing, so `pct create` always wrote the default quant and vision mode. It is
  now built after validation.
- **Vision is verified, not assumed.** The bootstrap fails when no
  `strata-vision` helper is found (config `vision.exe`, else
  `engine-cuda12/strata-vision`, else `engine/strata-vision`) or when the
  config's `vision.mmproj` is not a file, and both scripts warn when `/health`
  does not report `"images": true` after start. A silent text-only fallback is
  what made this invisible for so
  long. Re-running `setup.sh` still rewrites `strata-iq3_s.json`, but the
  Phase 1+2 tuning patch runs *after* setup in the same bootstrap, so a nuke +
  rebuild keeps the tuning and now also the encoder.

### Docs

- README: new **Vision (images)** section — weights, binary, VRAM cost, the
  `--vision-tokens` / `--vision cpu` / `vram_elastic` escape hatches, and the
  post-rebuild checks. Caveat recorded: **upstream has no sm_70 vision report**
  (`NVIDIA_V100.md` / `OLDER_GPUS.md` never mention the encoder path), so the
  first rebuild with vision is an experiment, not a known-good path.

## [0.4.3] - 2026-10-12

### Changed (learned expert profile lives on the model dataset)

- **`--expert-profile` / `--expert-profile-save` are repointed from
  `/opt/strata/data/expert-profile.bin` (container rootfs) to
  `/srv/ai/models/strata/data/<quant>/expert-profile.bin` (mp0 dataset).**
  setup.sh puts it on the rootfs, so `pct destroy` deletes it; the dataset
  mount survives, so the profile now needs no snapshot at all. One directory
  per quant (`iq3_s`, `iq3_xxs`) because the profile is quant-specific
  routing — until now both configs pointed at the same file and a cutover
  would have cross-contaminated them.
  Placement costs nothing: the file is ~192 KB and 0.1.43 reads it exactly
  once at startup (`src/program/generate.cpp:3309`/`:3492`) into RAM, never
  per token, so it is not on the decode I/O path. Only the 78 GB shard pair
  needs the SSD.
- **Seeding is newest-wins, not snapshot-wins.** The bootstrap still reads
  `pre-rebuild-*/data/expert-profile.bin`, but only copies it into the
  dataset path when that path is empty or the snapshot is newer. A profile
  the engine already learned on the dataset can no longer be shadowed by an
  older pre-rebuild snapshot. The rest of `/opt/strata/data` (draft
  vocabularies, `gguf_fingerprints.json`) is still restored to the rootfs
  where the engine looks for it.

### Added

- **`fit_max_tokens: true` in the model config JSON.** The engine rejects a
  request outright when `prompt + max_tokens > context` — observed live:
  `prompt (114845 tokens) + max tokens (16244) exceeds the context (131072);
  requests are never truncated`. OpenCode reserves the full `limit.output`
  (16384) for the reply, so a long session 400s at ~115k tokens instead of
  using the window. This clamps `max_tokens` to the room left, turning that
  hard failure into a short completion.

## [0.4.2] - 2026-10-12

### Changed (engine pin 0.1.41 -> 0.1.43, ahead of the LXC 115 rebuild)

- **`STRATA_COMMIT` pinned to `7695859aa13a` (v0.1.43, tagged 2026-10-11).**
  Chosen for decode on this board: 0.1.42 is +13–16% decode on one NVIDIA GPU
  (up to +30% where the CPU outruns PCIe — the V100-over-OCuLink case), and
  0.1.43 adds +5–11% on Tesla P100 / RTX 30-series under Linux. Verified the
  Volta path survives: `STRATA_EXPERIMENTAL_SM60` is still in 0.1.43
  (`setup.py::experimental_sm60`, and the `STRATA_EXPERIMENTAL_SM60` CMake
  option guarding `cc < 7.5`), so the CUDA 12.8 sm_70 build is unchanged.
- **Answer-shape caveat:** 0.1.42 enabled two NVIDIA defaults that change
  answers slightly — `STRATA_ROUTE_TAIL_SKIP=7` and the measured PCIe share.
  Accepted deliberately (speed). To get 0.1.41-identical answers, add
  `Environment=STRATA_ROUTE_TAIL_SKIP=0` and
  `Environment=STRATA_PCIE_FRAC_DEFAULT=old` to `strata.service`.
- **`STRATA_VERSION` variable added** so the pin, the `[3/6]` log line and the
  comment block cannot drift apart.

### Added (surviving a `pct destroy`)

- **Expert-profile snapshot/restore.** `/opt/strata` is on the container
  rootfs, so `pct destroy` deletes the profile learned from real traffic
  (94.8% decode hit rate vs ~87% cold, days to climb back). The deploy script
  now tars `/opt/strata/data` onto the model dataset
  (`/srv/ai/models/strata/pre-rebuild-<ts>/`) before destroying, and the
  bootstrap restores the newest snapshot before starting the service.
  Format-safe across versions: the file is `STRP` magic + version 1, and
  0.1.43's `read_expert_profile` (`src/core/expert_cache.cpp`) still reads
  version 1.
- A pre-rebuild snapshot of the running 0.1.41 box was taken by hand at
  `/srv/ai/models/strata/pre-rebuild-20261012/` (configs, unit, logs,
  `data/expert-profile.bin` md5 `e020bae26522a5675ac981e2d7033f0d`).

### Verified (not changed)

- **Phase 1+2 tuning is already in the IaC** and reproduces the live config
  exactly — `configure-hlh-ai-engine-strata.sh` patches `--prefill auto:16384`,
  `--kv-grow`, `--adapt-async 1`, `--expert-profile-save`,
  `--expert-profile-save-every 10`, `--pool-workers 10`, `--lookup-chain 2`,
  `--prompt-cache-tail`, `--conversation-cache-mib 4096` into the setup-written
  config, and writes the tuned unit (`LimitMEMLOCK=infinity`,
  `STRATA_EXPERIMENTAL_SM60=1`, restart budget). A rebuild does not lose them.
- `.done` markers restored on the SSD IQ3_S pair and added for the HDD
  IQ3_XXS pair (they were dropped by the Phase 3 rollback path).

## [0.4.1] - 2026-10-12

### Changed (Phase 3 item 10 verdict — revert to IQ3_S)

- **Model IQ3_XXS -> IQ3_S** (intelligence over speed): XXS benchmarked
  slower (decode 39.0 warm vs 41.8–47.5; prefill 80 vs 367–779 tok/s on
  ~4k prompts) despite more slots / higher hit rate. SSD pair swapped back,
  `strata.service` restored from `bak-iq3_s` (Phase 1+2 flags intact),
  `/health` = `qwen3.8-flash-next-iq3_s` after 580 s cold load. XXS pack
  (`packs/iq3_xxs`, ~43 GB) and HDD shards kept for now.

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
