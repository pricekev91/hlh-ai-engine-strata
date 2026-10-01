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

## Ops

- Add strata.service + V100 health to homelab monitoring (health endpoint +
  `nvidia-smi` parse).
- Document the 111↔115 revert as a runbook in home-lab-architecture.md known
  issues / notes (cross-repo pointer).
