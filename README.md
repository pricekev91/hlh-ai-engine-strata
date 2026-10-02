# HLH AI Engine — Strata (V100 OCuLink, LXC 115)

This repo provisions `hlh-ai-engine-strata` — the Strata AI engine running
**Qwen3.8-Flash-Next IQ2_XS** on the **Tesla V100 (GV100GL, 32 GB HBM2, compute
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
| Resources | 12 cores, **48 GB RAM** (IQ2_XS fits 48 GB per Strata's own math), 512 MB swap, 64 GB rootfs (`RaidZ1-6TB`) |
| GPU | **Tesla V100 GV100GL 32 GB** (`c5:00.0`, `10de:1df0`, cc 7.0) via OCuLink — single chip, `nvidia0` |
| Host driver | R580 `580.65.06` (last branch supporting Volta) on `6.14.11-9-pve` (6.17+ breaks 550/580 closed DKMS) |
| CUDA | **12.8** (final toolkit with sm_70; CUDA 13 dropped sm_60/sm_70) |
| Engine | **Strata 0.1.32** pinned `c499bd1`, built from source **`-DSTRATA_EXPERIMENTAL_SM60=ON`** (Volta community path, Strata #295/#236) |
| Model | Qwen3.8-Flash-Next **IQ2_XS** — ~35.5 GB of MoE experts in RAM, dense weights on GPU, 128 K context, int8 KV, vision off |
| Model storage | `/srv/ai/models/strata` (host `RaidZ1-6TB/ai/models` → LXC `/srv/ai/models/strata`, same-path bind `mp0`) |
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
  Gen3 x2 link, 8 GT/s).
- IQ2_XS in normal mode needs ~35.5 GB of experts in RAM + ~10 GB beside →
  the 48 GB LXC limit. Low-RAM (resident) mode is the fallback if RAM is
  ever reclaimed for other LXCs (32 GB card holds the hot experts, RAM holds
  the rest).

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
5. `[4/7]` Create LXC 115: privileged, 12 cores, 48 GB RAM, 64 GB rootfs on
   `RaidZ1-6TB`, `mp0 /srv/ai/models`, IP `192.168.1.15/24` gw `.1`, `onboot 1`.
6. `[5/7]` GPU passthrough (same pattern as 111): cgroup allows
   `c 195:*/507:*/508:*/510:*/511:* rwm` + bind mounts of `/dev/nvidia*`
   (`nvidia0`, `nvidiactl`, `nvidia-uvm`, `nvidia-uvm-tools`, `nvidia-modeset`).
7. `[6/7]` Start LXC, push `configure-hlh-ai-engine-strata.sh`, run
   `--bootstrap-inside`:
   - CUDA 12.8 toolkit + driver-branch userspace **apt-pinned to `580.65.06`**
     (exact-match FATAL gate — NVML requires userspace == host kernel driver),
   - Strata 0.1.32 at pinned `c499bd1` → `/opt/strata`,
   - `STRATA_EXPERIMENTAL_SM60=1 ./setup.sh --setup --family qwen --model IQ2_XS
     --context 131072 --kv int8 --vision no --gpu 0 --port 80 --host 0.0.0.0
     --data-dir /srv/ai/models/strata --low-ram auto --no-start --yes`
     (venv + pinned deps, llama.cpp fetch, **engine compile ~10–40 min**,
     **~68 GB model download + pack**, config JSON + run script),
   - `strata.service` (systemd, port 80, `LimitMEMLOCK=infinity` for the
     page-locked expert arena) enabled + started.
8. `[7/7]` Verify `strata.service` active + `/health` (first model load takes
   1–3 minutes, longer with a cold ZFS page cache).

Useful flags:

| Flag | Effect |
|---|---|
| `--yes` | Skip confirmation prompts (existing 115 delete, 111 stop) |
| `--skip-host-driver` | Don't touch the host driver (it's already pinned) |
| `--keep-111` | Don't stop LXC 111 (test-only; Strata and llama.cpp will share the 32 GB VRAM) |
| `--no-bootstrap` | Provision LXC 115 only; run `./configure-hlh-ai-engine-strata.sh` later |

## Deployment Model

| Aspect | hlh-ai-engine-egpu (111) | hlh-ai-engine-strata (115) |
|---|---|---|
| Engine | llama.cpp (CUDA) | Strata (CUDA, MoE) |
| Model | Qwen3.8-27B GGUF | Qwen3.8-Flash-Next IQ2_XS (packed shards) |
| CUDA | 12.8 | 12.8 (sm_70 experimental build) |
| GPU wiring | cgroup + `/dev/nvidia*` bind | identical |
| Host driver | 580.65.06 | identical (shared) |
| Model dir | `/srv/ai/models` (GGUFs) | `/srv/ai/models/strata` (own subfolder, packed) |
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

- Versioning: `major.minor.patch-strata` (e.g. `1.0.0-strata`)
- Change management: PRs + review for code changes; docs can be direct.
- Pinned externals:
  - Strata `c499bd102e7a4135c0de389dcfe38c399759ccc8` (0.1.32) — bump
    deliberately (rebuilds the engine; re-run `setup.sh` in the LXC after).
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
  in `/srv/ai/models/strata` survives (it's on the ZFS mount, not the rootfs),
  so the second run skips the 68 GB download (Strata setup detects existing
  shards).
