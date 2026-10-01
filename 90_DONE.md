# DONE

This is what is already implemented and verified in this repository.

## LXC Deployment (LXC 115)

- Standalone bash IAC (no OpenTofu/Ansible), sibling of `hlh-ai-engine-egpu`:
  `deploy-hlh-ai-engine-strata.sh` (host) + `configure-hlh-ai-engine-strata.sh`
  (bootstrap).
- LXC 115 `hlh-ai-engine-strata` privileged on `prox01` (192.168.1.10), Ubuntu
  24.04 noble, 12 cores, 48 GB RAM, 512 MB swap, 64 GB rootfs on `RaidZ1-6TB`,
  `nesting=1,keyctl=1,fuse=1`, `onboot 1`, static IP `192.168.1.15/24` gw `.1`
  on `vmbr0`.
- Model storage same path host and CT: `RaidZ1-6TB/ai/models` → `/srv/ai/models`
  via `mp0`; Strata data in its own `/srv/ai/models/strata` subfolder (packed
  shards, ~68 GB IQ2_XS + pack), survives LXC rebuilds.

## V100 CUDA Passthrough (sm_70 experimental)

- Host driver pinned R580 `580.65.06` (last branch for Volta) on
  `6.14.11-9-pve` (6.17+ breaks 550/580 closed DKMS) — same pin as
  `hlh-ai-engine-egpu`; deploy verifies + installs UVM persistence
  (`/etc/modules-load.d/nvidia.conf` + `nvidia-uvm-devices.service` Before
  `pve-guests` with dynamic UVM major) and device nodes.
- LXC passthrough via cgroup + bind-mount (no `hostpci`, Proxmox 9.x
  compatible, identical to 111): `c 195:*/507:*/508:*/510:*/511:* rwm` +
  `/dev/nvidia{0,ctl,uvm,uvm-tools,modeset}` bind mounts.
- CUDA **12.8** toolkit in LXC (final sm_70 support; CUDA 13 dropped sm_70),
  userspace 580.65.06 apt-pinned with exact-match FATAL gate (NVML requires
  userspace == host kernel driver).
- Strata 0.1.32 pinned `c499bd1`, engine built from source
  **`-DSTRATA_EXPERIMENTAL_SM60=ON`** (Volta sm_70 community path) — no
  pre-built binary exists for cc 7.0.

## Model + Service

- Qwen3.8-Flash-Next **IQ2_XS**, 128 K context (required), int8 KV, vision
  off, GPU 0, port 80, host 0.0.0.0 — web UI + OpenAI `/v1` + Anthropic
  `/v1/messages`, drop-in for the old llama.cpp :80 endpoint.
- systemd `strata.service` (WorkingDirectory /opt/strata,
  `LimitMEMLOCK=infinity` for the page-locked expert arena, CUDA PATH +
  LD_LIBRARY_PATH, Restart=on-failure), enabled at boot.
- **V100 cutover**: deploy stops LXC 111 (hlh-ai-engine-egpu) + `onboot 0`,
  config kept intact for revert (`pct set 111 --onboot 1 && pct start 111`).
