# 3-Phase Tuning Plan — Strata Engine (LXC 115)

Audited 2026-10-11 against the live engine (0.1.41) and `/opt/strata/strata-iq3_s.log`.
Phase 3 refreshed 2026-10-12 against the live host (prox01) while the IQ3_XXS
shard pair downloads — see §3.1–3.4 for the live state, the SSD capacity
blocker, and the cutover runbook.
Goal: faster decode and shorter prefill stalls. Phase 1–2 are applied (see their
STATUS lines); each change is one flag in `strata-iq3_s.json` args (or
`configure-hlh-ai-engine-strata.sh` for permanence). Restart `strata.service`
after each change; benchmark before/after.

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

**STATUS: APPLIED 2026-10-11 (live ad-hoc + IaC, tagged v0.3.0).** Results below.

6. `--pool-workers 10` — pool currently runs 8 workers + host thread on the
   12-core allocation; more workers serve cache misses faster.
7. `--lookup-chain 2` — suffix drafts already hit 6/6 on repetitive code
   output; chaining grows verify windows to 8 where repeats are likely.
8. `--prompt-cache-tail` — one extra checkpoint near the prompt end; shaves
   the fresh-read tail further.
9. `--conversation-cache-mib 8192` (tune to headroom) — parked-conversation
   RAM cache is off by default; speeds session restore with many OpenCode
   sessions (~23 GB host headroom available).

### Phase 2 applied — verification (2026-10-11, live LXC 115)

| Flag | Honored? | Evidence |
|---|---|---|
| `--pool-workers 10` | ✅ | "10 pool workers ... the host thread on 0 (draining too)"; participating threads 11; tasks/phase 33 (was 27) |
| `--lookup-chain 2` | ✅ | "lookup chain: 19 of 101 windows, 15 of 34 chained drafts accepted" |
| `--prompt-cache-tail` | ✅ (silent) | accepted at start, no dedicated log line; requests show 6 checkpoints |
| `--conversation-cache-mib 4096` | ✅ | "parked 91334 tokens in 695 ms"; "restored 91334 tokens (live) in 382.7 ms" -> next request reused 91,334 of 92,226 tokens, only 892 fresh read in 5.2 s |

Measured on real traffic after restart:

- Decode **41.8–47.5 tok/s** (baseline typical 34, Phase 1 warm 43.5).
- Session restore: 91k-token conversation back live in **0.4 s** (was: full
  re-prefill).
- First request after restart was cold (91k tokens in 771 s while the engine
  was still pinning experts; 12.4M major faults during warmup) — subsequent
  requests: 33–56 faults. Restart + immediate heavy traffic is the one rough
  edge; warm state is clean.
- Memory: CT 50.8/57 GB, parked conversations ~1–2 GB of the 4 GB budget,
  ~15 GB page cache intact.
- Hit rate 89.7% — still below the 94–95.5% baseline while the learned
  profile re-adapts; watch over the coming days.
- Rollback: `/opt/strata/strata-iq3_s.json.bak-phase1` + service restart.

## Phase 3 — model + hardware

**STATUS: download COMPLETE 2026-10-12 00:30 EDT — cutover pending.** Item 10
(IQ3_XXS A/B) is staged on the HDD pool; the swap itself is the next step.
Everything below is the live state + the cutover runbook, because the swap needs
a service restart and a storage move that cannot be done while the engine is
serving.

### 3.1 Item 10 — IQ3_XXS A/B (in flight)

Why: IQ3_XXS experts are **42.9 GB vs 50.3 GB IQ3_S** (`packs/iq3_s/experts.bin`
measures 50,292,326,400 B). ~7.4 GB less expert state to page over the 3.3 GB/s
OCuLink link is the biggest remaining decode lever, at a modest quality cost.

Download that ran (prox01, host root, 2026-10-12 00:01–00:30 EDT):

```
PID 836774  started Mon Oct 12 00:01:25 EDT
/root/.local/bin/hf download ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF \
    --include IQ3_XXS/* --local-dir /srv/ai/models
```

| Shard | Size | Note |
|---|---|---|
| `Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf` | 47,039,860,096 B (43.8 GiB) | the `--native` shard — carries the quantized experts, so it is 7.8 GB smaller than IQ3_S's and the slow one to fetch |
| `Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf` | 28,800,138,432 B (26.8 GiB) | same size as the IQ3_S shard 2 — it is the `--ple-gguf` side, quant-independent |
| **Pair total** | **75,839,998,528 B (70.6 GiB)** | vs 83,617,662,528 B for the IQ3_S pair |

**Complete 2026-10-12 00:30 EDT** (28.5 min wall, ~44 MB/s): both shards are in
`/srv/ai/models/IQ3_XXS/` at exactly their published sizes — 47,039,860,096 B and
28,800,138,432 B — no `.incomplete` remains and the `hf` process has exited.
Shard 2 landed first (00:18); shard 1 is the slow one. Note `hf` stages in
`/srv/ai/models/.cache/huggingface/download/IQ3_XXS/*.incomplete` and only moves
a file into `IQ3_XXS/` when it is whole — an empty `IQ3_XXS/` dir does **not**
mean nothing has downloaded.

### 3.2 The blocker: the SSD pool cannot hold both quants

`/strata-models` is `rpool/strata-models`, and **rpool is prox01's boot pool on a
single 128 GB AirDisk NVMe** — it is the only non-rotational pool on the host:

| Pool | Backing | SIZE | ALLOC | FREE | Role |
|---|---|---|---|---|---|
| `rpool` | 1x AirDisk 128GB NVMe (ROTA=0) | 117G | 104G (88%) | **13.1G** | boot + `strata-models` (77.9G) |
| `RaidZ1-6TB` | 3x WD30EZRX HDD (ROTA=1) | 8.17T | 6.26T | 1.91T | packs, CT 115 rootfs, model GGUFs |
| `Raid0-2TB` | 2x WD10EADS/EAVS HDD (ROTA=1) | 1.81T | 2.02G | 1.81T | **not an SSD** — do not put shards here |

`rpool/strata-models` holds the IQ3_S pair (77.9G) and rpool has **9.45G avail**.
The IQ3_XXS pair needs 70.6 GiB, so **the two pairs cannot coexist on the SSD**.
There is no room to "download then copy" — the SSD copies of IQ3_S must be
deleted first, and the running engine has both files mmap'd
(`--native /srv/ssd-models/...IQ3_S-00001...`, `--ple-gguf ...00002...`), so
freeing that space means stopping `strata.service` = **this model goes offline
for the swap**.

Safe to delete: the IQ3_S pair still exists on the HDD pool
(`/srv/ai/models/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-0000{1,2}-of-00002.gguf`, plus
the merged 78 GB `Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S.gguf` used by llama.cpp). The
`.done` markers (`whole (checked against its own tensor directory)`) exist on both
copies.

After deleting the IQ3_S pair, rpool avail goes to ~87G; the IQ3_XXS pair leaves
~16G spare. rpool is already at 88% cap / 42% fragmentation — do not let it go
above ~85% again, and note `zfs create` for a third quant on this pool is off
the table without a bigger SSD.

### 3.3 Cutover runbook (the reboot is mandatory)

Downtime window: shard copy HDD→SSD (~5–10 min on rpool) + pack build + model
load (IQ3_XXS runs in `--resident-experts` low-RAM mode; allow 15–25 min).

```bash
# 0. confirm the download finished — VERIFIED 2026-10-12 00:30 EDT (both shards
#    present at published sizes, no .incomplete, hf exited). Re-run if unsure:
ssh root@192.168.1.10 'ls -la /srv/ai/models/IQ3_XXS; \
  find /srv/ai/models/.cache/huggingface/download/IQ3_XXS -name "*.incomplete"'

# 1. stop the engine (frees the mmap on the IQ3_S shards)
ssh root@192.168.1.10 'pct exec 115 -- systemctl stop strata'

# 2. free the SSD, then stage the new pair on it
ssh root@192.168.1.10 'rm -f /strata-models/*IQ3_S*.gguf /strata-models/*IQ3_S*.done; \
  zfs list -o name,used,avail rpool; \
  rsync -a --info=progress2 /srv/ai/models/IQ3_XXS/ /strata-models/'

# 3. re-pack from the local SSD shards (engine is already built — pack only)
ssh root@192.168.1.10 'pct exec 115 -- sh -c "cd /opt/strata && \
  STRATA_EXPERIMENTAL_SM60=1 ./setup.sh --setup --family qwen3.8-flash-next \
  --model IQ3_XXS --context 131072 --kv k8v4 --gpu cuda --port 80 \
  --data-dir /srv/ai/models/strata --gguf-dir /srv/ssd-models --low-ram auto --no-start --yes"'

# 4. carry the Phase 1+2 flags onto the new config, then restart
#    /opt/strata/strata-iq3_xxs.json args must match strata-iq3_s.json except:
#      --pack  /srv/ai/models/strata/packs/iq3_xxs
#      --native /srv/ssd-models/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00001-of-00002.gguf
#      --ple-gguf /srv/ssd-models/Qwen3.8-Flash-Next-GSQ-RCO-IQ3_XXS-00002-of-00002.gguf
#      model_name qwen3.8-flash-next-iq3_xxs, log /opt/strata/strata-iq3_xxs.log
#    Keep: --kv k8v4 --resident-experts --kv-grow --prefill auto:16384 --adapt-async 1
#          --spec 4 --spec-min-p 0.5 --pool-workers 10 --lookup-chain 2
#          --prompt-cache-tail --conversation-cache-mib 4096
#          --expert-profile(+save) /opt/strata/data/expert-profile.bin
ssh root@192.168.1.10 'pct exec 115 -- systemctl restart strata'

# 5. verify
ssh root@192.168.1.10 'pct exec 115 -- curl -s localhost/health'   # model: qwen3.8-flash-next-iq3_xxs
```

Rollback: the IQ3_S pack (`packs/iq3_s`, 49 GB) and the HDD shard copies are
untouched, so revert = copy the IQ3_S pair back to `/strata-models`, point the
service back at `strata-iq3_s.json`, `systemctl restart strata`. Do **not**
delete `packs/iq3_s` until the IQ3_XXS A/B is signed off.

### 3.4 Script gaps this exposes (fix before running the cutover)

- `deploy-hlh-ai-engine-strata.sh` seeds the SSD with a **hardcoded**
  `GGUF_STEM="Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S"` — it will not seed IQ3_XXS.
  Make it `GGUF_STEM="Qwen3.8-Flash-Next-GSQ-RCO-${MODEL_QUANT}"` and add a
  `--model` pass-through, mirroring `configure-hlh-ai-engine-strata.sh`
  (which already does this correctly: `MODEL_NAME` + `--gguf-dir`).
- No capacity gate: the seed loop happily tries to copy 70.6 GiB onto a pool
  with 9.45G avail. Add an `avail >= pair size + 8G` check before seeding.
- Config drift: `LXC_MEMORY=56320` in the deploy script, live CT 115 is
  **58320** (57 GB). Reconcile before any `pct create` re-run, or a rebuild
  silently loses the 2 GB of mmap page-cache headroom that fixed the thrash.
- `configure`'s pre-flight already names both shards for `$MODEL_NAME`, so
  `--model IQ3_XXS --gguf-dir /srv/ssd-models` is the correct permanent path;
  the bootstrap re-parses argv inside the CT, so `--model` must be forwarded
  (see `INNER_ARGS`).

### 3.5 What to measure for the A/B

Same replay as Phase 1/2 (2–3 real OpenCode sessions), record in `90_DONE.md`:

- decode tok/s warm (IQ3_S reference: 41.8–47.5)
- expert cache hit rate (IQ3_S reference: 89.7% and climbing; baseline 94–95.5%)
- `expert cache <N> slots` — expect **more slots** at the same VRAM, since the
  pinned expert complement shrinks with 42.9 GB experts
- RAM: pinned GiB + major faults during warmup (IQ3_S: 29.33 GiB pinned, 0 faults
  warm, 12.4M faults on the first cold request after restart)
- quality gut-check on the same coding prompts — IQ3_XXS is the cost side of the
  trade; if it degrades, IQ3_S + the hardware items below are the fallback

### 3.6 Remaining Phase 3 items (not started)

11. CPU contention: LXC 109 (hlh-docker) shares host cores; Jellyfin transcodes /
    container churn steal pool-worker cycles during inference. Consider core
    pinning or scheduling.
12. Power cap: SXM4 V100 is a 300 W part, adapter caps at 250 W. Test
    `nvidia-smi -pl 300` (host, as root) — if accepted, app clock rises from
    1260 toward 1380 MHz. Revert with `nvidia-smi -pl 250` if unstable.
13. Docs hygiene: README says 0.1.32 / Gen3 x2; reality is 0.1.41 / x4.

## Expected combined effect

Decode: 26–43 -> ~40–60 tok/s. Prefill stalls: ~3x shorter. Cold start:
shorter with a learned profile. Phase 3 item 10 (IQ3_XXS) is the one that can
move decode past that band; items 11–12 are worth a few percent each.

## Rollback

Phase 1–2 changes are flags in `strata-iq3_s.json`; restore the previous args
line and `systemctl restart strata`. Model data untouched.

Phase 3 (IQ3_XXS) is a different class of change — it moves model data and
requires a service restart, so downtime is expected. Rollback is the pack +
shard copy in §3.3: keep `packs/iq3_s` and the HDD copies of the IQ3_S pair
until the A/B is signed off, then point the service back at
`strata-iq3_s.json`. Do not delete the IQ3_S shards from `/strata-models`
until that sign-off.

Revert of the whole engine to llama.cpp: `pct set 111 --onboot 1 && pct start 111`
(see README Cutover & Revert).
