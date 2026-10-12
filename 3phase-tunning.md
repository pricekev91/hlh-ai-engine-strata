# 3-Phase Tuning Plan — Strata Engine (LXC 115)

Audited 2026-10-11 against the live engine (0.1.41) and `/opt/strata/strata-iq3_s.log`.
Goal: faster decode and shorter prefill stalls. Nothing here is applied yet — each
change is one flag in `strata-iq3_s.json` args (or `configure-hlh-ai-engine-strata.sh`
for permanence). Restart `strata.service` after each change; benchmark before/after.

## Baseline (measured 2026-10-11)

| Metric | Current | Notes |
|---|---|---|
| Decode speed | 26–43 tok/s (bursts 80–100) | thinking tokens |
| Prefill (fresh tokens) | 48–106 tok/s | 2–4k fresh tokens = 20–50 s stall — biggest UX pain |
| Prompt cache reuse | 90–98% | working well |
| MTP spec acceptance | 64–82% (`--spec 4`) | healthy |
| Expert cache hit rate | 94–95.5% | 12,418 VRAM slots (23.56 GiB) |
| RAM↔VRAM expert swaps | ~5,000 blobs/request | each blocks a verify window today |
| VRAM free after load | 440 MiB of 32 GB | KV @128K int8 is the hog |
| PCIe link | 3.3 GB/s (8GT/s x4) | OCuLink max; README "Gen3 x2" note is stale |
| RAM | 26.68 GiB page-locked, 0 major faults | 48→57 GB bump fixed the thrash |
| GPU clocks/power | 1260 MHz app clock, 250 W cap (max 1380 MHz) | SXM4 board set to 250 W |
| Engine | 0.1.41 running | README pins 0.1.32 — docs drift |

## Why it's slow

The IQ3_S experts (50.3 GB) don't fit in 32 GB VRAM, so ~5% of routed expert
lookups per token miss the VRAM cache and are served from RAM or swapped over the
3.3 GB/s link. During prefill every fresh token routes 10 experts x 48 layers,
and the 8192-token chunk ring holds only 96 expert slots at a time — streaming
dominates. The 128K context is paid for but never used (requests top out ~30k
tokens): int8 KV reserves VRAM for all 131,072 cells, starving the expert cache.

## Phase 1 — VRAM reclaim + prefill (biggest wins, config only)

**STATUS: APPLIED 2026-10-11 (live ad-hoc + IaC, tagged v0.2.0).** Results below.

Edit args in `/opt/strata/strata-iq3_s.json` (and mirror into
`configure-hlh-ai-engine-strata.sh` SETUP_ARGS so redeploys keep them):

1. `--kv k8v4` — INT8 K + rotated Q4_0 V, 816 vs 1,056 B/cell (~23% KV cut).
   Alternative if quality A/B favors it: `--kv q4_0` (half of int8).
2. `--kv-grow` — KV takes VRAM only for cells requests actually reach
   (typical ~30k vs 131k cap). Frees ~3–4 GB VRAM -> +1,500–2,000 expert slots.
3. `--prefill auto:16384` — bigger prompt chunks amortize expert streaming
   over more rows. Needs the VRAM headroom from 1–2. Expect 2–4x prefill.
4. `--adapt-async 1` — the ~5,000 RAM↔VRAM swaps/request currently block verify
   windows; this advances them between windows (not bit-exact run to run).
5. `--expert-profile-save /opt/strata/data/expert-profile.bin
   --expert-profile-save-every 10` — let the profile learn actual routing
   (OpenCode traffic) instead of the generic 24,576-pair file; also cuts
   cold-start pre-fill time.

Verify after each restart: `expert cache <N> slots` line in the log grows,
`prompt chunk auto:` shows the bigger chunk, hit rate trends up.

Benchmark: replay 2–3 real OpenCode sessions; record `prompt ... read in ...
tok/s` and `generated ... tok/s` lines + `drafts accepted` ratio.

### Phase 1 applied — verification (2026-10-11, live LXC 115)

| Flag | Honored? | Evidence |
|---|---|---|
| `--kv k8v4` | ✅ | expert cache auto: 24.82 GiB free (was 24.47) -> **12,598 slots** (was 12,418) |
| `--kv-grow` | ❌ auto-off | engine: "--kv-grow is off (one GPU, a profile, the whole K/V in VRAM, every expert in RAM...)" — engine keeps full KV in VRAM in this config; flag is harmless, engine decides |
| `--prefill auto:16384` | ✅ | "prompt chunk auto: 16384 tokens"; prompt path borrows 3,370 slots / 6.41 GiB (was 1,795 / 3.40) |
| `--adapt-async 1` | ✅ | "adaptive tier asynchronous: up to 96 swaps per round, a round every 4 windows" |
| `--expert-profile-save` | ✅ | "expert profile saved to /opt/strata/data/expert-profile.bin (periodic)" |

Measured after restart:

- **Prefill: 367–779 tok/s** (was 48–106) — **3.5–7x faster**; an 80,505-token
  prompt read in 103 s, a 3,425-token prompt in 9.3 s.
- **Decode: 43.5 tok/s warm** (baseline typical 34); 27.2 on the first
  cold request.
- Expert cache hit rate 90.3–90.6% (was 94–95.5%) — slightly lower while the
  learned profile re-adapts; watch over the next days.
- RAM: pinned complement grew 26.68 -> 29.33 GiB (bigger lendable set);
  **0 major faults**, CT 51.6/57 GB, ~17 GB page cache. VRAM still full
  (432 MiB free) — kv-grow would have helped but the engine declined it.
- Rollback: `/opt/strata/strata-iq3_s.json.bak-0.1.0` + `systemctl restart strata`.

## Phase 2 — CPU pool + speculation tuning

6. `--pool-workers 10` — pool currently runs 8 workers + host thread on the
   12-core allocation; more workers serve cache misses faster.
7. `--lookup-chain 2` — suffix drafts already hit 6/6 on repetitive code
   output; chaining grows verify windows to 8 where repeats are likely.
8. `--prompt-cache-tail` — one extra checkpoint near the prompt end; shaves
   the fresh-read tail further.
9. `--conversation-cache-mib 8192` (tune to headroom) — parked-conversation
   RAM cache is off by default; speeds session restore with many OpenCode
   sessions (~23 GB host headroom available).

## Phase 3 — model + hardware

10. A/B test **IQ3_XXS** (42.9 GB experts vs 50.3 GB IQ3_S): ~7 GB less
    streaming for modest quality cost — potentially the single biggest decode
    win. Re-pack from shards with `setup.sh --model IQ3_XXS`.
11. CPU contention: LXC 109 (hlh-docker) shares host cores; Jellyfin
    transcodes / container churn steal pool-worker cycles during inference.
    Consider core pinning or scheduling.
12. Power cap: SXM4 V100 is a 300 W part, adapter caps at 250 W. Test
    `nvidia-smi -pl 300` (host, as root) — if accepted, app clock rises from
    1260 toward 1380 MHz. Revert with `nvidia-smi -pl 250` if unstable.
13. Docs hygiene: README says 0.1.32 / Gen3 x2; reality is 0.1.41 / x4.

## Expected combined effect

Decode: 26–43 -> ~40–60 tok/s. Prefill stalls: ~3x shorter. Cold start:
shorter with a learned profile.

## Rollback

All Phase 1–2 changes are flags in `strata-iq3_s.json`; restore the previous
args line and `systemctl restart strata`. Model data untouched. Revert of the
whole engine to llama.cpp: `pct set 111 --onboot 1 && pct start 111` (see
README Cutover & Revert).
