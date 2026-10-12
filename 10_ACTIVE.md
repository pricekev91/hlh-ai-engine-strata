# TODO

Active items in progress. These are the current focus areas.

## Active (V100 LXC 115 Strata sm_70) — Phase 3: IQ3_XXS cutover

- [ ] **IQ3_XXS cutover** — run the §3.3 runbook in `3phase-tunning.md`
  (scheduled window: 2026-10-12 morning). The IQ3_XXS shard pair downloads on
  prox01 into `/srv/ai/models/IQ3_XXS/` (started 00:01 EDT, 75.84 GB, ~87% done
  at 00:27, ETA ~00:31). Sequence: stop `strata.service` -> delete the IQ3_S
  pair from `/strata-models` -> rsync IQ3_XXS onto it -> `setup.sh --model
  IQ3_XXS --gguf-dir /srv/ssd-models` -> carry the Phase 1+2 flags into
  `strata-iq3_xxs.json` -> restart. **Expect 15–25 min of downtime.**
- [ ] Hard constraint (do not skip): `rpool` is the host's only SSD (128 GB
  NVMe, boot pool) with **9.45G avail** and `rpool/strata-models` already at
  77.9G. The IQ3_S and IQ3_XXS pairs **cannot coexist on the SSD** — the old
  pair must go before the new one lands. `Raid0-2TB` looks free (1.81T) but is
  two spinning HDDs; useless for shards. Keep `packs/iq3_s` (49G) and the HDD
  copies of the IQ3_S shards for rollback.
- [ ] Fix before cutover (`3phase-tunning.md` §3.4): the deploy script hardcodes
  `GGUF_STEM="...IQ3_S"` so it will not seed IQ3_XXS, and it has no free-space
  gate before a 70 GiB copy. Also `LXC_MEMORY=56320` in the script vs **58320
  live** on CT 115 — reconcile before any `pct create` re-run.
- [ ] A/B IQ3_XXS vs IQ3_S on the same 2–3 OpenCode session replay; log the
  numbers in `90_DONE.md`. Reference to beat: decode 41.8–47.5 tok/s, expert
  hit rate 89.7%, 12,598 slots, 29.33 GiB pinned RAM.

## This Week

- [ ] Watch stability (strata.service restarts, ZFS page-cache cold loads,
  any sm_70 kernel issues in `dmesg`).
- [ ] Expert profile re-adapt: hit rate sits at 89.7% vs the 94–95.5% baseline
  after Phase 1/2 — confirm it climbs back over the next days.
- [ ] Decide 111's fate: keep as revert fallback (onboot 0) or retire the
  LXC entirely once Strata proves itself.

## Superseded (kept for revert context)

- [x] **Cutover run** (`./deploy-hlh-ai-engine-strata.sh --yes`) — executed.
  LXC 115 runs Strata at 192.168.1.15 (onboot 1); LXC 111 (hlh-ai-engine-egpu,
  llama.cpp) is stopped with onboot 0 as the revert path.
- [x] Post-cutover verify: `strata.service` active, `/health` ok
  (`qwen3.8-flash-next-iq3_s`, loaded, 131072 ctx), chat + OpenAI `/v1`
  round-trips working. Measured decode 34 -> 43.5 -> 41.8–47.5 tok/s across
  Phase 1/2 (see CHANGELOG 0.1.0–0.3.0). README's 50–95 tok/s remains
  optimistic for cc 7.0 + Gen3 x4 OCuLink.
