# TODO

Active items in progress. These are the current focus areas.

## Active (V100 LXC 115 Strata sm_70) — rebuild on Strata 0.1.43

- [ ] **Nuke and rebuild LXC 115 on Strata 0.1.43** — IaC is ready (CHANGELOG
  0.4.2 + 0.5.0). Run on prox01 from the repo checkout:
  `./deploy-hlh-ai-engine-strata.sh --skip-host-driver --yes`
  (host driver 580.65.06 is already installed and working, so skip that step).
  Expect ~55–110 min offline: CUDA 12.8 install + engine compile 10–40 min +
  **image encoder: mmproj 0.9 GB download + `strata-vision` compile 10–20 min
  (new in 0.5.0, `--vision gpu` is now the default)** + pack from the local SSD
  shards + cold model load.
  What the IaC now handles by itself: 0.1.43 pin, Phase 1+2 tuning flags, the
  tuned `strata.service`, and the learned expert profile — which now lives on
  the model dataset (`/srv/ai/models/strata/data/iq3_s/expert-profile.bin`)
  so it survives `pct destroy` without the snapshot path (CHANGELOG 0.4.3).
  Verify after: `pct exec 115 -- systemctl is-active strata`,
  `curl -s localhost/health` (model `qwen3.8-flash-next-iq3_s`),
  **`curl -s localhost/health | grep -o '"images": *[a-z]*'` = `true`** and one
  real picture through `/v1/chat/completions` (CHANGELOG 0.5.0 — **no upstream
  sm_70 vision report exists**, so this is the first measurement),
  `ls -l /srv/ai/models/strata/data/iq3_s/expert-profile.bin` (non-zero, and
  growing every 10 min), and in `/opt/strata/strata-iq3_s.log` that the
  expert cache starts near **12,598 slots** with hit rate **~94–95%** (a
  ~87% start means the profile did not load). Expect the encoder to take ~1.2 GB
  of the card, i.e. **~1,000 fewer slots** than the text-only baseline — if the
  hit rate or decode drops more than ~5%, re-run with `--vision-tokens 512` or
  `--vision cpu` (README "Vision (images)").
  Rollback if 0.1.43 misbehaves: `STRATA_COMMIT=fb58e0dbc8399662c0e47c76578c6e878b14f6cf ./deploy-hlh-ai-engine-strata.sh --skip-host-driver --yes`
  Rollback if vision breaks the text path: `./deploy-hlh-ai-engine-strata.sh --skip-host-driver --vision no --yes`
- [x] Engine pin bumped 0.1.41 -> **0.1.43** (`7695859aa13a`) in
  `configure-hlh-ai-engine-strata.sh`. Volta sm_70 path confirmed still present
  in 0.1.43. Note `STRATA_ROUTE_TAIL_SKIP=7` is now on by default and changes
  answers slightly — see CHANGELOG 0.4.2 for how to turn it off.
- [x] Pre-rebuild rescue: `/opt/strata` configs, unit, logs and
  `data/expert-profile.bin` copied to
  `/srv/ai/models/strata/pre-rebuild-20261012/` (survives `pct destroy`).

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
- [x] A/B verdict 2026-10-12: **reverted to IQ3_S** (intelligence over speed).
  IQ3_XXS measured slower — decode 39.0 tok/s warm vs 41.8–47.5, prefill
  80 tok/s on a 4.6k prompt vs 367–779 — despite 15,658 slots and 96.8–97.4%
  hit rate; the smaller quant's CPU dequant cost outweighs its PCIe savings
  on 12 cores. Rollback ~15 min (SSD re-seed + cold load 580 s); service
  restored from `strata.service.bak-iq3_s`, XXS config/unit kept as
  `strata-iq3_xxs.json(.bak-base)` / `strata.service.bak-iq3_xxs`.

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
