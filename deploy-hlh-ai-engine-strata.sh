#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/configure-hlh-ai-engine-strata.sh"

usage() {
	cat <<'EOF'
Usage:
	./deploy-hlh-ai-engine-strata.sh [--skip-host-driver] [--keep-111] [--no-bootstrap] [--yes] [--model M]
	                                 [--vision gpu|cpu|no] [--vision-tokens N]

Strata path (Qwen3.8-Flash-Next IQ3_S/IQ3_XXS on Tesla V100 GV100GL 32GB via OCuLink) - CUDA:
	1) Verify host NVIDIA 580.65.06 (R580, last for Volta GV100 cc 7.0) + V100 present
	2) Ensure Ubuntu 24.04 LXC template
	3) Remove stale LXC 115 leftovers (115.conf.bak.*) / confirm delete if 115 exists
	4) FREE THE V100: stop hlh-ai-engine-egpu (LXC 111, llama.cpp) + onboot 0
	   (Strata and llama.cpp both want the 32 GB of VRAM; 111's config is kept intact
	    for revert: pct set 111 --onboot 1 && pct start 111)
	5) Ensure SSD model dataset (rpool/strata-models -> /strata-models) + seed the
	   IQ3_S GGUF shard pair onto it (from the HDD copy if present), then create
	   privileged LXC 115 (hlh-ai-engine-strata) at 192.168.1.15 with mp0 + mp1
	6) Add cgroup + /dev/nvidia* bind-mounts for single GV100 (c5:00.0)
	7) Start container + push/run Strata bootstrap
	   (CUDA 12.8 + engine build sm_70 EXPERIMENTAL -DSTRATA_EXPERIMENTAL_SM60=ON
	    + IQ3_S pack from LOCAL SSD shards, no model download
	    + image encoder: mmproj-Qwen3.8-Flash-Next-BF16.gguf (0.9 GB download)
	      + strata-vision compile, --vision gpu|cpu|no (default gpu)
	    + systemd strata.service on :80)

NOTES:
	- V100 is Volta (cc 7.0). Strata's upstream engine needs cc 7.5+; the sm_70 build is
	  the community/experimental path (STRATA_EXPERIMENTAL_SM60=1, Strata #295/#236) and
	  REQUIRES a CUDA 12.x toolkit (CUDA 13 dropped sm_60/sm_70).
	- Host driver: R580 580.65.06 (last supporting Volta) on proxmox-kernel-6.14.11-9-pve
	  (6.17+ breaks 550/580 closed DKMS). Install path mirrors hlh-ai-engine-egpu.
	- Model storage: the 78 GB IQ3_S GGUF shard pair is read from the SSD dataset
	  rpool/strata-models (host /strata-models -> LXC /srv/ssd-models, mp1). The
	  RaidZ1-6TB HDD pool was too slow (validated live 2026-10-09: fast on SSD).
	  Strata keeps its packed model + MTP + tokenizer in /srv/ai/models/strata
	  (mp0, same shared mount as hlh-ai-engine-egpu).
	- First bootstrap is long: engine compile ~10-40 min + pack from local SSD shards
	  (no model download; shards auto-seeded to the SSD dataset from /srv/ai/models).
	- Vision (images) is ON by default since 0.5.0: setup downloads the 0.9 GB mmproj
	  encoder into /srv/ai/models/strata/models (mp0 HDD - NOT the SSD dataset, the
	  rpool/strata-models pool has no room for it) and compiles strata-vision for
	  sm_70 (~10-20 min extra). The GPU encoder holds ~1.2 GB of the 32 GB card, so
	  the expert cache loses ~1,000 slots. --vision cpu keeps every slot and encodes
	  on the CPU instead; --vision no is the pre-0.5.0 text-only install.
	- Shell access into the CT: the bootstrap sets PermitRootLogin yes
	  (sshd_config.d/60-root-password.conf), so ssh root@192.168.1.15 works with the
	  CT root password (set it: pct exec 115 -- passwd root). The always-available
	  path is ssh root@192.168.1.10 (prox01) + pct exec 115 -- <cmd>.
EOF
}

# --- PINNED VERSIONS (V100 Volta cc 7.0) ---
# Last stable for Volta: R580 (580.65.06) + CUDA 12.8 (final sm_70 support; CUDA 13 dropped sm_70).
# Host pinned to proxmox-kernel-6.14.11-9-pve + 580.65.06 via .run --dkms (validated for this board).
KERNEL_VER=$(uname -r)
KERNEL_MAJ=$(echo "$KERNEL_VER" | cut -d. -f1)
if [[ "$KERNEL_VER" == *6.14* ]] || [[ "$KERNEL_MAJ" -ge 7 ]]; then
  DEFAULT_DRIVER="580.65.06"
  DEFAULT_SHORT="580.65.06"
  DEFAULT_CUDA="12.8.0-1"
  DEFAULT_MAJOR="12.8"
  DEFAULT_BRANCH="580"
else
  echo "WARNING: kernel $KERNEL_VER is not the validated 6.14 LTS - V100 R580 may not build (see hlh-ai-engine-egpu notes)" >&2
  DEFAULT_DRIVER="580.65.06"
  DEFAULT_SHORT="580.65.06"
  DEFAULT_CUDA="12.8.0-1"
  DEFAULT_MAJOR="12.8"
  DEFAULT_BRANCH="580"
fi
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-$DEFAULT_DRIVER}"
NVIDIA_DRIVER_VERSION_SHORT="${NVIDIA_DRIVER_VERSION_SHORT:-$DEFAULT_SHORT}"
CUDA_VERSION="${CUDA_VERSION:-$DEFAULT_CUDA}"
CUDA_MAJOR="${CUDA_MAJOR:-$DEFAULT_MAJOR}"
DRIVER_BRANCH="${DRIVER_BRANCH:-$DEFAULT_BRANCH}"

# --- LXC 115 (hlh-ai-engine-strata) ---
LXC_ID=115
LXC_NAME="hlh-ai-engine-strata"
LXC_HOSTNAME="hlh-ai-engine-strata"
LXC_IMAGE="local:vztmpl/ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
TEMPLATE_FILE="ubuntu-24.04-standard_24.04-2_amd64.tar.zst"
POOL="RaidZ1-6TB"
MODEL_HOST_DIR="/srv/ai/models"
MODEL_LXC_DIR="/srv/ai/models"
# --- SSD model shards (mp1) ---
# The 78 GB IQ3_S shard pair on the RaidZ1-6TB HDD pool crawled (model load/pack
# was unbearably slow). Shards now live on rpool (prox01's local SSD pool) in
# dataset strata-models, bind-mounted into the CT as /srv/ssd-models (mp1).
# Validated live on LXC 115 2026-10-09. Override the pool with SSD_POOL=...
SSD_POOL="${SSD_POOL:-rpool}"
SSD_DATASET="${SSD_POOL}/strata-models"
MODEL_SSD_HOST_DIR="/strata-models"
MODEL_SSD_LXC_DIR="/srv/ssd-models"
LXC_ROOTFS_SIZE="64"
# Model quant to seed onto the SSD (Q2_0 | IQ2_XS | IQ3_XXS | IQ3_S).
# Phase 3 (3phase-tunning.md §3.4): was hardcoded to IQ3_S, which would not
# seed IQ3_XXS on a rebuild. Override with --model or MODEL_QUANT=...
MODEL_QUANT="${MODEL_QUANT:-IQ3_S}"
# Vision (images): gpu | cpu | no, forwarded to the bootstrap as --vision.
# gpu is the default since 0.5.0 (encoder on the V100, ~1.2 GB of VRAM);
# cpu keeps every expert slot and pays ~3 s/picture; no = text only.
# Override with --vision or VISION_MODE=...
VISION_MODE="${VISION_MODE:-gpu}"
# Max tokens one picture becomes (bootstrap --vision-tokens). Empty = setup's
# default (1024 on gpu, 300 on cpu). Lower it if the encoder does not fit the
# card beside the 128K KV + expert cache.
VISION_TOKENS="${VISION_TOKENS:-}"
# RAM sizing (IQ3_S/IQ3_XXS, --resident-experts low-RAM mode; validated live 2026-10-10):
# Strata pins ~26.7 GiB of experts page-locked in RAM (the complement of the GPU
# cache) + ~2.7 GiB runtime. The rest of the allocation is page cache for the
# mmap'd 78 GB expert GGUFs - at 48 GB the CT ran at its cgroup limit and the OS
# re-read experts from SSD constantly (13M+ major faults). 57 GB gives the mmap
# cache ~7 GB more headroom. Host is 61 GiB: leaves ~6 GiB for host/PVE,
# CT 109 (hlh-docker) and the small VM - do not start 111/112/113 alongside.
# Live CT 115 is 58320 (2026-10-12); keep IaC in sync or a rebuild silently
# loses 2 GB of page-cache headroom.
LXC_MEMORY="58320"
LXC_CORES="12"
LXC_SWAP="512"
LXC_IP_CONFIG="192.168.1.15/24"
LXC_GATEWAY="192.168.1.1"

# LXC 111 = hlh-ai-engine-egpu (llama.cpp, same V100). Stopped at cutover.
EGPU_LXC_ID=111

SKIP_HOST_DRIVER=false
KEEP_EGPU_LXC=false
NO_BOOTSTRAP=false
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
	case "$1" in
		--skip-host-driver) SKIP_HOST_DRIVER=true; shift ;;
		--keep-111) KEEP_EGPU_LXC=true; shift ;;
		--no-bootstrap) NO_BOOTSTRAP=true; shift ;;
		--yes) ASSUME_YES=true; shift ;;
		--model) MODEL_QUANT="$2"; shift 2 ;;
		--vision) VISION_MODE="$2"; shift 2 ;;
		--vision-tokens) VISION_TOKENS="$2"; shift 2 ;;
		-h|--help) usage; exit 0 ;;
		*) echo "ERROR: Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done
case "$MODEL_QUANT" in
	Q2_0|IQ2_XS|IQ3_XXS|IQ3_S) ;;
	*) echo "ERROR: --model must be Q2_0 | IQ2_XS | IQ3_XXS | IQ3_S (got: $MODEL_QUANT)" >&2; exit 1 ;;
esac
case "$VISION_MODE" in
	yes) VISION_MODE="gpu" ;;
	gpu|cpu|no) ;;
	*) echo "ERROR: --vision must be gpu | cpu | no (got: $VISION_MODE)" >&2; exit 1 ;;
esac
if [ -n "$VISION_TOKENS" ] && ! [[ "$VISION_TOKENS" =~ ^[0-9]+$ ]]; then
	echo "ERROR: --vision-tokens takes a number of tokens, e.g. 512 (got: $VISION_TOKENS)" >&2; exit 1
fi

# Built after the option parsing on purpose: --model/--vision must show up in the
# Proxmox description, and pct create runs much later in this script.
LXC_DESC="Strata AI engine (Qwen3.8-Flash-Next ${MODEL_QUANT}, 128K ctx, vision ${VISION_MODE}) - CUDA $CUDA_MAJOR sm_70 EXPERIMENTAL build (-DSTRATA_EXPERIMENTAL_SM60=ON) + driver $NVIDIA_DRIVER_VERSION_SHORT for Tesla V100 (GV100 32GB cc 7.0) via OCuLink c5:00.0, model shards on $SSD_DATASET (SSD) -> /srv/ssd-models, packs on $POOL:/srv/ai/models/strata, port 80"

confirm() { # $1 = prompt text
	[[ "$ASSUME_YES" == "true" ]] && return 0
	local answer
	printf '%s\n' "$1"
	printf '%s' "Continue? [y/N] "
	read -r answer
	case "$answer" in y|Y|yes|YES) return 0 ;; *) echo "Aborted." >&2; exit 1 ;; esac
}

command -v pct >/dev/null 2>&1 || { echo "ERROR: pct not found. Run on Proxmox host." >&2; exit 1; }
[[ -f "$BOOTSTRAP_SCRIPT" ]] || { echo "ERROR: Bootstrap not found: $BOOTSTRAP_SCRIPT" >&2; exit 1; }

# --- V100 helpers: single GV100 ---
detect_v100_pcis() {
	# V100 shows as single 3D controller at c5:00.0 (GV100GL 10de:1df0)
	lspci -nn -D 2>/dev/null | grep -i "10de:1df0" | awk '{print $1}' | sort
}

# --- 0/7 Host driver (pinned) + V100 ---
if [[ "$SKIP_HOST_DRIVER" == "false" ]]; then
	echo "[0/7] Host NVIDIA driver check (pinned: $NVIDIA_DRIVER_VERSION_SHORT Volta GV100 sm70, CUDA $CUDA_MAJOR, kernel $KERNEL_VER)..."
	if lsmod | grep "nvidia" >/dev/null && modinfo nvidia 2>/dev/null | grep "$DRIVER_BRANCH" >/dev/null; then
		echo "  Host driver already loaded: $(modinfo nvidia 2>/dev/null | grep ^version: | head -1) on $KERNEL_VER"
		set +o pipefail; nvidia-smi 2>&1 | head -10 || true; set -o pipefail
		# Ensure nvidia_uvm persists across reboot
		if [ ! -f /etc/modules-load.d/nvidia.conf ]; then
			echo "  - Installing /etc/modules-load.d/nvidia.conf for nvidia_uvm persistence"
			cat > /etc/modules-load.d/nvidia.conf <<'MOD'
nvidia
nvidia_uvm
nvidia_modeset
nvidia_drm
MOD
		fi
		if [ ! -f /etc/systemd/system/nvidia-uvm-devices.service ]; then
			echo "  - Installing nvidia-uvm-devices.service (Before pve-guests.service)"
			cat > /etc/systemd/system/nvidia-uvm-devices.service <<'SVC'
[Unit]
Description=Create NVIDIA UVM device nodes for LXC passthrough (V100 Volta)
Before=pve-guests.service
After=systemd-modules-load.service
Wants=systemd-modules-load.service
DefaultDependencies=no

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'set -e; /sbin/modprobe nvidia || true; /sbin/modprobe nvidia_uvm || true; /sbin/modprobe nvidia_modeset || true; /sbin/modprobe nvidia_drm || true; /usr/bin/nvidia-modprobe -u -c 0 || true; UVM_MAJOR=$(grep -m1 nvidia-uvm /proc/devices 2>/dev/null | awk "{print $1}"); [ -n "$UVM_MAJOR" ] || UVM_MAJOR=511; if [ ! -c /dev/nvidia-uvm ]; then /bin/mknod -m 666 /dev/nvidia-uvm c $UVM_MAJOR 0 2>/dev/null || true; fi; if [ ! -c /dev/nvidia-uvm-tools ]; then /bin/mknod -m 666 /dev/nvidia-uvm-tools c $UVM_MAJOR 1 2>/dev/null || true; fi; /bin/chmod 666 /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>/dev/null || true; /bin/mknod -m 666 /dev/nvidia-modeset c 195 254 2>/dev/null || /bin/chmod 666 /dev/nvidia-modeset 2>/dev/null || true; ls -l /dev/nvidia* 2>&1 | head -n 20'

[Install]
WantedBy=multi-user.target
SVC
			systemctl daemon-reload
			systemctl enable nvidia-uvm-devices.service >/dev/null 2>&1 || true
		fi
		systemctl start nvidia-uvm-devices.service >/dev/null 2>&1 || true
		/sbin/modprobe nvidia_uvm 2>/dev/null || true
		/usr/bin/nvidia-modprobe -u -c 0 2>/dev/null || true
		UVM_MAJOR=$(grep -m1 nvidia-uvm /proc/devices 2>/dev/null | awk '{print $1}'); [ -n "$UVM_MAJOR" ] || UVM_MAJOR=511
		[ -c /dev/nvidia-uvm ] || mknod -m 666 /dev/nvidia-uvm c "$UVM_MAJOR" 0 2>/dev/null || true
		[ -c /dev/nvidia-uvm-tools ] || mknod -m 666 /dev/nvidia-uvm-tools c "$UVM_MAJOR" 1 2>/dev/null || true
		[ -c /dev/nvidia-modeset ] || mknod -m 666 /dev/nvidia-modeset c 195 254 2>/dev/null || true
		chmod 666 /dev/nvidia-uvm /dev/nvidia-uvm-tools 2>/dev/null || true
	else
		echo "  Host driver not loaded. Installing R580 Tesla $NVIDIA_DRIVER_VERSION via .run --dkms"
		echo "  (580 is not in trixie non-free; 590+ drops Volta. Path mirrors hlh-ai-engine-egpu.)"
		echo "  - Blacklisting nouveau"
		cat > /etc/modprobe.d/blacklist-nouveau-v100-strata.conf <<'BLK'
blacklist nouveau
blacklist lbm-nouveau
options nouveau modeset=0
BLK
		if [ ! -f /tmp/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run ]; then
			echo "  Downloading Tesla $NVIDIA_DRIVER_VERSION..."
			wget -q --show-progress "https://us.download.nvidia.com/tesla/${NVIDIA_DRIVER_VERSION}/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run" -O "/tmp/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run" || {
				echo "ERROR: Failed to download $NVIDIA_DRIVER_VERSION .run" >&2; exit 1; }
		fi
		chmod +x "/tmp/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run"
		echo "  Running NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run --dkms --silent --install-libglvnd..."
		"/tmp/NVIDIA-Linux-x86_64-${NVIDIA_DRIVER_VERSION}.run" --dkms --silent --install-libglvnd 2>&1 | tail -n 30
		if ! modinfo nvidia 2>/dev/null | grep -q "580"; then echo "ERROR: 580 driver not loaded after .run" >&2; exit 1; fi
		update-initramfs -u 2>&1 | tail -n 5 || true
		echo "  Host driver ready - if nvidia-smi still fails, reboot prox01 and re-run with --skip-host-driver"
	fi
fi

echo "[0/7] Validating V100..."
V100_PCI_LIST=$(detect_v100_pcis || true)
if [ -z "$V100_PCI_LIST" ]; then echo "ERROR: No V100 (10de:1df0) detected via lspci. Is the OCuLink dock powered on? (expected 0000:c5:00.0)" >&2; lspci -nn | grep -i nvidia || true; exit 1; fi
echo "  Detected V100 PCI addresses:"
echo "$V100_PCI_LIST" | sed 's/^/    /'
V100_COUNT=$(echo "$V100_PCI_LIST" | wc -l)
if [ "$V100_COUNT" -ne 1 ]; then echo "WARNING: Expected 1 GV100 chip, found $V100_COUNT. Continuing." >&2; fi
if ! lsmod | grep "nvidia" >/dev/null; then echo "ERROR: nvidia module not loaded. Run without --skip-host-driver." >&2; exit 1; fi
set +o pipefail; nvidia-smi -L 2>&1 | head -10 || { echo "ERROR: nvidia-smi failed"; exit 1; }; set -o pipefail
nvidia-smi 2>&1 | head -20 || true

# --- 1/7 Template ---
echo "[1/7] Ensuring LXC template ($TEMPLATE_FILE)..."
# NOTE: PVE 9.2 stores local vztmpl archives under /var/lib/vz/template/cache/ (the
# old ct/ dir does not exist) - check storage membership via 'pveam list', not paths.
if ! pveam list local 2>/dev/null | grep -qF "$TEMPLATE_FILE"; then
	echo "  Template not in local storage - updating index and downloading (~1 GB)..."
	pveam update
	# PVE 9.x: pveam download <storage> <template> (there is no 'pveam install')
	pveam download local "$TEMPLATE_FILE" || { echo "ERROR: pveam download local $TEMPLATE_FILE failed" >&2; exit 1; }
fi
pveam list local 2>/dev/null | grep -qF "$TEMPLATE_FILE" || { echo "ERROR: template $TEMPLATE_FILE not in local storage after pveam download" >&2; exit 1; }
echo "  Template present (local:${TEMPLATE_FILE})."

# --- 2/7 Stale LXC 115 leftovers ---
echo "[2/7] Cleaning stale LXC ${LXC_ID} leftovers..."
rm -f "/etc/pve/lxc/${LXC_ID}.conf.bak."* 2>/dev/null || true
if pct status "${LXC_ID}" >/dev/null 2>&1; then
	# /opt/strata lives on the container's rootfs, so pct destroy takes it with it.
	# The packs and GGUF shards are on datasets and survive, but the learned expert
	# profile does not - and it is worth days of traffic (94.8% decode hit rate vs
	# ~87% cold). Snapshot it onto the surviving model dataset before destroying.
	SNAP_DIR="${MODEL_HOST_DIR}/strata/pre-rebuild-$(date +%Y%m%d-%H%M%S)"
	echo "[2/7] Snapshotting /opt/strata tuning -> ${SNAP_DIR} ..."
	mkdir -p "$SNAP_DIR"
	pct exec "${LXC_ID}" -- tar czf /root/strata-tuning-snap.tgz -C /opt/strata data 2>/dev/null \
		&& pct pull "${LXC_ID}" /root/strata-tuning-snap.tgz "${SNAP_DIR}/strata-data.tgz" 2>/dev/null \
		&& tar xzf "${SNAP_DIR}/strata-data.tgz" -C "$SNAP_DIR" && rm -f "${SNAP_DIR}/strata-data.tgz" \
		&& echo "  expert profile saved: $(ls "$SNAP_DIR"/data/expert-profile.bin 2>/dev/null || echo MISSING)" \
		|| echo "  WARNING: no /opt/strata/data snapshot (engine will re-learn the profile from cold)" >&2
	for _f in strata-iq3_s.json strata-iq3_xxs.json; do
		pct pull "${LXC_ID}" "/opt/strata/${_f}" "${SNAP_DIR}/${_f}" 2>/dev/null || true
	done
	pct pull "${LXC_ID}" /etc/systemd/system/strata.service "${SNAP_DIR}/strata.service" 2>/dev/null || true
	echo "  snapshot: $(du -sh "$SNAP_DIR" 2>/dev/null | awk '{print $1}') in ${SNAP_DIR}"
	confirm "hlh-ai-engine-strata (LXC ${LXC_ID}) already exists. Delete it and redeploy? (its /srv/ai/models/strata packs on ${POOL} and SSD shards on ${SSD_DATASET} survive)"
	echo "[2/7] Deleting existing LXC ${LXC_ID}..."
	pct stop "${LXC_ID}" >/dev/null 2>&1 || true
	pct destroy "${LXC_ID}"
fi

# --- 3/7 Free the V100: stop hlh-ai-engine-egpu (111) ---
if [[ "$KEEP_EGPU_LXC" == "true" ]]; then
	echo "[3/7] Keeping LXC ${EGPU_LXC_ID} running (--keep-111). WARNING: Strata and llama.cpp will share the 32 GB VRAM."
else
	if pct status "${EGPU_LXC_ID}" >/dev/null 2>&1; then
		STATUS_111=$(pct status "${EGPU_LXC_ID}" 2>/dev/null | awk '{print $2}')
		if [ "$STATUS_111" = "running" ]; then
			confirm "Stopping hlh-ai-engine-egpu (LXC ${EGPU_LXC_ID}, llama.cpp) to free the V100's 32 GB VRAM for Strata."
			echo "[3/7] Stopping LXC ${EGPU_LXC_ID}..."
			pct stop "${EGPU_LXC_ID}"
		else
			echo "[3/7] LXC ${EGPU_LXC_ID} is ${STATUS_111} - nothing to stop."
		fi
		echo "[3/7] Setting LXC ${EGPU_LXC_ID} onboot=0 (config kept intact; revert: pct set ${EGPU_LXC_ID} --onboot 1 && pct start ${EGPU_LXC_ID})"
		pct set "${EGPU_LXC_ID}" --onboot 0
	else
		echo "[3/7] LXC ${EGPU_LXC_ID} not found - skipping V100 cutover."
	fi
fi

# --- 4/7 SSD model dataset + Create LXC ---
echo "[4/7] Ensuring SSD model dataset ${SSD_DATASET} (mountpoint ${MODEL_SSD_HOST_DIR})..."
command -v zfs >/dev/null 2>&1 || { echo "ERROR: zfs not found - cannot ensure ${SSD_DATASET}" >&2; exit 1; }
if ! zfs list "$SSD_DATASET" >/dev/null 2>&1; then
	echo "  Creating ${SSD_DATASET} on SSD pool ${SSD_POOL}..."
	zfs create -o mountpoint="$MODEL_SSD_HOST_DIR" "$SSD_DATASET" \
		|| { echo "ERROR: zfs create $SSD_DATASET failed (does SSD pool ${SSD_POOL} exist? override with SSD_POOL=<pool>)" >&2; exit 1; }
fi
mkdir -p "${MODEL_SSD_HOST_DIR}"
# Seed the ${MODEL_QUANT} shard pair onto the SSD (idempotent): skip when already there,
# copy from the HDD model dir when present; otherwise the bootstrap pre-flight
# fatals with a clear missing-shard message.
GGUF_STEM="Qwen3.8-Flash-Next-GSQ-RCO-${MODEL_QUANT}"
# Capacity gate (3phase-tunning.md §3.4): rpool is a 128 GB boot pool with
# ~9.5G avail when the old quant sits on it. Refuse to seed when there is not
# room for the full pair + 8G headroom instead of filling the pool mid-copy.
NEED_BYTES=0
for _i in 00001 00002; do
	_f="${GGUF_STEM}-${_i}-of-00002.gguf"
	if [ ! -s "${MODEL_SSD_HOST_DIR}/${_f}" ] && [ -s "${MODEL_HOST_DIR}/${_f}" ]; then
		_sz=$(stat -c%s "${MODEL_HOST_DIR}/${_f}" 2>/dev/null || echo 0)
		NEED_BYTES=$((NEED_BYTES + _sz))
	elif [ ! -s "${MODEL_SSD_HOST_DIR}/${_f}" ] && [ -s "${MODEL_HOST_DIR}/${MODEL_QUANT}/${_f}" ]; then
		_sz=$(stat -c%s "${MODEL_HOST_DIR}/${MODEL_QUANT}/${_f}" 2>/dev/null || echo 0)
		NEED_BYTES=$((NEED_BYTES + _sz))
	fi
done
if [ "$NEED_BYTES" -gt 0 ]; then
	AVAIL_BYTES=$(zfs get -Hp -o value available "$SSD_DATASET" 2>/dev/null || echo 0)
	MIN_BYTES=$((NEED_BYTES + 8 * 1024 * 1024 * 1024))
	if [ "$AVAIL_BYTES" -lt "$MIN_BYTES" ]; then
		echo "ERROR: not enough space on ${SSD_DATASET} to seed ${MODEL_QUANT} (need $(numfmt --to=iec "$NEED_BYTES") + 8G headroom, avail $(numfmt --to=iec "$AVAIL_BYTES")). Delete the old quant from ${MODEL_SSD_HOST_DIR} first." >&2
		exit 1
	fi
fi
for _i in 00001 00002; do
	_f="${GGUF_STEM}-${_i}-of-00002.gguf"
	if [ -s "${MODEL_SSD_HOST_DIR}/${_f}" ]; then
		echo "  SSD shard present: ${_f}"
	elif [ -s "${MODEL_HOST_DIR}/${_f}" ]; then
		echo "  Seeding ${_f} from ${MODEL_HOST_DIR} (HDD -> SSD, a few minutes)..."
		if command -v rsync >/dev/null 2>&1; then
			rsync -a --info=progress2 "${MODEL_HOST_DIR}/${_f}" "${MODEL_SSD_HOST_DIR}/${_f}"
		else
			cp "${MODEL_HOST_DIR}/${_f}" "${MODEL_SSD_HOST_DIR}/${_f}"
		fi
	elif [ -s "${MODEL_HOST_DIR}/${MODEL_QUANT}/${_f}" ]; then
		echo "  Seeding ${_f} from ${MODEL_HOST_DIR}/${MODEL_QUANT} (HDD -> SSD, a few minutes)..."
		if command -v rsync >/dev/null 2>&1; then
			rsync -a --info=progress2 "${MODEL_HOST_DIR}/${MODEL_QUANT}/${_f}" "${MODEL_SSD_HOST_DIR}/${_f}"
		else
			cp "${MODEL_HOST_DIR}/${MODEL_QUANT}/${_f}" "${MODEL_SSD_HOST_DIR}/${_f}"
		fi
	else
		echo "WARNING: ${_f} found on neither ${MODEL_SSD_HOST_DIR} nor ${MODEL_HOST_DIR} - bootstrap will fatal unless shards are provided" >&2
	fi
done
echo "[4/7] Creating privileged Ubuntu LXC (${LXC_ID}, ${LXC_NAME}) on ${POOL}..."
mkdir -p "${MODEL_HOST_DIR}"
chown 0:0 "${MODEL_HOST_DIR}"
chmod 755 "${MODEL_HOST_DIR}"
pct create "${LXC_ID}" "${LXC_IMAGE}" \
	--storage "${POOL}" \
	--rootfs "${LXC_ROOTFS_SIZE}" \
	--hostname "${LXC_HOSTNAME}" \
	--memory "${LXC_MEMORY}" \
	--cores "${LXC_CORES}" \
	--swap "${LXC_SWAP}" \
	--features nesting=1,keyctl=1,fuse=1 \
	--net0 name=eth0,bridge=vmbr0,ip=${LXC_IP_CONFIG},gw=${LXC_GATEWAY} \
	--unprivileged 0 \
	--onboot 1 \
	--mp0 "${MODEL_HOST_DIR},mp=${MODEL_LXC_DIR}" \
	--mp1 "${MODEL_SSD_HOST_DIR},mp=${MODEL_SSD_LXC_DIR}" \
	--description "${LXC_DESC}"

# --- 5/7 V100 CUDA passthrough ---
echo "[5/7] Adding V100 CUDA passthrough (single GV100 32GB + UVM)..."
# V100 presents as single PCI device c5:00.0 (10de:1df0) IOMMU 20. LXC passthrough via /dev, not hostpci.
# Host /dev/nvidia* is created by nvidia driver after modprobe; expose via cgroup + bind-mount.
# If host uses dynamic UVM major (507/511), covers both. nvidia-modeset is 195:254.
cat >> "/etc/pve/lxc/${LXC_ID}.conf" <<'LXCCONF'

# V100 Tesla GV100 32GB (cc 7.0) — CUDA + driver 580 pinned (R580 last for Volta), single GPU
# c5:00.0 (10de:1df0) via OCuLink 00:03.1 GPP x4; IOMMU group 20
# Expose single chip as nvidia0 plus control nodes (CUDA)
# UVM major is dynamic: 507 (470) / 508 (580) / 511 (caps) - allow all
lxc.cgroup2.devices.allow: c 195:* rwm
lxc.cgroup2.devices.allow: c 507:* rwm
lxc.cgroup2.devices.allow: c 508:* rwm
lxc.cgroup2.devices.allow: c 510:* rwm
lxc.cgroup2.devices.allow: c 511:* rwm
lxc.mount.entry: /dev/nvidia0 dev/nvidia0 none bind,optional,create=file
lxc.mount.entry: /dev/nvidiactl dev/nvidiactl none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm dev/nvidia-uvm none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-uvm-tools dev/nvidia-uvm-tools none bind,optional,create=file
lxc.mount.entry: /dev/nvidia-modeset dev/nvidia-modeset none bind,optional,create=file
LXCCONF

# --- 6/7 Start + bootstrap ---
echo "[6/7] Starting LXC ${LXC_ID}..."
pct start "${LXC_ID}"
sleep 5

if [[ "$NO_BOOTSTRAP" == "true" ]]; then
	echo "[6/7] Skipping bootstrap (--no-bootstrap). Run later:"
	echo "  ./configure-hlh-ai-engine-strata.sh"
else
	echo "[6/7] Running in-container Strata bootstrap (CUDA $CUDA_MAJOR, sm_70 EXPERIMENTAL, $MODEL_QUANT from local SSD shards, vision $VISION_MODE)..."
	echo "      This is the long step: engine compile ~10-40 min + pack from SSD shards (no model download)"
	if [[ "$VISION_MODE" != "no" ]]; then
		echo "      + image encoder: mmproj-Qwen3.8-Flash-Next-BF16.gguf (0.9 GB download) + strata-vision compile ~10-20 min."
	fi
	pct exec "${LXC_ID}" -- mkdir -p /root/strata-bootstrap
	pct push "${LXC_ID}" "$BOOTSTRAP_SCRIPT" /root/strata-bootstrap/configure-hlh-ai-engine-strata.sh --perms 0755
	pct push "${LXC_ID}" "/usr/bin/nvidia-smi" "/tmp/nvidia-smi" --perms 0755
	# Forward the quant + vision mode: the pushed script re-parses its own argv
	# inside the CT, so without these a --model IQ3_XXS seed is followed by an
	# IQ3_S pack and --vision is silently lost (the pre-0.5.0 text-only install).
	BOOT_ARGS=(--bootstrap-inside --model "$MODEL_QUANT" --vision "$VISION_MODE")
	if [ -n "$VISION_TOKENS" ]; then
		BOOT_ARGS+=(--vision-tokens "$VISION_TOKENS")
		echo "      + --vision-tokens ${VISION_TOKENS} (max tokens per picture)."
	fi
	pct exec "${LXC_ID}" -- bash /root/strata-bootstrap/configure-hlh-ai-engine-strata.sh "${BOOT_ARGS[@]}"
fi

# --- 7/7 Verify + summary ---
echo "[7/7] Verifying..."
if [[ "$NO_BOOTSTRAP" != "true" ]]; then
	pct exec "${LXC_ID}" -- systemctl is-active strata >/dev/null 2>&1 || {
		echo "ERROR: strata.service not active after bootstrap - check: pct exec ${LXC_ID} -- journalctl -u strata -n 100" >&2
		exit 1
	}
	# IQ2_XS loads ~35.5 GB of experts into RAM + VRAM at start: 1-3 min, longer the first time.
	if pct exec "${LXC_ID}" -- curl -fsS -m 5 http://127.0.0.1:80/health >/dev/null 2>&1; then
		echo "  /health OK"
	else
		echo "WARNING: strata active but /health not ready yet (model load can take several minutes) - check: pct exec ${LXC_ID} -- journalctl -u strata -f" >&2
	fi
	# Vision gate: /health carries "images": true|false. Say it here rather than
	# letting it surface as a client-side "started without the vision encoder".
	if [[ "$VISION_MODE" != "no" ]]; then
		_HEALTH="$(pct exec "${LXC_ID}" -- curl -fsS -m 5 http://127.0.0.1:80/health 2>/dev/null || true)"
		case "$_HEALTH" in
			*'"images": true'*|*'"images":true'*)
				echo "  Vision OK     : /health reports images=true (encoder ${VISION_MODE})" ;;
			'')
				echo "WARNING: could not read /health to confirm the image encoder - check: curl -s http://127.0.0.1:80/health" >&2 ;;
			*)
				echo "WARNING: --vision ${VISION_MODE} but /health does not report images=true - images will be refused. Check the encoder start in /opt/strata/strata-*.log (VRAM: the GPU encoder wants ~1.2 GB beside the 128K KV)." >&2 ;;
		esac
	fi
fi

echo ""
echo "Deployment complete. LXC ${LXC_ID} (${LXC_NAME}) at ${LXC_IP_CONFIG%%/*}."
echo "  Strata web UI + API : http://192.168.1.15:80   (OpenAI /v1, Anthropic /v1/messages)"
echo "  Model shards (SSD)  : ${MODEL_SSD_HOST_DIR} (${SSD_DATASET}) <-> ${MODEL_SSD_LXC_DIR} (LXC)"
echo "  Model packs         : ${MODEL_HOST_DIR}/strata (host) <-> ${MODEL_LXC_DIR}/strata (LXC) on ${POOL}"
echo "  Image encoder       : vision ${VISION_MODE} (mmproj-Qwen3.8-Flash-Next-BF16.gguf in ${MODEL_LXC_DIR}/strata/models, helper /opt/strata/engine-cuda12/strata-vision)"
echo "  Strata source       : /opt/strata (pinned commit; engine in /opt/strata/engine-cuda12 - setup.py names the dir after the CUDA toolkit, and sm_70 requires 12.x)"
echo "  V100 freed from     : LXC ${EGPU_LXC_ID} (hlh-ai-engine-egpu, stopped, onboot 0, config intact)"
echo "  Host driver pinned  : $NVIDIA_DRIVER_VERSION_SHORT (branch $DRIVER_BRANCH) CUDA $CUDA_MAJOR Volta V100 32GB sm70"
echo "  Shell into the CT   : ssh root@${LXC_IP_CONFIG%%/*} (root password; PermitRootLogin yes) - or pct exec ${LXC_ID} from prox01"
echo "Verify inside LXC: nvidia-smi -L && systemctl status strata && curl -s http://127.0.0.1:80/health"
