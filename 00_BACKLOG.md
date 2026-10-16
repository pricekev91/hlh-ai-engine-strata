# BACKLOG

Items for future implementation. These are human-entered ideas not yet reflected
in the codebase.

## Strata Engine (sm_70 experimental)

- Track Strata sm_70 community fixes upstream (#295, #236) — re-bump the pinned
  commit when a real Volta fix lands; rebuild is ~10–40 min and model data
  survives.
- Run Strata calibration once (`./setup.sh --calibrate` inside the LXC, 5–10
  min) to tune engine settings for this board — setup skipped it with `--yes`.
- Add a `strata-switch-model.sh` helper (Q2_0 / IQ3_XXS / IQ3_S / Coder on this
  hardware) — Strata's own `setup.sh --model <X>` is the primitive; the script
  would wrap it + restart `strata.service`.
- Low-RAM (resident) mode tuning: if RAM is ever reclaimed for other LXCs,
  re-run setup with `--low-ram on` (32 GB card holds hot experts, RAM the rest).
- API key: Strata supports `--api-key`; enable if the :80 endpoint ever leaves
  the trusted LAN.
- **Vision on Volta works** (measured 2026-10-16 on the 0.5.0 rebuild —
  upstream documents vision for Turing+ and never mentions the encoder in
  `NVIDIA_V100.md` / `OLDER_GPUS.md`, so this is the first sm_70 report).
  `strata-vision` starts and `warms up at 1024 image tokens in 1.5 s`;
  `/health` → `images: true`. Cost: expert cache **11,920 slots / 22.55 GiB**
  vs the 12,598-slot text-only baseline = **678 slots (−5.4 %)** for the
  encoder + `--vram-reserve-mib 700`; card at 32,282/32,768 MiB. Hit rate
  91.8–94.8 % (mostly 92–93 %) vs 94–95 %; decode 39.1–54.7 tok/s samples.
  Inside the ±5 % band → `--vision gpu` stays the default. Escape hatches if it
  ever gets worse: `--vision-tokens 512` → `--vision cpu` → the on-demand
  encoder (`vram_elastic: true` + `vision.elastic: true`, `elastic_mib` 2048 /
  `elastic_idle_s` 120 — NVIDIA-only, upstream measured it on an AMD card only).
  **Worth an upstream report** (works on cc 7.0, with these numbers).
- mmproj is re-downloaded (0.9 GB from HF) on every greenfield bootstrap; it
  lives in `/srv/ai/models/strata/models` (mp0) so a rebuild that keeps the
  dataset does not re-fetch it. Only seed it onto `rpool/strata-models` if that
  pool ever has room (9.45 G avail today, and the shard pair owns it) — a
  rebuild on a box without HF egress needs the file pre-seeded instead.

## GPU / Performance (V100 GV100GL 32GB)

- Measure and log real pp/decode tok/s for IQ2_XS (baseline: none — cc 7.0 is
  not in Strata's benchmark table).
- Track OCuLink PCIe link (Gen3 x2 @ 8 GT/s today): a proper x4 (or higher-gen)
  riser would help prompt processing; NOT hot-pluggable while the LXC runs.
- Evaluate IQ3_XXS/IQ3_S as quality upgrades (47/54.8 GB RAM+VRAM — IQ3_XXS
  fits 48 GB normal mode; IQ3_S needs 64 GB).

## LXC Lifecycle (115)

- LXC 111 retirement decision after cutover proves out (keep onboot 0 as
  revert fallback, or destroy + free the slot).
- LXC snapshot before model upgrades (Strata data is on the ZFS mount; rootfs
  holds the engine build).
- Optional: `LimitCPU`/`LimitAS` hardening once usage is characterized.
- SSH keys: since 0.5.3 the deploy script sets the CT root **password** and
  enables root password login right after `pct start`, so the direct
  `ssh root@192.168.1.15` path works on a greenfield rebuild with no manual
  step — but it is still password-only, and a password is the weaker of the two
  options on a LAN-reachable root shell. A `--ssh-key FILE` on the deploy script,
  pushed into `/root/.ssh/authorized_keys` at the same point, would let
  `PermitRootLogin` go back to `prohibit-password` and make
  `--root-password` optional instead of load-bearing.
- `allowed_hosts` is now IaC-managed (0.5.2, default
  `hlh-ai-engine-strata.mizertech.net`). Two follow-ups: apply it to the live CT
  (needs the ~6 min strata restart, command in 10_ACTIVE), and revisit the scope
  if a reverse proxy or a second name ever fronts the endpoint —
  `--allowed-hosts .mizertech.net` widens it to the domain, `*` switches the
  guard off entirely (defensible only while the box stays LAN-only).
  `cors_origins` is the matching knob if a browser origin ever needs it.

## Ops

- Add strata.service + V100 health to homelab monitoring (health endpoint +
  `nvidia-smi` parse).
- Document the 111↔115 revert as a runbook in home-lab-architecture.md known
  issues / notes (cross-repo pointer).
