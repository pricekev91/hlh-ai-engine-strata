# TODO

Active items in progress. These are the current focus areas.

## Active (V100 LXC 115 Strata sm_70) — Phase 3: IQ3_XXS cutover

- [x] **IQ3_XXS cutover** — DONE 2026-10-12 ~00:53 EDT (runbook `3phase-tunning.md`
  §3.3 with two corrections: `--family qwen` not `qwen3.8-flash-next`, `--gpu 0`
  not `cuda`). Downtime ~25 min (stop 00:28, health OK 00:53; rsync 10.4 min +
  pack ~2 min + load ~160 s). `/health` = `qwen3.8-flash-next-iq3_xxs`, chat +
  `/v1` round-trip OK.
- [x] IQ3_XXS shard pair downloaded to `/srv/ai/models/IQ3_XXS/` on prox01
  (28.5 min, ~44 MB/s; 47,039,860,096 + 28,800,138,432 B verified).
- [x] Setup `--low-ram auto` chose NORMAL mode for IQ3_XXS on 57 GB RAM
  (42.9 experts + 10 headroom = 52.9 < 57, so no `--resident-experts` flag —
  the runbook's resident-mode expectation was wrong). Consequences in
  `strata-iq3_xxs.log`: `--adapt-async 1` auto-off (needs resident mode),
  `--kv-grow` HONORED (elastic KV: 16,384 of 131,072 cells in VRAM),
  prefill ring 384 slots. First boot: **15,658 expert slots** (was 12,598),
  cold 58-token probe 29.6 tok/s decode / 86.9% hit rate.
- [ ] Hard constraint (do not skip): `rpool` is the host's only SSD (128 GB
  NVMe, boot pool) with **9.45G avail** and `rpool/strata-models` already at
  77.9G. The IQ3_S and IQ3_XXS pairs **cannot coexist on the SSD** — the old
  pair must go before the new one lands. `Raid0-2TB` looks free (1.81T) but is
  two spinning HDDs; useless for shards. Keep `packs/iq3_s` (49G) and the HDD
  copies of the IQ3_S shards for rollback.
- [x] Fix before cutover (`3phase-tunning.md` §3.4) — DONE 2026-10-12:
  `GGUF_STEM` parameterized via `--model`/`MODEL_QUANT` (Q2_0|IQ2_XS|IQ3_XXS|IQ3_S),
  `avail >= pair + 8G` capacity gate added, `LXC_MEMORY` 56320 -> **58320** (live).
- [ ] A/B IQ3_XXS vs IQ3_S on the same 2–3 OpenCode session replay; log the
  numbers in `90_DONE.md`. Reference to beat: decode 41.8–47.5 tok/s, expert
  hit rate 89.7%, 12,598 slots, 29.33 GiB pinned RAM. IQ3_XXS first-boot
  reference (cold, 2026-10-12): 15,658 slots, elastic KV on, adapt-async off,
  29.6 tok/s / 86.9% on a 58-token probe — expect both to climb warm.

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
