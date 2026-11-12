#!/usr/bin/env bash
# strata-switch-model.sh
# Version: 1.1.0
# Description: Model switcher for the Strata AI engine (LXC 115, Tesla V100 GV100 32GB, sm_70 EXPERIMENTAL).
#              Runs on the PROXMOX HOST (prox01) - it needs pct, zfs and the host path of the SSD
#              model dataset (/strata-models = rpool/strata-models = CT /srv/ssd-models).
#
# On a switch it:
#   1. reads the LIVE config (the one strata.service points at) and keeps every tuning flag from it
#      (--max-context, --kv, --kv-grow, --prefill, --adapt-async, --spec, --mtp, --resident-experts,
#       --pool-workers, --lookup-chain, --conversation-cache-mib, --vision, allowed_hosts, port, ...)
#      so the new model starts with the SAME settings the current model is running at;
#   2. stops strata.service and deletes the PREVIOUS model's shards from the SSD dataset;
#   3. copies ONLY the new model's shard pair HDD -> SSD, because Strata reads the PLE n-gram table
#      (unbuffered, on the token path) and the native experts from SSD - tok/s depends on it;
#   4. writes /opt/strata/strata-<tag>.json, repoints the unit, starts it, waits for /health and
#      verifies the model name; on failure it reverts the unit/config and re-seeds the old shards.
#
# Usage:
#   strata-switch-model.sh                      interactive: show models, switch by number or tag
#   strata-switch-model.sh --list               show current model + settings + all models, no changes
#   strata-switch-model.sh --to TAG [--yes]     switch to TAG
#   strata-switch-model.sh --dry-run --to TAG   every check + the generated config, but NO stop/copy/delete/restart
#   strata-switch-model.sh --rollback           switch back to the model in active.json's "prev"
#   strata-switch-model.sh --build-pack TAG     build a missing pack (HDD, ~15-45 min) and exit
# Options:
#   --no-ple-reuse     always re-copy shard 2 (default: reuse the SSD copy when it is byte-identical -
#                      the PLE table is quant-independent, so this saves 26.8 GiB and ~5 min per switch)
#   --from-hdd         skip the SSD copy and run off the HDD copies (much slower; opt-in only)
#   --lxc N            CT id (default 115)
#   --headroom-gib N   free SSD space to keep after the copy (default 8)
#   --health-wait S    seconds to wait for /health (default 1800)
#   --no-rollback      do not auto-revert when the new model fails to come up
#   --check-hf         compare the on-disk shard sizes with Hugging Face's x-linked-size
#   --strict           treat a size mismatch as fatal
set -euo pipefail

VERSION="1.1.0"
LXC="${STRATA_LXC:-115}"
MODEL_HOST_DIR="/srv/ai/models"                 # CT mp0  -> /srv/ai/models
SSD_HOST_DIR="/strata-models"                   # rpool/strata-models, CT mp1 -> /srv/ssd-models
CT_SSD_DIR="/srv/ssd-models"
STRATA_DIR="/opt/strata"
STRATA_ROOT="/srv/ai/models/strata"             # packs / data / configs / state (HDD pool)
PACKS_DIR="$STRATA_ROOT/packs"
DATA_DIR="$STRATA_ROOT/data"
CFG_STORE="$STRATA_ROOT/configs"
STATE_FILE="$STRATA_ROOT/active.json"
LOG_FILE="$STRATA_ROOT/switch.log"
SERVICE="strata"
UNIT="/etc/systemd/system/${SERVICE}.service"
HEALTH_URL="http://127.0.0.1/health"            # inside the CT
HEADROOM_GIB=8
HEALTH_WAIT_S=1800
DRY_RUN=0 ASSUME_YES=0 ROLLBACK=0 PLE_REUSE=1 FROM_HDD=0 NO_ROLLBACK=0 CHECK_HF=0 STRICT=0
MODE="interactive" TO="" BUILD_PACK_TAG=""

# published sizes (bytes): tag -> shard1 shard2 ; and the HF repo/path each came from
# Verification data for the KNOWN quant pairs (published sizes + HF origin) -
# model *discovery* is dynamic (a scan of MODEL_HOST_DIR); a tag missing from
# these tables is still switchable, it just skips the published-size check
# (defaults 0). When adding a new quant, publish its sizes here for
# --check-hf / --strict; nothing else needs to change.
declare -A EXP=( [iq3_s]="54817524224 28800138432" [iq3_xxs]="47039860096 28800138432"
                 [iq3_s_abliterated]="55063448064 28800138432" )
declare -A HF=( [iq3_s]="ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/IQ3_S"
                [iq3_xxs]="ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF/IQ3_XXS"
                [iq3_s_abliterated]="SC117/Qwen3.8-Flash-Next-GSQ-RCO-abliterated-GGUF/IQ3_S" )

log()  { echo "[strata-switch] $*"; }
warn() { echo "[strata-switch] WARNING: $*" >&2; }
die()  { echo "[strata-switch] ERROR: $*" >&2; exit 1; }
run()  { if [ "$DRY_RUN" = 1 ]; then echo "    DRY-RUN: $*"; return 0; fi; "$@"; }
ct()   { pct exec "$LXC" -- "$@"; }
gb()   { numfmt --to=iec --suffix=B "${1:-0}"; }
gib()  { echo "$(( ${1:-0} / 1073741824 ))"; }
short(){ sed -e 's|Qwen3[.]8-Flash-Next-GSQ-RCO-||' -e 's|-00001-of-00002[.]gguf|.shard1|' -e 's|-00002-of-00002[.]gguf|.shard2|' -e 's|[.]gguf$||'; }
summarize(){ python3 -c '
import json,sys
try: c = json.loads(sys.argv[1])
except Exception: sys.exit(0)
a = c["args"]; out = []
def g(f): return a[a.index(f)+1] if f in a else None
for f, lab in (("--max-context","ctx"),("--kv","kv"),("--spec","spec"),("--pool-workers","pool"),
               ("--conversation-cache-mib","cache"),("--prefill","prefill"),("--mtp","mtp")):
    v = g(f)
    if v: out.append("%s %s" % (lab, v.split("/")[-1] if lab == "mtp" else v))
for f, lab in (("--resident-experts","resident"),("--kv-grow","kv-grow"),("--prompt-cache-tail","tail-cache"),("--vision","vision")):
    if f in a: out.append(lab)
print("  ".join(out))
' "$1"; }
copy_to_ssd(){ # src dst
  local src="$1" dst="$2" t0=$SECONDS
  if [ -t 1 ]; then rsync -ah --info=progress2 "$src" "$dst"; else rsync -a "$src" "$dst"; fi
  local d=$(( SECONDS - t0 )); [ $d -lt 1 ] && d=1
  log "  copied $(gib "$(stat -c %s "$dst")") GiB in ${d}s ($(( $(stat -c %s "$dst") / d / 1048576 )) MB/s)"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --list) MODE="list"; shift ;;
    --to) MODE="switch"; TO="${2:-}"; [ -n "$TO" ] || die "--to needs a model tag"; shift 2 ;;
    --rollback) MODE="switch"; ROLLBACK=1; shift ;;
    --build-pack) MODE="buildpack"; BUILD_PACK_TAG="${2:-}"; [ -n "$BUILD_PACK_TAG" ] || die "--build-pack needs a tag"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --yes|-y) ASSUME_YES=1; shift ;;
    --lxc) LXC="$2"; shift 2 ;;
    --headroom-gib) HEADROOM_GIB="$2"; shift 2 ;;
    --health-wait) HEALTH_WAIT_S="$2"; shift 2 ;;
    --no-ple-reuse) PLE_REUSE=0; shift ;;
    --from-hdd) FROM_HDD=1; shift ;;
    --no-rollback) NO_ROLLBACK=1; shift ;;
    --check-hf) CHECK_HF=1; shift ;;
    --strict) STRICT=1; shift ;;
    -h|--help) awk 'NR>1 && /^#/{sub(/^# ?/,""); print; next} NR>1{exit}' "$0"; exit 0 ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ "$(id -u)" = 0 ] || die "run as root on the Proxmox host (needs pct, zfs and $SSD_HOST_DIR)"
command -v pct >/dev/null 2>&1 || die "pct not found - run this on the Proxmox host (prox01), not inside the CT"
[ -d "$SSD_HOST_DIR" ] || die "$SSD_HOST_DIR is not mounted (rpool/strata-models?)"
[ -d "$MODEL_HOST_DIR" ] || die "$MODEL_HOST_DIR is not present on the host"
mkdir -p "$CFG_STORE" "$DATA_DIR"

# ------------------------------------------------------------------ discovery
declare -A TAG_SRC1 TAG_SRC2 TAG_PACK TAG_NAME
discover() {
  local f base rest quant abl tag
  TAG_SRC1=(); TAG_SRC2=(); TAG_PACK=(); TAG_NAME=()
  while IFS= read -r f; do
    base="$(basename "$f")"
    case "$base" in Qwen3.8-Flash-Next-GSQ-RCO-*) : ;; *) continue ;; esac
    rest="${base#Qwen3.8-Flash-Next-GSQ-RCO-}"; rest="${rest%-00001-of-00002.gguf}"
    [ "$rest" = "$base" ] && continue
    abl=""; quant="$rest"
    if [[ "$rest" == abliterated-* ]]; then abl="_abliterated"; quant="${rest#abliterated-}"; fi
    tag="$(printf '%s' "$quant" | tr '[:upper:]' '[:lower:]')$abl"
    TAG_SRC1[$tag]="$f"
    TAG_SRC2[$tag]="${f%-00001-of-00002.gguf}-00002-of-00002.gguf"
    TAG_PACK[$tag]="$PACKS_DIR/$tag"
    local mname="qwen3.8-flash-next-$(printf '%s' "$quant" | tr '[:upper:]' '[:lower:]')"
    [ -n "$abl" ] && mname="$mname-abliterated"
    TAG_NAME[$tag]="$mname"
  done < <(find "$MODEL_HOST_DIR" -mindepth 1 -maxdepth 3 -type f -name '*-00001-of-00002.gguf' 2>/dev/null | sort)
}
resolve_tag() {
  local want; want="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]' | tr '-' '_')"
  [ "$want" = "iq3_s_abl" ] && want="iq3_s_abliterated"
  [ -n "${TAG_SRC1[$want]:-}" ] && { printf '%s' "$want"; return 0; }
  return 1
}
pack_ok() { local d="$1"; [ -s "$d/index.txt" ] && [ -s "$d/native_experts.txt" ] && [ -s "$d/dense.bin" ] && [ -s "$d/tokenizer/vocab.json" ]; }
pack_experts() { [ -s "$1/experts.bin" ]; }

# ------------------------------------------------------------------ live config
current_config_path() { ct cat "$UNIT" 2>/dev/null | tr -d '\r' | grep -m1 '^ExecStart=' | grep -o -- '--config [^ ]*' | awk '{print $2}'; }
live_cfg_json() { local p="${1:-$(current_config_path)}"; [ -n "$p" ] && ct cat "$p" | tr -d '\r'; }

build_pack() {
  local tag="$1" src1="${TAG_SRC1[$tag]}" out="$PACKS_DIR/$tag"
  log "building pack $out: reads $(gb "$(stat -c %s "$src1")"), writes ~50 GB (15-45 min on the HDD pool)"
  mkdir -p "$out"
  ct bash -c "cd $STRATA_DIR && nice -n 19 ionice -c 3 .venv/bin/python tools/iq_pack.py --gguf '$src1' --out '$out' --experts-bin" 2>&1 | tee -a "$PACKS_DIR/build-$tag.log"
  ct bash -c "cd $STRATA_DIR && .venv/bin/python tools/strata_tokenizer.py --gguf '$src1' --out '$out'" 2>&1 | tee -a "$PACKS_DIR/build-$tag.log"
  pack_ok "$out" || die "the pack build finished but $out is still incomplete"
}

# Copy the live config, rewrite only the model-specific keys.
gen_config() { # source_json tag pack native ple profile
python3 - "$1" "$2" "$3" "$4" "$5" "$6" <<'PY'
import json, sys
src, tag, pack, native, ple, profile = sys.argv[1:7]
name = {"iq3_s": "qwen3.8-flash-next-iq3_s",
        "iq3_xxs": "qwen3.8-flash-next-iq3_xxs",
        "iq3_s_abliterated": "qwen3.8-flash-next-iq3_s-abliterated"}.get(tag,
               "qwen3.8-flash-next-" + tag.replace("_", "-"))
cfg = json.loads(src)
a = cfg["args"]
def setflag(flag, value):
    if flag in a:
        a[a.index(flag) + 1] = value
    else:
        a.extend([flag, value])
setflag("--pack", pack)
setflag("--native", native)
setflag("--ple-gguf", ple)
setflag("--expert-profile", profile)
if "--expert-profile-save" in a:
    setflag("--expert-profile-save", profile)
cfg["tokenizer"] = pack + "/tokenizer"
cfg["model_name"] = name
cfg["log"] = "/opt/strata/strata-%s.log" % tag
if isinstance(cfg.get("vision"), dict) and cfg["vision"].get("model"):
    cfg["vision"]["model"] = native
sys.stdout.write(json.dumps(cfg, indent=1) + "\n")
PY
}

save_state() {
  local tag="$1" prev=""
  [ -f "$STATE_FILE" ] && prev="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("prev",""))' "$STATE_FILE" 2>/dev/null || true)"
  python3 - "$STATE_FILE" "$tag" "$prev" <<'PY'
import json, sys, datetime
json.dump({"tag": sys.argv[1], "prev": sys.argv[2],
           "at": datetime.datetime.now().isoformat(timespec="seconds")},
          open(sys.argv[1], "w"), indent=1)
PY
}

wait_health() { # timeout_s want_model
  local t="$1" want="$2" end=$((SECONDS + t)) got
  while [ $SECONDS -lt $end ]; do
    got="$(ct curl -s -m 5 "$HEALTH_URL" 2>/dev/null | tr -d '\r' || true)"
    if [ -n "$got" ] && { [ -z "$want" ] || printf '%s' "$got" | grep -q "$want"; }; then printf '%s' "$got"; return 0; fi
    printf '    .'; sleep 5
  done
  return 1
}

show_current() {
  local cfgpath model state
  cfgpath="$(current_config_path || true)"
  model="$(ct curl -s -m 5 "$HEALTH_URL" 2>/dev/null | tr -d '\r' | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin); print(d.get("model") or d.get("model_name") or "?")
except Exception:
    print("(not answering)")' 2>/dev/null || echo '(not answering)')"
  # systemctl is-active exits 3 for an inactive/missing unit; with set -e +
  # pipefail that killed the script before it printed anything.
  state="$(ct systemctl is-active "$SERVICE" 2>/dev/null | tr -d '\r' || true)"
  printf 'strata  LXC %s  service %s  serving %s\n' "$LXC" "${state:-?}" "${model:-?}"
  printf '  config   %s\n' "${cfgpath:-none}"
  printf '  settings %s\n' "$(summarize "$(live_cfg_json)")"
  printf '  SSD      %s used / %s free   %s\n' "$(zfs list -o used -H rpool/strata-models)" \
    "$(zfs list -o available -H rpool/strata-models)" \
    "$(ls -1 "$SSD_HOST_DIR"/*.gguf 2>/dev/null | xargs -n1 basename 2>/dev/null | short | awk '{printf "%s%s", (NR>1?" + ":""), $0}')"
  if [ "${VERBOSE:-0}" = 1 ]; then
    printf '  args     %s\n' "$(live_cfg_json | python3 -c 'import json,sys;print(" ".join(json.load(sys.stdin)["args"]))' 2>/dev/null)"
  fi
}

show_models() {
  printf '\n  %-2s %-21s %-12s %-14s %s\n' '#' MODEL SHARDS PACK ON_SSD
  local t n=0 sz1 sz2 note on
  for t in $(printf '%s\n' "${!TAG_SRC1[@]}" | sort); do
    n=$((n+1))
    sz1="$(stat -c %s "${TAG_SRC1[$t]}")"; sz2="$(stat -c %s "${TAG_SRC2[$t]}" 2>/dev/null || echo 0)"
    pack_experts "${TAG_PACK[$t]}" && note="experts.bin" || note="dense only"
    pack_ok "${TAG_PACK[$t]}" || note="MISSING"
    [ -e "$SSD_HOST_DIR/$(basename "${TAG_SRC1[$t]}")" ] && on="yes" || on="-"
    printf '  %-2s %-21s %3s+%3s GiB   %-14s %s\n' "$n" "$t" "$(gib "$sz1")" "$(gib "$sz2")" "$note" "$on"
  done
  if [ "${VERBOSE:-0}" = 1 ]; then
    local t2; for t2 in $(printf '%s\n' "${!TAG_SRC1[@]}" | sort); do printf '  %s\n    %s\n' "$t2" "${TAG_SRC1[$t2]}"; done
  fi
}

case "$MODE" in
list) VERBOSE=1; discover; show_current; show_models; exit 0 ;;
buildpack)
  discover; t="$(resolve_tag "$BUILD_PACK_TAG")" || die "unknown model tag: $BUILD_PACK_TAG (try --list)"
  build_pack "$t"; log "pack ready: ${TAG_PACK[$t]}"; exit 0 ;;
esac

discover
[ ${#TAG_SRC1[@]} -gt 0 ] || die "no Qwen3.8-Flash-Next-GSQ-RCO shard pair found under $MODEL_HOST_DIR"

if [ "$ROLLBACK" = 1 ]; then
  [ -f "$STATE_FILE" ] || die "no $STATE_FILE - nothing to roll back to"
  TO="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("prev",""))' "$STATE_FILE")"
  [ -n "$TO" ] || die "no previous model recorded in $STATE_FILE"
  log "rolling back to $TO"
fi
if [ "$MODE" = "interactive" ]; then
  show_current; show_models; echo
  # Accept the menu number or the tag (menu order = the sort order show_models printed).
  mapfile -t MENU_TAGS < <(printf '%s\n' "${!TAG_SRC1[@]}" | sort)
  printf '  switch to? [number or tag] '; read -r TO
  [ -n "${TO:-}" ] || die "aborted"
  if [[ "$TO" =~ ^[0-9]+$ ]]; then
    [ "$TO" -ge 1 ] && [ "$TO" -le "${#MENU_TAGS[@]}" ] || die "no menu number $TO (1-${#MENU_TAGS[@]})"
    TO="${MENU_TAGS[$((TO-1))]}"
    log "menu choice $TO -> $TO"
  fi
fi
TAG="$(resolve_tag "$TO")" || die "unknown model '$TO' (try --list)"
SRC1="${TAG_SRC1[$TAG]}"; SRC2="${TAG_SRC2[$TAG]}"; PACK="${TAG_PACK[$TAG]}"
NAME1="$(basename "$SRC1")"; NAME2="$(basename "$SRC2")"
CUR_CFG="$(current_config_path)"
[ -n "$CUR_CFG" ] || die "cannot find --config in $UNIT"
LIVE="$(live_cfg_json "$CUR_CFG")"; [ -n "$LIVE" ] || die "live config $CUR_CFG is empty or unreadable"

log "switch: $TAG  (${TAG_NAME[$TAG]})"

# ---- pre-flight: shard sizes
prob=""
read -r w1 w2 <<<"${EXP[$TAG]:-0 0}"
for pair in "$SRC1:$w1" "$SRC2:$w2"; do
  f="${pair%:*}"; want="${pair##*:}"; size="$(stat -c %s "$f" 2>/dev/null || echo 0)"
  if [ "$size" = 0 ]; then prob="$prob missing: $f"
  elif [ "$want" != 0 ] && [ "$size" != "$want" ]; then prob="$prob size $(gb "$size") != published $(gb "$want"): $f"
  fi
done
if [ "$CHECK_HF" = 1 ] && [ -n "${HF[$TAG]:-}" ]; then
  repo="${HF[$TAG]%/*}"; dir="${HF[$TAG]##*/}"
  for f in "$SRC1" "$SRC2"; do
    got="$(curl -sIL --max-time 25 "https://huggingface.co/$repo/resolve/main/$dir/$(basename "$f")" 2>/dev/null | tr -d '\r' | awk 'tolower($1)=="x-linked-size:"{print $2}' | head -1)"
    [ -n "$got" ] && [ "$got" != "$(stat -c %s "$f")" ] && prob="$prob HF says $(gb "$got") for $(basename "$f")"
  done
fi
if [ -n "$prob" ]; then
  warn "size check:$prob"
  [ "$STRICT" = 1 ] && die "--strict: refusing to switch with a size mismatch"
fi

# ---- pre-flight: pack
if ! pack_ok "$PACK"; then
  if [ "$DRY_RUN" = 1 ]; then echo "    DRY-RUN: would build the missing pack $PACK (15-45 min, HDD)"
  else build_pack "$TAG"; fi
fi
pack_ok "$PACK" || die "$PACK is not a complete pack (need index.txt, native_experts.txt, dense.bin, tokenizer/vocab.json)"
log "  pack ready: $(basename "$PACK") $(pack_experts "$PACK" && echo '+ experts.bin' || echo '(dense only)')"
if printf '%s' "$LIVE" | grep -q -- '--resident-experts' && ! pack_experts "$PACK"; then
  warn "$PACK has no experts.bin, but the live settings use --resident-experts."
  warn "  It works (the experts stream from the native GGUF on the SSD), but it is not the path the tuning was"
  warn "  measured on. To build it: $0 --build-pack $TAG  (~10 min, ~47 GB on the HDD pool)"
fi

# ---- pre-flight: SSD space (the PLE table is quant-independent: reuse it when identical)
PLE_FROM=""
if [ "$PLE_REUSE" = 1 ]; then
  sz2="$(stat -c %s "$SRC2")"
  a1="$(ionice -c3 head -c 268435456 "$SRC2" | md5sum | cut -d' ' -f1)"
  b1="$(ionice -c3 tail -c 268435456 "$SRC2" | md5sum | cut -d' ' -f1)"
  for cand in "$SSD_HOST_DIR"/*-00002-of-00002.gguf; do
    [ -f "$cand" ] || continue
    [ "$(stat -c %s "$cand")" = "$sz2" ] || continue
    [ "$(basename "$cand")" = "$NAME2" ] && { PLE_FROM="$cand"; break; }
    if [ "$(ionice -c3 head -c 268435456 "$cand" | md5sum | cut -d' ' -f1)" = "$a1" ] &&
       [ "$(ionice -c3 tail -c 268435456 "$cand" | md5sum | cut -d' ' -f1)" = "$b1" ]; then
      PLE_FROM="$cand"; break
    fi
  done
  [ -n "$PLE_FROM" ] && log "  PLE table already on the SSD, byte-identical: $(basename "$PLE_FROM" | short) -> hard-linked (saves $(gib "$sz2") GiB)"
fi
NEED=$(( $(stat -c %s "$SRC1") + $(stat -c %s "$SRC2") ))
[ -n "$PLE_FROM" ] && NEED=$(( $(stat -c %s "$SRC1") ))
AVAIL=$(( $(zfs list -o avail -H rpool/strata-models | numfmt --from=iec) ))
log "  SSD: needs $(gib "$NEED") GiB + $HEADROOM_GIB GiB headroom, $(gib "$AVAIL") GiB free now (the old shards are deleted first)"
# No pre-delete die: the avail above is deliberately pre-purge arithmetic -
# the enforceable gate runs AFTER the old shards are freed (see "still only").
log "  CT memory: $(pct config "$LXC" | awk -F': ' '/^memory:/{print $2}') MiB"

echo
log "plan"
printf '  1. stop %s, delete the old shards from the SSD\n' "$SERVICE"
printf '  2. copy %s (%s GiB) to the SSD\n' "$(basename "$SRC1" | short)" "$(gib "$(stat -c %s "$SRC1")")"
if [ -n "$PLE_FROM" ]; then printf '  3. PLE table hard-linked from %s (no copy)\n' "$(basename "$PLE_FROM" | short)"
else printf '  3. copy %s (%s GiB) to the SSD\n' "$(basename "$SRC2" | short)" "$(gib "$(stat -c %s "$SRC2")")"; fi
printf '  4. write strata-%s.json from the live settings, repoint the unit, start it\n' "$TAG"
printf '  5. wait for /health -> %s (cold load + profile pre-fill)\n' "${TAG_NAME[$TAG]}"
printf '  settings carried over from %s\n' "$(basename "$CUR_CFG")"
echo
if [ "$DRY_RUN" = 0 ] && [ "$ASSUME_YES" = 0 ]; then
  printf '  proceed? ~15-25 min of downtime [y/N] '; read -r ans
  case "$ans" in y|Y|yes|YES) : ;; *) die "aborted" ;; esac
fi

mkdir -p "$DATA_DIR/$TAG"
TMPJSON="$(mktemp "/tmp/strata-$TAG.XXXXXX.json")"
trap 'rm -f "$TMPJSON"' EXIT
gen_config "$LIVE" "$TAG" "$PACK" "$CT_SSD_DIR/$NAME1" "$CT_SSD_DIR/$NAME2" "$DATA_DIR/$TAG/expert-profile.bin" > "$TMPJSON"

if [ "$DRY_RUN" = 1 ]; then
  cp "$TMPJSON" "$CFG_STORE/strata-$TAG.dryrun.json"
  log "DRY RUN - nothing was stopped, copied, deleted or restarted"
  printf '%s\n' "$LIVE" > "/tmp/strata-live.$$.json"
  python3 - "/tmp/strata-live.$$.json" "$CFG_STORE/strata-$TAG.dryrun.json" <<'PYREPORT'
import json, sys
live = json.load(open(sys.argv[1])); new = json.load(open(sys.argv[2]))
def pairs(a):
    out, i = {}, 0
    while i < len(a):
        if a[i].startswith("--"):
            if i + 1 < len(a) and not a[i+1].startswith("--"): out[a[i]] = a[i+1]; i += 2
            else: out[a[i]] = True; i += 1
        else: i += 1
    return out
lp, np = pairs(live["args"]), pairs(new["args"])
changed = [k for k in np if lp.get(k) != np[k]]
same = [k for k in np if lp.get(k) == np[k]]
print("    would install  " + sys.argv[2])
print("    model_name     " + new["model_name"])
print("    changed:")
for k in changed:
    v = np[k]
    print("      %-19s %s -> %s" % (k, lp.get(k, "-"), v))
for k in ("tokenizer", "log"):
    if live.get(k) != new.get(k): print("      %-19s %s -> %s" % (k, live.get(k), new.get(k)))
if isinstance(new.get("vision"), dict) and live.get("vision", {}).get("model") != new["vision"].get("model"):
    print("      %-19s %s" % ("vision.model", new["vision"]["model"]))
print("    unchanged: %s" % " ".join(same))
PYREPORT
  log "preview saved: $CFG_STORE/strata-$TAG.dryrun.json"
  exit 0
fi

# ---- rollback material
cp "$UNIT" "$UNIT.bak-pre-$TAG-$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
PREV_CFG_PATH="$CUR_CFG"
PREV_SHARDS=()
while IFS= read -r f; do [ -n "$f" ] && PREV_SHARDS+=( "$(basename "$f")" ); done \
  < <(ct sh -c "grep -o -- '--native [^ ]*\|--ple-gguf [^ ]*' '$PREV_CFG_PATH'" 2>/dev/null | tr -d '\r' | awk '{print $2}')
log "previous model's SSD shards: ${PREV_SHARDS[*]:-none}"

START=$SECONDS
run ct systemctl stop "$SERVICE"

NATIVE="$CT_SSD_DIR/$NAME1"; PLE="$CT_SSD_DIR/$NAME2"
if [ "$FROM_HDD" = 0 ]; then
  # The SSD dataset is a disposable cache: free EVERY GGUF before the copy, not
  # just the shards named by the live config. A stale pair (or an unreadable
  # config) used to leave the pool full and the copy would fail; keep only the
  # byte-identical PLE shard we are about to hard-link.
  for f in "$SSD_HOST_DIR"/*.gguf; do
    [ -e "$f" ] || continue
    [ -n "$PLE_FROM" ] && [ "$f" = "$PLE_FROM" ] && continue
    log "  freed $(gib "$(stat -c %s "$f")") GiB: $(basename "$f" | short)"
    run rm -f "$f" "$f.done"
  done
  AVAIL=$(( $(zfs list -o avail -H rpool/strata-models | numfmt --from=iec) ))
  [ $AVAIL -ge $NEED ] || die "still only $(gb "$AVAIL") free on rpool/strata-models, need $(gb "$NEED")"
  run copy_to_ssd "$SRC1" "$SSD_HOST_DIR/$NAME1"
  run sh -c "printf 'whole (checked against its own tensor directory)' > '$SSD_HOST_DIR/$NAME1.done'"
  if [ -n "$PLE_FROM" ]; then
    if [ "$PLE_FROM" != "$SSD_HOST_DIR/$NAME2" ]; then
      run ln "$PLE_FROM" "$SSD_HOST_DIR/$NAME2"
      run rm -f "$PLE_FROM" "$PLE_FROM.done"   # the inode now lives under $NAME2
    fi
    run sh -c "printf 'whole (checked against its own tensor directory)' > '$SSD_HOST_DIR/$NAME2.done'"
  else
    run copy_to_ssd "$SRC2" "$SSD_HOST_DIR/$NAME2"
    run sh -c "printf 'whole (checked against its own tensor directory)' > '$SSD_HOST_DIR/$NAME2.done'"
  fi
else
  warn "--from-hdd: Strata reads the PLE table and the experts off the HDD pool - expect a large tok/s loss"
  NATIVE="$SRC1"; PLE="$SRC2"
  gen_config "$LIVE" "$TAG" "$PACK" "$NATIVE" "$PLE" "$DATA_DIR/$TAG/expert-profile.bin" > "$CFG_STORE/strata-$TAG.json"
fi

run ct cp "$CFG_STORE/strata-$TAG.json" "$STRATA_DIR/strata-$TAG.json"
run ct sed -i "s|--config [^ ]*|--config $STRATA_DIR/strata-$TAG.json|" "$UNIT"
run ct systemctl daemon-reload
run ct systemctl start "$SERVICE"

log "waiting up to ${HEALTH_WAIT_S}s for $SERVICE to load ${TAG_NAME[$TAG]} (cold load + expert-profile pre-fill)"
if H="$(wait_health "$HEALTH_WAIT_S" "${TAG_NAME[$TAG]}")"; then
  echo
  save_state "$TAG"
  log "done: $TAG in $(( (SECONDS - START) / 60 )) min"
  printf '%s' "$H" | python3 -c 'import json,sys
try:
    d = json.load(sys.stdin)
    print("    model : %s\n    ctx   : %s\n    images: %s" % (d.get("model") or d.get("model_name"), d.get("context") or d.get("max_context"), d.get("images")))
except Exception:
    print("    health: " + sys.stdin.read())' 2>/dev/null || true
  echo "$TAG switched at $(date -Is)" >> "$LOG_FILE"
  log "engine log: pct exec $LXC -- tail -f $STRATA_DIR/strata-$TAG.log"
  log "back to the previous model: $0 --rollback"
  exit 0
fi

echo
warn "$SERVICE did not report ${TAG_NAME[$TAG]} within ${HEALTH_WAIT_S}s"
echo "$TAG FAILED at $(date -Is)" >> "$LOG_FILE"
if [ "$NO_ROLLBACK" = 0 ] && [ -n "$PREV_CFG_PATH" ]; then
  log "auto-rollback to $PREV_CFG_PATH"
  ct systemctl stop "$SERVICE" || true
  rm -f "$SSD_HOST_DIR/$NAME1" "$SSD_HOST_DIR/$NAME1.done" 2>/dev/null || true
  if [ -n "$PLE_FROM" ] && [ "$PLE_FROM" != "$SSD_HOST_DIR/$NAME2" ]; then rm -f "$SSD_HOST_DIR/$NAME2" "$SSD_HOST_DIR/$NAME2.done" 2>/dev/null || true; fi
  for f in "${PREV_SHARDS[@]}"; do
    [ -e "$SSD_HOST_DIR/$f" ] && continue
    src=""
    for t in "${!TAG_SRC1[@]}"; do
      [ "$(basename "${TAG_SRC1[$t]}")" = "$f" ] && src="${TAG_SRC1[$t]}"
      [ "$(basename "${TAG_SRC2[$t]}")" = "$f" ] && src="${TAG_SRC2[$t]}"
    done
    [ -n "$src" ] && { log "  re-seeding $(basename "$f" | short)"; copy_to_ssd "$src" "$SSD_HOST_DIR/$f"; }
  done
  ct sed -i "s|--config [^ ]*|--config $PREV_CFG_PATH|" "$UNIT"
  ct systemctl daemon-reload && ct systemctl start "$SERVICE"
  warn "rollback started - verify: pct exec $LXC -- curl -s $HEALTH_URL"
fi
exit 1
