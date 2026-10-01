# TODO

Active items in progress. These are the current focus areas.

## Active (V100 LXC 115 Strata sm_70)

- [ ] **Cutover run**: `./deploy-hlh-ai-engine-strata.sh --yes` — not yet
  executed. Deliberately deferred until an intentional window: it stops LXC 111
  (hlh-ai-engine-egpu), which currently serves inference, and the bootstrap is
  long (engine compile ~10–40 min + ~68 GB download + pack).
- [ ] After cutover: verify `nvidia-smi -L` in 115, `systemctl status strata`,
  `/health`, a real chat + OpenAI `/v1` round-trip; measure actual tok/s
  (expect well under README 50–95 — cc 7.0 experimental, Gen3 x2 link) and log
  the number in 90_DONE.
- [ ] Confirm host reboots cleanly: 115 starts at boot (onboot 1), 111 stays
  stopped (onboot 0), V100 UVM devices present before guests.

## This Week

- [ ] Watch first-day stability (strata.service restarts, ZFS page-cache cold
  loads, any sm_70 kernel issues in `dmesg`).
- [ ] Decide 111's fate: keep as revert fallback (onboot 0) or retire the
  LXC entirely once Strata proves itself.
