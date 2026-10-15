# HLH AI Engine — Strata (V100 OCuLink, LXC 115)

This repo provisions `hlh-ai-engine-strata` — the Strata AI engine running
**Qwen3.8-Flash-Next IQ3_S** on the **Tesla V100 (GV100GL, 32 GB HBM2, compute
capability 7.0 / Volta)** attached to `prox01` via the OCuLink slot (`c5:00.0`),
as privileged **LXC 115** at **`192.168.1.15`**.

It is a standalone sibling of [`hlh-ai-engine-egpu`](../hlh-ai-engine-egpu)
(same host, same GPU, same wiring pattern — two-script bash, no OpenTofu /
Ansible), and **supersedes it on the V100**: at cutover `deploy-hlh-ai-engine-strata.sh`
stops LXC 111 (`hlh-ai-engine-egpu`, llama.cpp, Qwen3.8-27B) and sets it to
`onboot 0`. 111's config stays intact for revert
(`pct set 111 --onboot 1 && pct start 111`).

## Executive Summary

| Item | Value |
|---|---|
| Proxmox host | `prox01.mizertech.org` (192.168.1.10) |
| LXC ID / hostname | `115` / `hlh-ai-engine-strata` |
| IP / FQDN | `192.168.1.15` / `hlh-ai-engine-strata.mizertech.net` |
| OS / type | Ubuntu 24.04 (noble), privileged, `nesting=1,keyctl=1,fuse=1` |
| Resources | 12 cores, **55 GB RAM** (26.7 GiB pinned experts + runtime + mmap page-cache headroom — see RAM sizing), 512 MB swap, 64 GB rootfs (`RaidZ1-6TB`) |
| GPU | **Tesla V100 GV100GL 32 GB** (`c5:00.0`, `10de:1df0`, cc 7.0) via OCuLink — single chip, `nvidia0` |
| Host driver | R580 `580.65.06` (last branch supporting Volta) on `6.14.11-9-pve` (6.17+ breaks 550/580 closed DKMS) |
| CUDA | **12.8** (final toolkit with sm_70; CUDA 13 dropped sm_60/sm_70) |
| Engine | **Strata 0.1.43** pinned `7695859aa13a`, built from source **`-DSTRATA_EXPERIMENTAL_SM60=ON`** (Volta community path, Strata #295/#236) |
| Model | Qwen3.8-Flash-Next **IQ3_S** — low-RAM mode (32 GB card holds the hot experts, RAM the rest), 128 K context, int8 KV, **vision on** (GPU encoder, since 0.5.0) |
| Model shards | `/srv/ssd-models` (host **`rpool/strata-models`** on the **SSD pool** → LXC `/srv/ssd-models`, bind `mp1`) — the 78 GB IQ3_S pair on the RaidZ1-6TB HDD pool was too slow; SSD is fast (validated live 2026-10-09) |
| Model packs | `/srv/ai/models/strata` (host `RaidZ1-6TB/ai/models` → LXC `/srv/ai/models/strata`, same-path bind `mp0`) — packed model, MTP, tokenizer, **`models/mmproj-…-BF16.gguf` (0.9 GB image encoder)** |
| API | **port 80**: web UI + OpenAI `/v1` + Anthropic `/v1/messages` (drop-in replacement for the old `:80` llama.cpp endpoint) |
| Supersedes | LXC 111 `hlh-ai-engine-egpu` (llama.cpp) — stopped + `onboot 0` at cutover, config intact |

## Why Strata / why sm_70 experimental

- Strata is a CUDA-only MoE engine: dense weights in VRAM, expert weights in
  RAM, expert selection in one fused CUDA kernel. Its README documents exactly
  this hardware class ("V100 32 GB + 32–64 GB RAM runs IQ2_XS/IQ3_XXS").
- Upstream requires compute capability ≥ 7.5. The V100 (cc 7.0) works through
  the documented **experimental sm_60/sm_70 path**: `STRATA_EXPERIMENTAL_SM60=1`
  at build time → `-DSTRATA_EXPERIMENTAL_SM60=ON`, **CUDA 12.x required**
  (CUDA 13 dropped sm_70). Community-tested, not upstream-benchmarked:
  expect well under the 50–95 tok/s README numbers (this board also runs on a
  Gen3 x4 link, 8 GT/s).
- IQ3_S runs in **low-RAM (resident) mode**: the 32 GB card holds the hot
  experts + dense + KV, RAM holds the pinned complement (~26.7 GiB) and the
  page cache for the mmap'd expert files. RAM sizing (validated live
  2026-10-10): at 48 GB the CT sits at its cgroup limit and the OS re-reads
  experts from SSD (13M+ major faults); **55 GB** gives the mmap cache more
  headroom while leaving ~6 GiB on the 61 GiB host for PVE, CT 109 and the
  small VM. Do not start 111/112/113 alongside.

## Vision (images)

On by default since **0.5.0** (`--vision gpu`; `--vision cpu` / `--vision no`
override). Before that the engine was built **without** the encoder and every
picture died with `this server was started without the vision encoder` — the
tell was `"images": false` in `/health` and `"input_modalities": ["text"]` in
`/v1/models`.

What `--vision gpu` adds to the bootstrap:

- **Weights**: `mmproj-Qwen3.8-Flash-Next-BF16.gguf` (907,543,008 B, sha256
  `b1a82259…49bd0`) from `ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF` — the
  same 27-layer ViT + projector for every Flash-Next quant. `setup.sh`
  downloads it into `<data-dir>/models` = `/srv/ai/models/strata/models`
  (**mp0, the HDD pool** — `rpool/strata-models` has no room for it, and the
  encoder is read once at start, not per token, so HDD is fine). A copy already
  in `--gguf-dir` is used in place instead; the bootstrap logs which of the
  three paths it took.
- **Binary**: `engine-cuda12/strata-vision` (llama.cpp `mtmd`), built with
  `-DSTRATA_VISION_CUDA=ON` at the **same `CMAKE_CUDA_ARCHITECTURES`** as the
  engine, in the CUDA-12 `build-vision-cuda12` folder — i.e. sm_70 code on the
  same 12.8 toolkit. It is installed **next to the engine**, and on this card
  the engine lives in `engine-cuda12/`, not `engine/` (`engine_dir()` in
  `setup.py` picks that folder for toolkit 12). ~10–20 min extra compile.
- **Cost**: the encoder holds ~1.2 GB of the 32 GB card at 1024 image tokens,
  so the expert cache gets ~1,000 fewer slots. Upstream measures 2–8 % slower
  text; here the expert hit rate (94–95 %) *is* the decode lever, so check
  `strata-iq3_s.log` after the rebuild.
- **Escape hatches**: `--vision-tokens N` shrinks what one picture becomes
  (setup default 1024 on gpu) if the encoder does not fit beside the 128 K KV;
  `--vision cpu` keeps every expert slot and pays ~3 s/picture at 300 tokens on
  cores the `--pool-workers 10` expert pool also wants; `vram_elastic: true` +
  `vision.elastic: true` loads the encoder on demand and drops it after
  `elastic_idle_s` (NVIDIA-only; upstream measured it on an AMD card only).

**Unverified on Volta**: upstream documents vision for Turing+ and has no sm_70
report (`NVIDIA_V100.md` / `OLDER_GPUS.md` never mention the encoder path).
After a rebuild confirm both halves:

```sh
curl -s http://192.168.1.15/health  | grep -o '"images": *[a-z]*'          # want true
curl -s http://192.168.1.15/v1/models | grep -o '"input_modalities":[^]]*]' # want ["text","image"]
# then one real picture through /v1/chat/completions (an image_url part)
```

A silent text-only fallback is what bit this board before, so the bootstrap now
fails when no `strata-vision` helper is found (the config's `vision.exe`, else
`engine-cuda12/strata-vision`, else `engine/strata-vision`) or when the config's
`vision.mmproj` is not a file, and it warns when `/health` still reports
`images: false` after start.

## Quick Start

```sh
cd git/hlh-ai-engine-strata
./deploy-hlh-ai-engine-strata.sh --yes
```

What that does, in order:

1. `[0/7]` Host: verify R580 `580.65.06` + V100 (`nvidia-smi -L`, 32 GB),
   ensure `nvidia_uvm` persistence + UVM device nodes (installs them if absent;
   full `.run --dkms` path included for greenfield hosts).
2. `[1/7]` Ensure the Ubuntu 24.04 LXC template is in `local` storage (`pveam update && pveam download local ...` if missing; verified via `pveam list local`).
3. `[2/7]` Remove stale LXC 115 leftovers (`115.conf.bak.*`); confirm-delete a
   live 115 on redeploy (its `/srv/ai/models/strata` data survives).
4. `[3/7]` **Free the V100**: stop LXC 111 (`hlh-ai-engine-egpu`) and set it to
   `onboot 0` (config kept; revert = `pct set 111 --onboot 1 && pct start 111`).
5. `[4/7]` Ensure the SSD dataset `rpool/strata-models` (mountpoint
   `/strata-models`) and seed the IQ3_S shard pair onto it (idempotent; copies
   from `/srv/ai/models` if not already on SSD). Then create LXC 115:
   privileged, 12 cores, 55 GB RAM, 64 GB rootfs on `RaidZ1-6TB`,
   `mp0 /srv/ai/models` + `mp1 /strata-models → /srv/ssd-models`,
   IP `192.168.1.15/24` gw `.1`, `onboot 1`.
6. `[5/7]` GPU passthrough (same pattern as 111): cgroup allows
   `c 195:*/507:*/508:*/510:*/511:* rwm` + bind mounts of `/dev/nvidia*`
   (`nvidia0`, `nvidiactl`, `nvidia-uvm`, `nvidia-uvm-tools`, `nvidia-modeset`).
7. `[6/7]` Start LXC, push `configure-hlh-ai-engine-strata.sh`, run
   `--bootstrap-inside`:
   - CUDA 12.8 toolkit + driver-branch userspace **apt-pinned to `580.65.06`**
     (exact-match FATAL gate — NVML requires userspace == host kernel driver),
   - Strata 0.1.43 at pinned `7695859aa13a` → `/opt/strata`,
   - `STRATA_EXPERIMENTAL_SM60=1 ./setup.sh --setup --family qwen --model IQ3_S
     --context 131072 --kv k8v4 --vision gpu --gpu 0 --port 80 --host 0.0.0.0
     --data-dir /srv/ai/models/strata --gguf-dir /srv/ssd-models --low-ram auto
     --no-start --yes`
     (venv + pinned deps, llama.cpp fetch, **engine compile ~10–40 min**,
     **pack from local SSD shards — no model download**; ~5 GB MTP draft and the
     0.9 GB mmproj image encoder fetched, **`strata-vision` compile ~10–20 min**),
   - `strata.service` (systemd, port 80, `LimitMEMLOCK=infinity` for the
     page-locked expert arena) enabled + started.
8. `[7/7]` Verify `strata.service` active + `/health` (first model load takes
   1–3 minutes, longer with a cold ZFS page cache) + that `/health` reports
   `"images": true` when `--vision` is on.

Useful flags:

| Flag | Effect |
|---|---|
| `--yes` | Skip confirmation prompts (existing 115 delete, 111 stop) |
| `--skip-host-driver` | Don't touch the host driver (it's already pinned) |
| `--keep-111` | Don't stop LXC 111 (test-only; Strata and llama.cpp will share the 32 GB VRAM) |
| `--no-bootstrap` | Provision LXC 115 only; run `./configure-hlh-ai-engine-strata.sh` later |
| `--model M` | `Q2_0` \| `IQ2_XS` \| `IQ3_XXS` \| `IQ3_S` (default) — seeds the SSD dataset **and** is forwarded to the bootstrap (before 0.5.0 the bootstrap silently re-packed the default quant) |
| `--vision V` | `gpu` (default) \| `cpu` \| `no` — forwarded to the bootstrap as `--vision` (see [Vision (images)](#vision-images)) |
| `--vision-tokens N` | Max tokens one picture becomes (setup default 1024 on gpu) — lower it if the encoder does not fit beside the 128 K KV |

## Deployment Model

| Aspect | hlh-ai-engine-egpu (111) | hlh-ai-engine-strata (115) |
|---|---|---|
| Engine | llama.cpp (CUDA) | Strata (CUDA, MoE) |
| Model | Qwen3.8-27B GGUF | Qwen3.8-Flash-Next IQ2_XS (packed shards) |
| CUDA | 12.8 | 12.8 (sm_70 experimental build) |
| GPU wiring | cgroup + `/dev/nvidia*` bind | identical |
| Host driver | 580.65.06 | identical (shared) |
| Model dir | `/srv/ai/models` (GGUFs) | shards `/srv/ssd-models` (SSD `mp1`), packs `/srv/ai/models/strata` (`mp0`) |
| Port | 80 | 80 (drop-in after cutover) |
| Status | **stopped, `onboot 0` at cutover** | active |

## Runtime Contract

| Endpoint | Purpose |
|---|---|
| `http://hlh-ai-engine-strata.mizertech.net:80` | Strata web UI (chat) |
| `http://hlh-ai-engine-strata.mizertech.net:80/v1` | OpenAI-compatible API (`/chat/completions`, `/v1/models`) |
| `http://hlh-ai-engine-strata.mizertech.net:80/v1/messages` | Anthropic-compatible API |
| `http://hlh-ai-engine-strata.mizertech.net:80/health` | health (model load status) |

API key: none by default — same as the old llama.cpp setup (LAN-only trust).
Pass `--api-key` to Strata later if that changes.

## Repository Layout

```
hlh-ai-engine-strata/
├── README.md
├── CHANGELOG.md
├── 00_BACKLOG.md
├── 10_ACTIVE.md
├── 90_DONE.md
├── .gitignore
├── deploy-hlh-ai-engine-strata.sh     # host-side: LXC 115 + V100 wiring + 111 cutover
└── configure-hlh-ai-engine-strata.sh  # bootstrap: CUDA 12.8 + Strata sm_70 build + IQ2_XS + systemd
```

## Governance

- Versioning: `major.minor.patch` — **v0.1.0** is the working baseline
  (2026-10-11, decode 34 tok/s measured live; tuning plan in
  [3phase-tunning.md](3phase-tunning.md)). The `1.0.x-strata` labels in
  git history predate the reset.
- Change management: PRs + review for code changes; docs can be direct.
- Pinned externals:
  - Strata `7695859aa13afb248bdb4d36f9b2e95707db079d` (0.1.43) — bump
    deliberately (rebuilds the engine; re-run `setup.sh` in the LXC after).
    The IaC pins this; the live LXC 115 still runs 0.1.41 until the rebuild
    (`10_ACTIVE.md`).
  - CUDA `12.8.0-1` (final sm_70 toolkit) + userspace `580.65.06` (last Volta driver).
    Do **not** move to CUDA 13.x (drops sm_70) or driver 590+ (drops Volta).
- Scope: this repo owns LXC 115 lifecycle, Strata install, and the 111→115
  V100 cutover. Host driver lifecycle is shared with `hlh-ai-engine-egpu`
  (same .run --dkms path, same pin). `hlh-iac` (Terraform + Ansible) is the
  separate, broader homelab IAC repo and does **not** cover this LXC.

## Cutover & Revert

- **Cutover** (already done by deploy `[3/7]`): `pct stop 111 && pct set 111 --onboot 0`.
  115 starts at boot (`onboot 1`), serves `:80`.
- **Revert** (if Strata must go): `pct set 111 --onboot 1 && pct start 111`
  (llama.cpp + Qwen3.8-27B comes back on `:80` at `192.168.1.11`); stop 115
  with `pct set 115 --onboot 0 && pct stop 115`. Both LXCs can hold the GPU
  wiring simultaneously — VRAM (32 GB) is the shared resource, so don't run
  both loaded at once.
- **Rebuild 115**: re-run `./deploy-hlh-ai-engine-strata.sh --yes`. Model data
  survives: packs in `/srv/ai/models/strata` (ZFS mount) and the IQ3_S shard
  pair in `rpool/strata-models` (SSD). `[4/7]` re-seeds the SSD dataset from
  `/srv/ai/models` if the shards are missing, and the bootstrap packs from the
  local SSD shards — no model download.
