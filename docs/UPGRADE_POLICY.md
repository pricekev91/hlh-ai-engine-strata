# Strata Upgrade Policy

**Rule: pin to the latest upstream release tag that is at least 7 days old
("main − 7", snapped to a tag), after a scoped review. Never pin a raw
date-based `main` commit.**

Adopted 2026-11-12. Rationale: upstream (Niko1221/Strata) ships a release every
1–2 days with no stable channel, so every pin is a judgment call — this turns
the judgment into a repeatable, auditable policy.

## Why 7 days

Upstream patches regressions within ~24 h (e.g. 0.2.13 → 0.2.13.1 in one day).
A release that has survived a week in the field has already absorbed its
day-1 breakers. Seven days is the aging floor, not a target — if the review
below fails, fall back one tag and re-run.

## Why snap to the tag, not a raw main commit

Tags are the commits upstream actually built, signed, and shipped. Each tag's
annotation names the exact source commit for every package — including the
**Qwen Linux-CUDA engine** we build from. A raw date-based main commit can sit
mid-merge or between engine builds: untested glue.

Pin the commit named in the tag annotation for the Qwen engine packages
(verified per release; e.g. v0.2.11 → `0bdcef4682c5371f7bcf130c41791c7849d78205`).

## Scoped-review checklist (mandatory before every pin bump)

Reading 3,000 commits is not a review. Scope it to what this deployment uses:

1. **Read the tag annotations** between the current pin and the candidate —
   upstream writes detailed build notes per package.
2. **Risk-area-filtered log**:
   `git log --oneline <current-pin>..<candidate> | grep -iE "sm_70|sm_60|volta|expert.?profile|pack|cuda12|vision|mtp|openai|anthropic|resident|ple"`
3. **Flag re-grep**: confirm all serve flags used by
   `strata-iq3_s_abliterated.json` still exist in the candidate tree
   (`--ple-gguf --expert-profile --resident-experts --kv-grow --lookup-chain
   --prompt-cache-tail --conversation-cache-mib --pool-workers --adapt-async
   --vram-reserve-mib --spec-min-p --max-context --vision`), plus the
   `setup.sh` invocation flags.
4. **Build gate unchanged**: `STRATA_EXPERIMENTAL_SM60` still present in
   CMakeLists and still required for cc 7.0; CUDA 12.x still supported.
5. Anything unresolved in Volta paths → **fall back one tag** and re-run.

Record the review result in the CHANGELOG entry for the bump.

## Deploy gate (bench before/after)

- Pre-flight: back up `expert-profile.bin` + the active config; record the
  current bench ladder (0.5.4 methodology: 3 configs × 6 tests) and the
  `/health` + `/v1/models` output.
- After deploy: re-run the ladder; decode/prefill deltas and expert hit rate
  go in `10_ACTIVE.md` / CHANGELOG. Vision re-check on Volta: `images: true`
  + `input_modalities: ["text","image"]` + one real image.
- A regression beyond noise is a rollback, not a debate.

## Rollback (always one command)

```sh
STRATA_COMMIT=<previous-pin> ./deploy-hlh-ai-engine-strata.sh --skip-host-driver --yes
```

Current rollback pin: `7695859aa13afb248bdb4d36f9b2e95707db079d` (0.1.43).
Previous: `fb58e0dbc8399662c0e47c76578c6e878b14f6cf` (0.1.x, pre-0.1.43).

## Pin history

| Repo version | Strata pin | Engine | Tag date | Aged | Review |
|---|---|---|---|---|---|
| 0.5.5 | `0bdcef468` (0.2.11) | 0.1.57 | 2026-11-05 | 7 d | PASS — CHANGELOG 0.5.5 |
| 0.4.2 | `7695859` (0.1.43) | 0.1.43 | 2026-10-11 | — | manual (pre-policy) |
| ≤0.4.1 | `fb58e0d` (0.1.41) | 0.1.41 | — | — | manual (pre-policy) |

## Versioning note

This repo keeps its **own version line** (0.5.x) independent of the engine pin:
the repo version tracks *our* changes (scripts, flags, model config, docs);
the upstream pin is data, recorded per release in the CHANGELOG title, the
README table, and the pin-history table above. Mirroring the upstream number
would break on any of: patching our scripts without an engine change, rolling
back the engine, or pinning an engine commit between app releases.
