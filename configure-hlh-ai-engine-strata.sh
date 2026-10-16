#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LXC_ID=115
LXC_IP="192.168.1.15"

usage() {
	cat <<'EOF'
Usage:
	./configure-hlh-ai-engine-strata.sh [--lxc-id ID] [--host HOST] [--model M] [--gguf-dir DIR]
	                                   [--vision gpu|cpu|no] [--vision-tokens N]
	                                   [--bootstrap-inside]

Strata path (Qwen3.8-Flash-Next IQ3_S on Tesla V100 GV100GL 32GB via OCuLink) - CUDA:
	- host driver 580.65.06 (R580, last for Volta) already installed by
	  deploy-hlh-ai-engine-strata.sh (or hlh-ai-engine-egpu's)
	- container: CUDA $CUDA_MAJOR (sm_70 requires CUDA 12.x; 13 dropped sm_70) +
	  driver-branch userspace 580.65.06 (apt-pinned to the host kernel driver)
	- Strata at pinned commit (engine built -DSTRATA_EXPERIMENTAL_SM60=ON, sm_70
	  community path, Strata #295/#236)
	- model install (default IQ3_S from LOCAL GGUF shards in /srv/ssd-models (SSD
	  bind, mp1; no ~84 GB download + pack) into /srv/ai/models/strata (shared host
	  mount), 128K context, k8v4 KV, vision ON (GPU encoder)
	- systemd strata.service on port 80 (web UI + OpenAI /v1 + Anthropic /v1/messages)

Options:
	--model M      Q2_0 | IQ2_XS | IQ3_XXS | IQ3_S (default, Strata's sizes for
	               Qwen3.8-Flash-Next). IQ3_XXS/IQ3_S experts (42.9/50.3 GB) do not
	               fit 48 GB RAM + 10 GB beside in normal mode, so setup's
	               --low-ram auto switches them to low-RAM mode: the 32 GB card
	               holds the hot experts, RAM the rest.
	--gguf-dir DIR use GGUF shards already in DIR (default /srv/ssd-models, the
	               SSD bind mp1 - RaidZ1 HDD reads were too slow for the 78 GB
	               pair; pass --gguf-dir /srv/ai/models to use the HDD copies)
	               instead of downloading them (needs every shard:
	               Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf (52G) and
	               -00002-of-00002.gguf (27G) from ISTA-DASLab/
	               Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S; the ~5 GB MTP draft
	               layer is still fetched)
	--vision V     gpu | cpu | no (default gpu - images work).
	               gpu: setup downloads mmproj-Qwen3.8-Flash-Next-BF16.gguf
	               (0.9 GB, 27-layer ViT + projector) into
	               <data-dir>/models = /srv/ai/models/strata/models (mp0, HDD -
	               NOT the SSD dataset) and compiles the strata-vision helper
	               with CUDA at the same sm_70 archs as the engine (~10-20 min
	               extra). The encoder holds ~1.2 GB of the 32 GB card at 1024
	               image tokens, so ~1,000 fewer expert slots: upstream measures
	               2-8% slower text. Volta has no upstream vision report - see
	               README "Vision (images)".
	               cpu: no VRAM cost (the expert cache keeps every slot), about
	               3 s per picture at 300 tokens, and it competes with
	               --pool-workers 10 on these 12 cores.
	               no: text only (the pre-0.5.0 behaviour).
	--vision-tokens N  most tokens one picture becomes (setup default: 1024 on
	               gpu, 300 on cpu). Lower it if the encoder does not fit
	               beside the 128K KV + expert cache.
	--allowed-hosts LIST  comma-separated Host names the server accepts
	               (default: hlh-ai-engine-strata.mizertech.net). Strata's
	               DNS-rebinding guard 403s any Host: header it does not know;
	               loopback, the bind address, IPs and the container's short
	               hostname always pass, the FQDN does not. Accepts .example.com
	               (that name and everything below) and * (check off). Pass "" to
	               leave setup.sh's default (no allowed_hosts key).

Host side (default): pushes this script into LXC and runs it with --bootstrap-inside.
--bootstrap-inside: run the bootstrap directly inside the LXC (called by the deploy
	script or manually: pct exec 115 -- bash /root/strata-bootstrap/configure-hlh-ai-engine-strata.sh --bootstrap-inside).
EOF
}

# --- PINNED VERSIONS (V100 Volta cc 7.0) ---
# R580 580.65.06 = last driver supporting Volta (host kernel driver, installed via .run --dkms).
# CUDA 12.8 = final toolkit with sm_70 (CUDA 13 dropped sm_60/sm_70; Strata needs CUDA 12.x).
# Strata: v0.1.43 - the sm_70 experimental path is unchanged (STRATA_EXPERIMENTAL_SM60=1,
# CUDA 12.x source build; still present in 0.1.43 setup.py#experimental_sm60 and the
# CMakeLists STRATA_EXPERIMENTAL_SM60 option). Chosen over 0.1.41 for decode: 0.1.42 is
# +13-16% decode on one NVIDIA GPU (up to +30% where the CPU outruns PCIe - this board's
# V100-over-OCuLink case), 0.1.43 adds +5-11% on Tesla P100 / RTX 30-series under Linux.
# CAVEAT: 0.1.42 turned on two NVIDIA defaults that change answers slightly -
# STRATA_ROUTE_TAIL_SKIP=7 (skip experts ranked 7th+ in every window of a miss) and the
# measured PCIe share. Set STRATA_ROUTE_TAIL_SKIP=0 and STRATA_PCIE_FRAC_DEFAULT=old in
# the unit's Environment= lines to get 0.1.41-identical answers at the cost of the speed.
# Also carries: RAM-resident prompts #1353, under-RAM Linux decode #1194, the hung-engine
# watchdog #1317/#1407, the quoted-tool-call security fix (0.1.40.1).
CUDA_VERSION="${CUDA_VERSION:-12.8.0-1}"
CUDA_MAJOR="${CUDA_MAJOR:-12.8}"
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-580.65.06}"
DRIVER_BRANCH="${DRIVER_BRANCH:-580}"
STRATA_REPO="https://github.com/Niko1221/Strata.git"
STRATA_VERSION="${STRATA_VERSION:-0.1.43}"
STRATA_COMMIT="${STRATA_COMMIT:-7695859aa13afb248bdb4d36f9b2e95707db079d}"   # 0.1.43
STRATA_DIR="/opt/strata"
STRATA_MODEL_DIR="/srv/ai/models/strata"
MODEL_FAMILY="qwen"
# Exact model under test (on disk in /srv/ssd-models (SSD bind), no download):
# ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF:IQ3_S
#   Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00001-of-00002.gguf (52G, 54817524224 B)
#   Qwen3.8-Flash-Next-GSQ-RCO-IQ3_S-00002-of-00002.gguf (27G, 28800138432 B)
# (--model/--gguf-dir override both; the merged 78G single file is for llama.cpp,
# Strata's --gguf-dir takes the split pair, not the merged file.)
MODEL_NAME="${MODEL_NAME:-IQ3_S}"        # --model: Q2_0 | IQ2_XS | IQ3_XXS | IQ3_S
MODEL_TAG="$(printf '%s' "$MODEL_NAME" | tr '[:upper:]' '[:lower:]')"
# Learned expert profile: on the model dataset (mp0), NOT under /opt/strata.
# /opt/strata is the container rootfs, so `pct destroy` deletes whatever the engine
# learned from real traffic (94.8% decode hit rate vs ~87% cold, days to re-learn);
# the model dataset survives. One subdirectory per quant, because the profile is
# quant-specific routing and IQ3_S / IQ3_XXS must not overwrite each other (both
# configs pointed at the same file until 2026-10-12).
# Placement costs nothing: the file is ~192 KB and is read exactly once at startup
# (0.1.43 generate.cpp:3309/3492) into RAM, never per token. Only the 78 GB GGUF
# shard pair needs the SSD - see 3phase-tunning.md.
PROFILE_DIR="$STRATA_MODEL_DIR/data/$MODEL_TAG"
PROFILE_PATH="$PROFILE_DIR/expert-profile.bin"
# Shards default to the SSD bind (mp1, host rpool/strata-models -> /strata-models).
# RaidZ1-6TB HDD reads of the 78 GB pair were too slow; SSD validated live 2026-10-09.
GGUF_DIR="${GGUF_DIR:-/srv/ssd-models}"  # --gguf-dir: local GGUF shards, no model download
STRATA_CONTEXT="131072"      # 128K - required (16K is unusable for this workload)
# Phase 1 tuning (3phase-tunning.md, 2026-10-11): k8v4 = INT8 K (exact attention
# scores) + rotated Q4_0 V, 816 vs 1056 B/cell - frees ~23% of the 128K KV for
# expert cache slots. setup.sh accepts int8|q4_0|k8v4.
STRATA_KV="k8v4"
# Vision is ON by default since 0.5.0. setup.sh then (a) downloads the 0.9 GB
# mmproj-Qwen3.8-Flash-Next-BF16.gguf into <data-dir>/models (mp0 HDD, not the
# SSD dataset) and (b) compiles strata-vision from llama.cpp's mtmd with
# -DSTRATA_VISION_CUDA=ON at the same CMAKE_CUDA_ARCHITECTURES as the engine,
# i.e. sm_70 on the CUDA 12.8 toolkit (setup.py: build in build-vision-cuda12/,
# installed next to the engine in engine-cuda12/ - engine_dir() picks that folder
# for toolkit 12, which is what sm_70 requires).
# Cost on this card: the encoder holds ~1.2 GB at 1024 image tokens, so the
# expert cache loses ~1,000 slots (upstream: 2-8% slower text; here the hit
# rate is the decode lever, so watch it in strata-iq3_s.log). --vision cpu
# keeps every slot and pays ~3 s/picture on cores the expert pool also wants.
STRATA_VISION="gpu"
STRATA_VISION_TOKENS=""   # --vision-tokens: empty = setup's default (1024 gpu / 300 cpu)
MMPROJ_NAME="mmproj-Qwen3.8-Flash-Next-BF16.gguf"   # 907,543,008 B, ISTA-DASLab
STRATA_PORT="80"
STRATA_HOST="0.0.0.0"
STRATA_GPU="0"
# DNS-rebinding guard (serve/server.py host_names_for/allowed_hosts_of): every
# request's Host: header must be loopback, the bind address, an IP,
# socket.gethostname() or one of allowed_hosts. In this CT gethostname() is the
# SHORT name (hlh-ai-engine-strata), so the FQDN clients and the README actually
# use (hostname -f = hlh-ai-engine-strata.mizertech.net) was refused:
# 403 {"type":"forbidden","message":"Host '...' is not allowed"} while
# http://192.168.1.15/ worked. Comma-separated; "" = leave setup.sh's default
# (no allowed_hosts key). server.py also accepts "*" (check off) and
# ".example.com" (that name plus everything below it), and strips a scheme,
# port or path from an entry.
STRATA_ALLOWED_HOSTS="${STRATA_ALLOWED_HOSTS:-hlh-ai-engine-strata.mizertech.net}"

BOOTSTRAP_INSIDE=false
HOST_IP="$LXC_IP"
TARGET_LXC_ID="$LXC_ID"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--lxc-id) TARGET_LXC_ID="$2"; shift 2 ;;
		--host) HOST_IP="$2"; shift 2 ;;
		--model) MODEL_NAME="$2"; shift 2 ;;
		--gguf-dir) GGUF_DIR="$2"; shift 2 ;;
		--vision) STRATA_VISION="$2"; shift 2 ;;
		--vision-tokens) STRATA_VISION_TOKENS="$2"; shift 2 ;;
		--allowed-hosts) STRATA_ALLOWED_HOSTS="$2"; shift 2 ;;
		--bootstrap-inside) BOOTSTRAP_INSIDE=true; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "ERROR: Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done
case "$STRATA_VISION" in
	yes) STRATA_VISION="gpu" ;;   # setup.sh accepts yes/no too; we keep gpu/cpu/no
	gpu|cpu|no) ;;
	*) echo "ERROR: --vision must be gpu | cpu | no (got: $STRATA_VISION)" >&2; exit 1 ;;
esac
if [ -n "$STRATA_VISION_TOKENS" ] && ! [[ "$STRATA_VISION_TOKENS" =~ ^[0-9]+$ ]]; then
	echo "ERROR: --vision-tokens takes a number of tokens, e.g. 768 (got: $STRATA_VISION_TOKENS)" >&2; exit 1
fi
# Validate the Host allow-list here, not 60 minutes later: allowed_hosts_of() in
# server.py raises ValueError on a bad entry, and the server then refuses to
# start at all.
if [ -n "$STRATA_ALLOWED_HOSTS" ]; then
	if [[ "$STRATA_ALLOWED_HOSTS" =~ [[:space:]] ]]; then
		echo "ERROR: --allowed-hosts is a comma-separated list with no spaces (got: $STRATA_ALLOWED_HOSTS)" >&2; exit 1
	fi
	_OLDIFS="$IFS"; IFS=,; read -r -a _AH <<< "$STRATA_ALLOWED_HOSTS"; IFS="$_OLDIFS"
	for _h in "${_AH[@]}"; do
		if [ -z "$_h" ]; then
			IFS="$_OLDIFS"
			echo "ERROR: --allowed-hosts has an empty entry (got: $STRATA_ALLOWED_HOSTS)" >&2; exit 1
		fi
		if [ "$_h" = "*" ]; then continue; fi
		if [[ ! "$_h" =~ ^\.?[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
			IFS="$_OLDIFS"
			echo "ERROR: --allowed-hosts entry '$_h' is not a host name (bare name, .domain for a suffix, or * for any Host)" >&2; exit 1
		fi
	done
	IFS="$_OLDIFS"
fi
VISION_LABEL="vision off"
if [ "$STRATA_VISION" = "gpu" ]; then VISION_LABEL="vision on, GPU encoder"; fi
if [ "$STRATA_VISION" = "cpu" ]; then VISION_LABEL="vision on, CPU encoder"; fi

# --- Inside-container bootstrap ---
if $BOOTSTRAP_INSIDE; then
	set -euo pipefail

	log() { echo "[strata-bootstrap] $*"; }
	fatal() { log "ERROR: $*" >&2; exit 1; }

	log "Starting in-container bootstrap for Strata (CUDA $CUDA_MAJOR, sm_70 EXPERIMENTAL)..."

	# --- 1/6 Base deps + CUDA $CUDA_MAJOR + driver-branch userspace (apt-pinned) ---
	log "[1/6] Installing base deps + CUDA $CUDA_MAJOR + driver-branch userspace..."
	export DEBIAN_FRONTEND=noninteractive
	# Repair stale NVIDIA CUDA apt repo (from the K80/CUDA 11.8 era of this slot)
	for f in /etc/apt/sources.list.d/nvidia-*.list /etc/apt/sources.list.d/nvidia-*.sources; do
		[ -f "$f" ] && { log "  - Removing stale CUDA apt source: $f"; rm -f "$f"; }
	done
	rm -rf /etc/apt/keyrings/nvidia*.gpg 2>/dev/null || true
	apt-get update
	apt-get install -y ca-certificates wget curl gnupg
	apt-get install -y --no-install-recommends \
		build-essential git cmake pkg-config \
		python3 python3-venv python3-pip python3-dev \
		unzip bc libopenblas-dev libssl-dev \
		openssh-server nvtop
	# CUDA $CUDA_MAJOR repo (noble = ubuntu2404; CUDA 12.x = last with sm_70)
	if [ ! -f /etc/apt/keyrings/cuda.gpg ]; then
		# Noble repo key: verified to sign the ubuntu2404 repo's InRelease
		# ("cudatools <cudatools@nvidia.com>"). The old URL
		# /compute/cuda/<major>/keys/cuda-<major>_prod.asc 404s, and `wget -q`
		# under set -euo pipefail then died with ZERO output (silent crash).
		wget -q "https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub" -O /tmp/cuda_prod.asc \
			|| fatal "failed to download CUDA GPG key from https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/3bf863cc.pub"
		gpg --dearmor --yes --output /etc/apt/keyrings/cuda.gpg /tmp/cuda_prod.asc
		rm -f /tmp/cuda_prod.asc
		echo "deb [signed-by=/etc/apt/keyrings/cuda.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /" > /etc/apt/sources.list.d/cuda.list
		apt-get update
	fi
	log "  - Installing CUDA $CUDA_MAJOR (sm_70 supported; CUDA 13 dropped Volta)"
	# Debian package name uses dashes, not dots: cuda-toolkit-12-8 (not cuda-toolkit-12.8)
	apt-get install -y "cuda-toolkit-${CUDA_MAJOR//./-}=${CUDA_VERSION}"
	# Driver-branch userspace, pinned to the host kernel driver. R580 (580.65.06) is the
	# last branch for Volta; the host was installed via .run --dkms. The CUDA ubuntu2404
	# repo carries several 580 point releases (580.65.06-0ubuntu1 ... 580.126.09-1ubuntu1),
	# so resolve the repo version whose base matches the host driver base and FATAL if it
	# is not there (NVML requires userspace base == host kernel driver base).
	BRANCH_PKGS=(
		"libnvidia-compute-${DRIVER_BRANCH}"
		"libnvidia-cfg1-${DRIVER_BRANCH}"
		"libnvidia-decode-${DRIVER_BRANCH}"
		"libnvidia-gpucomp-${DRIVER_BRANCH}"
		"nvidia-utils-${DRIVER_BRANCH}"
		"nvidia-persistenced"
	)
	log "  - Pinning userspace branch $DRIVER_BRANCH to host kernel driver $NVIDIA_DRIVER_VERSION (6 packages, persistenced kept: libnvidia-compute Depends on it)"
	RESOLVED_US="$(apt-cache madison "libnvidia-compute-${DRIVER_BRANCH}" 2>/dev/null | awk -F'|' -v v="${NVIDIA_DRIVER_VERSION}" '{gsub(/[ \t]/,"",$2); if (index($2, v "-")==1) {print $2; exit}}' || true)"
	if [ -z "$RESOLVED_US" ]; then
		log "  Available ${DRIVER_BRANCH} userspace in CUDA repo:"
		apt-cache madison "libnvidia-compute-${DRIVER_BRANCH}" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print "    ", $2}' | head -10 || true
		fatal "no ${NVIDIA_DRIVER_VERSION} userspace in CUDA ubuntu2404 repo (host driver ${NVIDIA_DRIVER_VERSION}); if the repo rotated, upgrade the host driver to the current 580 tip and re-run"
	fi
	log "  - Resolved $DRIVER_BRANCH userspace: $RESOLVED_US (base matches host driver $NVIDIA_DRIVER_VERSION)"
	# Clean broken NVML symlinks left by the pre-1.0.3 bootstrap (it created
	# .so.1 -> .so backwards, and a .so.<ver> -> .so link shadowing the real lib).
	# Only remove symlinks, never the real library file: on a healthy system
	# libnvidia-ml.so.<ver> is a regular file and .so.1 -> .so.<ver> is correct.
	if [ -L /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 ] && [ ! -e /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 ]; then
		rm -f /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>/dev/null || true
	fi
	if [ -L "/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.${NVIDIA_DRIVER_VERSION}" ]; then
		rm -f "/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.${NVIDIA_DRIVER_VERSION}" 2>/dev/null || true
	fi
	apt-mark unhold "${BRANCH_PKGS[@]}" 2>/dev/null || true
	if ! apt-get install -y --allow-downgrades --no-install-recommends \
		"libnvidia-compute-${DRIVER_BRANCH}=${RESOLVED_US}" \
		"libnvidia-cfg1-${DRIVER_BRANCH}=${RESOLVED_US}" \
		"libnvidia-decode-${DRIVER_BRANCH}=${RESOLVED_US}" \
		"libnvidia-gpucomp-${DRIVER_BRANCH}=${RESOLVED_US}" \
		"nvidia-utils-${DRIVER_BRANCH}=${RESOLVED_US}" \
		"nvidia-persistenced=${RESOLVED_US}" 2>&1 | tail -n 30; then
		fatal "pinned userspace ${RESOLVED_US} install failed (host driver ${NVIDIA_DRIVER_VERSION}) - do NOT fall back to unpinned: NVML needs the base version to match"
	fi
	# KEEP nvidia-persistenced installed but disabled. libnvidia-compute-580
	# Depends: nvidia-persistenced, so `apt-get remove` also removes
	# libnvidia-compute + libnvidia-decode (which provide libnvidia-ml.so.1)
	# and upgrades the remaining 580 packages to the repo tip (observed:
	# 580.65.06 -> 580.178.04 + compute/decode removed -> nvidia-smi
	# "couldn't find libnvidia-ml.so"). Disabling the service is sufficient in
	# an LXC (the host owns persistence mode).
	systemctl disable --now nvidia-persistenced 2>/dev/null || true
	apt-mark hold "${BRANCH_PKGS[@]}" 2>/dev/null || true
	# FATAL gate: EVERY pinned userspace package base must match the host kernel
	# driver base (NVML requirement). Checking only libnvidia-compute masked the
	# 2026-10-09 failure where compute stayed 580.65.06 while cfg1/gpucomp/utils
	# drifted to 580.178.04.
	for _pkg in "${BRANCH_PKGS[@]}"; do
		_us_ver=$(dpkg-query -W -f='${Version}' "$_pkg" 2>/dev/null || echo "missing")
		_us_stat=$(dpkg-query -W -f='${Status}' "$_pkg" 2>/dev/null || echo "missing")
		case "$_us_ver" in
			"${NVIDIA_DRIVER_VERSION}-"*) ;;
			*) fatal "FATAL: ${_pkg}=${_us_ver} but host kernel driver is $NVIDIA_DRIVER_VERSION (NVML version mismatch; all 580 userspace must share the base)" ;;
		esac
		case "$_us_stat" in
			*"ok installed"*) ;;
			*) fatal "FATAL: ${_pkg} status is '${_us_stat}' (not fully installed; NVML libs missing)" ;;
		esac
	done
	US_VER=$(dpkg-query -W -f='${Version}' "libnvidia-compute-${DRIVER_BRANCH}" 2>/dev/null || echo "missing")
	log "  - Userspace $US_VER matches host kernel driver $NVIDIA_DRIVER_VERSION (NVML exact-base match required, all 6 packages verified)"
	# CUDA env for the user (systemd unit also sets it explicitly)
	cat > /etc/profile.d/cuda.sh <<CUDAEOF
export PATH=/usr/local/cuda-${CUDA_MAJOR}/bin:\$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-${CUDA_MAJOR}/lib64:\$LD_LIBRARY_PATH
CUDAEOF
	# nvidia-smi: prefer the deb's binary (nvidia-utils-580, same pinned base as
	# libnvidia-ml.so.1). The host .run binary pushed to /tmp/nvidia-smi is only
	# a fallback for a missing/broken deb binary -- blindly overwriting a working
	# deb binary gains nothing (both are 580.65.06 here) and hides version drift.
	if [ ! -x /usr/bin/nvidia-smi ] && [ -f /tmp/nvidia-smi ]; then
		cp /tmp/nvidia-smi /usr/bin/nvidia-smi
		chmod +x /usr/bin/nvidia-smi
	fi
	# NVML symlinks: dpkg already ships libnvidia-ml.so.1 -> libnvidia-ml.so.<ver>
	# (verified live). Only repair a missing/dangling .so.1, in the correct
	# direction (versioned file is real, .so.1 is the link). Never create
	# .so.1 -> libnvidia-ml.so (bare .so does not exist in the deb layout).
	if [ -f "/usr/lib/x86_64-linux-gnu/libnvidia-ml.so.${NVIDIA_DRIVER_VERSION}" ]; then
		if [ ! -e /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 ]; then
			ln -sf "libnvidia-ml.so.${NVIDIA_DRIVER_VERSION}" /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>/dev/null || true
		fi
		ldconfig 2>/dev/null || true
	fi

	# --- SSH: let root in with a password (openssh-server was installed above) ---
	# Ubuntu's sshd default is PermitRootLogin prohibit-password, so root's password
	# is refused even though PasswordAuthentication is yes - and the bootstrap never
	# installs an authorized_keys, which left a rebuilt CT with NO working SSH path
	# at all (verified live 2026-10-16: "Permission denied (publickey,password)",
	# /root/.ssh empty, PermitRootLogin without-password). The documented path was
	# always prox01 + `pct exec 115`, but `ssh root@192.168.1.15` is what the
	# runbooks and muscle memory expect. Exposure is the LAN only (no port-forward,
	# no public name) - the same trust boundary as the :80 endpoint.
	# A drop-in, not an edit of sshd_config: sshd_config.d/*.conf is Included at the
	# top of the main file (line 12) so it wins, and apt keeps owning sshd_config.
	# Same file name as lab-opskit/create-lxc.sh and hlh-ai-engine-vllm so every
	# LXC on the LAN is configured the same way.
	#
	# Do NOT gate on a bare `sshd -t`. ssh.service has RuntimeDirectory=sshd, so
	# while the service is stopped /run/sshd does not exist and the test fails for
	# a reason unrelated to this file. dpkg stops ssh (and ssh.socket) mid-way
	# through the apt install above - an earlier run deleted a perfectly good
	# drop-in that way and the CT came back key-only. So: create the runtime dir
	# first, and if the config still fails, work out whether the drop-in is really
	# the cause before removing it.
	SSHD_DROPIN="/etc/ssh/sshd_config.d/99-root-login.conf"
	rm -f /etc/ssh/sshd_config.d/60-root-password.conf 2>/dev/null || true
	ssh-keygen -A >/dev/null 2>&1 || true     # host keys, if the template has none yet
	mkdir -p /etc/ssh/sshd_config.d /run/sshd
	cat > "$SSHD_DROPIN" <<SSHEOF
# Managed by configure-hlh-ai-engine-strata.sh / deploy-hlh-ai-engine-strata.sh - do not edit in place.
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
SSHEOF
	chmod 0644 "$SSHD_DROPIN"
	if ! sshd -t >/dev/null 2>&1; then
		if mv "$SSHD_DROPIN" "${SSHD_DROPIN}.off" 2>/dev/null; then
			if sshd -t >/dev/null 2>&1; then
				mv "${SSHD_DROPIN}.off" "$SSHD_DROPIN"
				rm -f "$SSHD_DROPIN"
				log "  WARNING: sshd rejects the drop-in - SSH stays at Ubuntu defaults (root key-only)"
			else
				mv "${SSHD_DROPIN}.off" "$SSHD_DROPIN"
				log "  WARNING: sshd -t fails with AND without the drop-in - kept it, but check: pct exec ${TARGET_LXC_ID} -- sshd -t"
			fi
		fi
	fi
	# dpkg leaves ssh stopped after configuring openssh-server; enable it so the
	# container is still reachable after a reboot.
	systemctl enable ssh >/dev/null 2>&1 || true
	# reset-failed: a previous failed start leaves the unit rate-limited
	# ("start request repeated too quickly"), and then restart refuses to run.
	systemctl reset-failed ssh >/dev/null 2>&1 || true
	if systemctl restart ssh 2>/dev/null || service ssh restart 2>/dev/null; then
		if sshd -T 2>/dev/null | grep -qi '^permitrootlogin yes'; then
			log "  - SSH: PermitRootLogin yes + PasswordAuthentication yes (drop-in sshd_config.d/99-root-login.conf)"
			case "$(passwd -S root 2>/dev/null | awk '{print $2}')" in
				P) log "      root has a password set - ssh root@${LXC_IP} works now" ;;
				*) log "      root has NO usable password - set one: deploy with --root-password, or pct exec ${TARGET_LXC_ID} -- passwd root" ;;
			esac
		else
			log "  WARNING: sshd restarted but PermitRootLogin is not 'yes' - check ${SSHD_DROPIN} and sshd -T"
		fi
	else
		log "  WARNING: could not (re)start ssh.service - the drop-in is in place but needs: pct exec ${TARGET_LXC_ID} -- systemctl restart ssh"
	fi

	# --- 2/6 Verify GPU + nvcc ---
	log "[2/6] Verifying GPU + CUDA toolkit inside container..."
	[ -c /dev/nvidia0 ] || fatal "/dev/nvidia0 missing (GPU passthrough not wired? check deploy [5/7])"
	[ -x /usr/bin/nvidia-smi ] || fatal "nvidia-smi missing"
	if ! nvidia-smi -L 2>&1 | head -n 5; then fatal "nvidia-smi -L failed (driver/userspace mismatch?)" ; fi
	nvidia-smi 2>&1 | head -20 || true
	NVCC=/usr/local/cuda-${CUDA_MAJOR}/bin/nvcc
	[ -x "$NVCC" ] || fatal "nvcc $NVCC missing"
	"$NVCC" --version | grep -q "release ${CUDA_MAJOR}" || fatal "nvcc is not CUDA ${CUDA_MAJOR}"
	"$NVCC" --version | tail -n 1 | sed 's/^/  nvcc: /'
	"$NVCC" -arch=sm_70 --generate-code arch=compute_70,code=sm_70 /dev/null -o /tmp/nvcc70test 2>&1 | head -n 5 || true
	rm -f /tmp/nvcc70test
	log "  GPU + CUDA $CUDA_MAJOR (sm_70) verified inside LXC."

	# --- 3/6 Strata source at pinned commit ---
	log "[3/6] Checking out Strata at pinned commit ${STRATA_COMMIT:0:7} (${STRATA_VERSION})..."
	if [ -d "$STRATA_DIR/.git" ]; then
		git -C "$STRATA_DIR" fetch --depth 1 origin "$STRATA_COMMIT" 2>/dev/null || git -C "$STRATA_DIR" fetch --unshallow 2>/dev/null || true
		git -C "$STRATA_DIR" checkout -q "$STRATA_COMMIT"
		git -C "$STRATA_DIR" clean -fdq 2>/dev/null || true
	else
		rm -rf "$STRATA_DIR"
		git clone --quiet "$STRATA_REPO" "$STRATA_DIR"
		git -C "$STRATA_DIR" checkout -q "$STRATA_COMMIT"
	fi
	log "  Strata: $(git -C "$STRATA_DIR" describe --tags 2>/dev/null || echo "${STRATA_COMMIT:0:12}")"
	mkdir -p "$STRATA_MODEL_DIR"

	# --- 4/6 Strata setup: build engine (sm_70 EXPERIMENTAL) + IQ3_S local install ---
	# This is the long step: venv + pinned deps, llama.cpp fetch, engine compile
	# (~10-40 min on 12 cores), pack from LOCAL GGUF shards (no ~84 GB download;
	# only the ~5 GB MTP draft layer is fetched), config + run script.
	log "[4/6] Strata setup (family=${MODEL_FAMILY} model=${MODEL_NAME} context=${STRATA_CONTEXT} kv=${STRATA_KV} vision=${STRATA_VISION} gpu=${STRATA_GPU} port=${STRATA_PORT})..."
	log "      STRATA_EXPERIMENTAL_SM60=1 -> builds -DSTRATA_EXPERIMENTAL_SM60=ON (Volta sm_70 community path)"
	cd "$STRATA_DIR"
	export STRATA_EXPERIMENTAL_SM60=1
	# Pre-flight: local shards must exist BEFORE the long engine build, or setup
	# would compile for ~40 min and then fail on a missing download. Strata
	# resolves --gguf-dir by exact published first-shard name, then expects every
	# -0000i-of-0000N shard beside it (gguf_dir_shards in setup.py).
	if [ -n "$GGUF_DIR" ]; then
		GGUF_STEM="Qwen3.8-Flash-Next-GSQ-RCO-${MODEL_NAME}"
		for _i in 00001 00002; do
			_shard="${GGUF_DIR}/${GGUF_STEM}-${_i}-of-00002.gguf"
			[ -s "$_shard" ] || fatal "--gguf-dir ${GGUF_DIR} is missing ${_shard##*/} (have: $(ls "$GGUF_DIR" 2>/dev/null | grep -c gguf || echo 0) ggufs; need both -00001-of-00002 and -00002-of-00002 for ${MODEL_NAME}; seed them on the SSD dataset (host: /strata-models, copied by the deploy script) or pass --gguf-dir /srv/ai/models for the HDD copies)"
		done
		log "      local shards OK: $(du -sh "${GGUF_DIR}/${GGUF_STEM}-00001-of-00002.gguf" | awk '{print $1}') + $(du -sh "${GGUF_DIR}/${GGUF_STEM}-00002-of-00002.gguf" | awk '{print $1}') (no model download)"
	fi
	# Vision pre-flight: setup looks for the encoder in <data-dir>/models first, then
	# in --gguf-dir (used in place), and only then downloads it. Say which of the
	# three paths it will take, so a rebuild that has no HF egress is not a surprise.
	if [ "$STRATA_VISION" != "no" ]; then
		if [ -s "$STRATA_MODEL_DIR/models/$MMPROJ_NAME" ]; then
			log "      mmproj already in ${STRATA_MODEL_DIR}/models - no download"
		elif [ -n "$GGUF_DIR" ] && [ -s "$GGUF_DIR/$MMPROJ_NAME" ]; then
			log "      mmproj found in ${GGUF_DIR} - setup reads it in place (no download)"
		else
			log "      mmproj ${MMPROJ_NAME} (0.9 GB) will be downloaded from ISTA-DASLab into ${STRATA_MODEL_DIR}/models"
		fi
	fi
	SETUP_ARGS=(--setup
		--family "$MODEL_FAMILY"
		--model "$MODEL_NAME"
		--context "$STRATA_CONTEXT"
		--kv "$STRATA_KV"
		--vision "$STRATA_VISION"
		--gpu "$STRATA_GPU"
		--port "$STRATA_PORT"
		--host "$STRATA_HOST"
		--data-dir "$STRATA_MODEL_DIR"
		--low-ram auto
		--no-start
		--yes)
	if [ -n "$GGUF_DIR" ]; then
		log "      --gguf-dir ${GGUF_DIR} (using pre-downloaded shards, no model download)"
		SETUP_ARGS+=(--gguf-dir "$GGUF_DIR")
	fi
	if [ "$STRATA_VISION" != "no" ] && [ -n "$STRATA_VISION_TOKENS" ]; then
		log "      --vision-tokens ${STRATA_VISION_TOKENS} (max tokens per picture; setup's default is 1024 on gpu, 300 on cpu)"
		SETUP_ARGS+=(--vision-tokens "$STRATA_VISION_TOKENS")
	fi
	./setup.sh "${SETUP_ARGS[@]}"
	log "  Strata setup complete."

	# --- 5/6 systemd unit ---
	log "[5/6] Installing strata.service (port $STRATA_PORT)..."
	# Config JSON written by setup: /opt/strata/strata-<family-tag><model>.json lowercased
	# (the qwen family tag is empty: IQ2_XS -> strata-iq2_xs.json). Prefer the exact name,
	# fall back to a case-insensitive content match (older checkouts named it differently);
	# *.shared-settings.json (0.1.41+) is the server's chat settings, not a model config.
	EXPECTED_CFG="$STRATA_DIR/strata-$(printf '%s' "$MODEL_NAME" | tr '[:upper:]' '[:lower:]').json"
	CFG_JSON=""
	if [ -f "$EXPECTED_CFG" ]; then
		CFG_JSON="$EXPECTED_CFG"
	else
		for f in "$STRATA_DIR"/strata-*.json; do
			[ -f "$f" ] || continue
			case "$f" in *.shared-settings.json) continue ;; esac
			if grep -qi "$MODEL_NAME" "$f" 2>/dev/null; then CFG_JSON="$f"; break; fi
		done
	fi
	[ -n "$CFG_JSON" ] || fatal "no Strata config for ${MODEL_NAME} found in $STRATA_DIR (setup did not finish?)"
	log "  Using config: $CFG_JSON"

	# --- Phase 1+2 tuning flags (3phase-tunning.md) ---
	# setup.sh writes the base args; these engine flags are NOT setup.sh options,
	# so patch them into the config JSON's args array (idempotent):
	# Phase 1:
	#   --kv-grow                 KV takes VRAM only for cells requests actually
	#                             reach (typ. ~30k, not the 131k cap) -> slots back
	#                             to the expert cache (needs --expert-profile;
	#                             engine may auto-off it on this config - harmless)
	#   --prefill auto:16384      bigger prompt chunks amortize expert streaming
	#                             over more rows (2-4x prefill expected)
	#   --adapt-async 1           RAM<->VRAM expert swaps advance between verify
	#                             windows instead of blocking one (not bit-exact)
	#   --expert-profile-save     learn the VRAM tier from real routing; saved on
	#                             QUIT and every 10 min between requests, then
	#                             pre-filled at start via the existing --expert-profile
	# Phase 2:
	#   --pool-workers 10         CPU expert pool: default picked 8 workers + host
	#                             on the 12-core allocation; 10 serves cache misses
	#                             faster (host thread drains too = 11 on 12 cores)
	#   --lookup-chain 2          after MTP drafts, add up to 2 prompt-lookup
	#                             drafts; window grows to 8 where repeats are likely
	#   --prompt-cache-tail       one extra checkpoint near the prompt's end
	#                             (needs --prompt-cache + --prompt-cache-every,
	#                             both on by default: 6 / 16384)
	#   --conversation-cache-mib  park conversation state in RAM for fast session
	#                             restore (default 0 = off). 4096, not the doc's
	#                             8192: CT is 57 GB with ~29.3 pinned + runtime;
	#                             8 GB would squeeze the expert page cache.
	log "  Applying Phase 1+2 tuning flags to $CFG_JSON..."
	"$STRATA_DIR/.venv/bin/python" - "$CFG_JSON" "$PROFILE_PATH" "$STRATA_ALLOWED_HOSTS" <<'PYEOF'
import json, sys
p, profile, hosts = sys.argv[1], sys.argv[2], sys.argv[3]
cfg = json.load(open(p))
a = cfg["args"]
def set_pair(flag, val):
    if flag in a:
        a[a.index(flag) + 1] = val
    else:
        a.extend([flag, val])
if "--prefill" in a and a[a.index("--prefill") + 1] == "auto":
    a[a.index("--prefill") + 1] = "auto:16384"
if "--kv-grow" not in a:
    a.append("--kv-grow")
# setup.sh writes --expert-profile as <install dir>/data/expert-profile.bin, i.e. on
# the container rootfs. Repoint BOTH the read and the save side at the dataset path
# so the learned profile outlives a rebuild and each quant keeps its own.
set_pair("--expert-profile", profile)
set_pair("--adapt-async", "1")
set_pair("--expert-profile-save", profile)
set_pair("--expert-profile-save-every", "10")
set_pair("--pool-workers", "10")
set_pair("--lookup-chain", "2")
if "--prompt-cache-tail" not in a:
    a.append("--prompt-cache-tail")
set_pair("--conversation-cache-mib", "4096")
# fit_max_tokens: the engine rejects a request outright when
# prompt + max_tokens > context ("prompt (114845 tokens) + max tokens (16244)
# exceeds the context (131072); requests are never truncated", 0.1.43). Clients
# like OpenCode reserve the full limit.output (16384) for the reply, so a long
# session dies at ~115k instead of using the window. Clamping max_tokens to the
# room left turns that 400 into a short completion.
cfg["fit_max_tokens"] = True
# allowed_hosts: serve/server.py refuses any request whose Host: header it does
# not recognise (DNS-rebinding guard). host_names_for() allows loopback, the bind
# address, IPs and socket.gethostname() - in this CT that is the SHORT name, so
# the FQDN clients actually use dies with 403 forbidden unless it is listed here.
# Patched in the same place as the tuning flags because setup.sh rewrites this
# file on every run, so an edit made by hand does not survive a rebuild.
if hosts.strip():
    cfg["allowed_hosts"] = [h.strip().lower() for h in hosts.split(",") if h.strip()]
json.dump(cfg, open(p, "w"), indent=1)
PYEOF
	log "  Phase 1+2 flags: $(python3 -c "import json,sys; print(' '.join(json.load(open(sys.argv[1]))['args']))" "$CFG_JSON" 2>/dev/null || echo 'see config')"
	if [ -n "$STRATA_ALLOWED_HOSTS" ]; then
		log "  allowed_hosts: $STRATA_ALLOWED_HOSTS (loopback, the bind address, IPs and $(hostname -s) already pass the guard)"
	else
		log "  allowed_hosts: not set - only loopback, the bind address, IPs and $(hostname -s) will be accepted"
	fi

	# --- Vision: verify setup actually wired the encoder ---
	# A silent text-only fallback is what bit this board before: without the encoder
	# every image request dies with "this server was started without the vision
	# encoder". Both halves must exist - the mtmd helper binary AND the mmproj weights.
	# The helper sits in engine-cuda12/ here, not engine/: setup.py's engine_dir()
	# picks engine-cuda12 for the CUDA 12 toolkit, which is what sm_70 requires.
	if [ "$STRATA_VISION" != "no" ]; then
		VIS_EXE="$("$STRATA_DIR/.venv/bin/python" -c "import json,sys; print((json.load(open(sys.argv[1])).get('vision') or {}).get('exe',''))" "$CFG_JSON" 2>/dev/null || true)"
		VIS_MMPROJ="$("$STRATA_DIR/.venv/bin/python" -c "import json,sys; print((json.load(open(sys.argv[1])).get('vision') or {}).get('mmproj',''))" "$CFG_JSON" 2>/dev/null || true)"
		if [ -z "$VIS_EXE" ] || [ ! -x "$VIS_EXE" ]; then
			for _ve in "$STRATA_DIR/engine-cuda12/strata-vision" "$STRATA_DIR/engine/strata-vision"; do
				if [ -x "$_ve" ]; then VIS_EXE="$_ve"; break; fi
			done
		fi
		if [ -z "$VIS_EXE" ] || [ ! -x "$VIS_EXE" ]; then
			fatal "vision=${STRATA_VISION} but no strata-vision helper in ${STRATA_DIR}/engine-cuda12 or ${STRATA_DIR}/engine - the image encoder build failed (see the setup log above)"
		fi
		if [ -z "$VIS_MMPROJ" ] || [ ! -s "$VIS_MMPROJ" ]; then
			fatal "vision=${STRATA_VISION} but the config's vision.mmproj is '${VIS_MMPROJ:-<unset>}' (not a file) - setup did not fetch ${MMPROJ_NAME} (0.9 GB) into ${STRATA_MODEL_DIR}/models"
		fi
		VIS_GPU="no"
		if [ "$STRATA_VISION" = "gpu" ]; then VIS_GPU="yes"; fi
		log "  Vision wired: exe=${VIS_EXE}, mmproj=${VIS_MMPROJ##*/} ($(du -h "$VIS_MMPROJ" | awk '{print $1}')), encoder on GPU: $VIS_GPU"
	fi

	# --- Learned expert profile: the dataset path is the source of truth ---
	# PROFILE_PATH lives on the model dataset, so it survives pct destroy on its own.
	# Seed it from the newest pre-rebuild snapshot (or leave it alone if the engine
	# has already been writing to it - that copy is newer than any snapshot). The
	# rest of data/ (draft vocabularies, gguf_fingerprints.json) still belongs on the
	# rootfs where the engine looks for it. Format-safe across versions: STRP magic +
	# version 1, and 0.1.43's read_expert_profile (src/core/expert_cache.cpp) reads 1.
	mkdir -p "$PROFILE_DIR" "$STRATA_DIR/data"
	LATEST_SNAP=""
	for d in "$STRATA_MODEL_DIR"/pre-rebuild-*/data; do
		[ -s "$d/expert-profile.bin" ] && LATEST_SNAP="$d"
	done
	SNAP_NAME="${LATEST_SNAP%/data}"; SNAP_NAME="${SNAP_NAME##*/}"
	if [ -n "$LATEST_SNAP" ] && { [ ! -s "$PROFILE_PATH" ] || [ "$LATEST_SNAP/expert-profile.bin" -nt "$PROFILE_PATH" ]; }; then
		cp -a "$LATEST_SNAP/expert-profile.bin" "$PROFILE_PATH" \
			&& log "  Seeded learned expert profile -> ${PROFILE_PATH} (from ${SNAP_NAME})"
	fi
	if [ -n "$LATEST_SNAP" ]; then
		cp -a "$LATEST_SNAP"/. "$STRATA_DIR/data/" 2>/dev/null || true
	fi
	if [ -s "$PROFILE_PATH" ]; then
		log "  Expert profile: ${PROFILE_PATH} ($(du -h "$PROFILE_PATH" | awk '{print $1}')) - dataset-backed, survives a rebuild"
	else
		log "  No expert profile found - the engine will learn one from cold."
	fi

	cat > /etc/systemd/system/strata.service <<UNITEOF
[Unit]
Description=Strata AI Engine (Qwen3.8-Flash-Next ${MODEL_NAME}, ${STRATA_CONTEXT} ctx, ${VISION_LABEL}) - CUDA ${CUDA_MAJOR} sm_70 EXPERIMENTAL build on Tesla V100 32GB, port ${STRATA_PORT}
After=network.target
# Explicit restart budget (systemd's implicit default is 5 starts in 10 s): with
# RestartSec=10 a crash-loop gets 60 s before the unit goes to failed state.
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=${STRATA_DIR}
Environment=STRATA_EXPERIMENTAL_SM60=1
Environment=PATH=/usr/local/cuda-${CUDA_MAJOR}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=LD_LIBRARY_PATH=/usr/local/cuda-${CUDA_MAJOR}/lib64
LimitMEMLOCK=infinity
ExecStart=${STRATA_DIR}/.venv/bin/python ${STRATA_DIR}/serve/server.py --engine strata --config ${CFG_JSON} --port ${STRATA_PORT}
Restart=on-failure
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
UNITEOF
	systemctl daemon-reload

	# --- 6/6 Start + verify ---
	log "[6/6] Starting strata.service and verifying..."
	systemctl enable strata >/dev/null 2>&1 || true
	systemctl restart strata
	sleep 3
	if ! systemctl is-active strata >/dev/null 2>&1; then
		log "  strata.service not active yet - last 30 lines:"
		journalctl -u strata -n 30 --no-pager 2>/dev/null || true
		fatal "strata.service failed to start"
	fi
	# Model load: IQ2_XS copies ~35.5 GB of experts into RAM + dense weights on GPU,
	# 1-3 min, longer the first time (page cache cold; shards now read from the SSD
	# bind /srv/ssd-models, which is what made this board fast); IQ3_XXS/IQ3_S
	# run in low-RAM mode here and load longer still (15 min window below = warning).
	READY=0
	for i in $(seq 1 90); do
		if curl -fsS -m 5 "http://127.0.0.1:${STRATA_PORT}/health" >/dev/null 2>&1; then READY=1; break; fi
		if ! systemctl is-active strata >/dev/null 2>&1; then
			journalctl -u strata -n 30 --no-pager 2>/dev/null || true
			fatal "strata.service died while loading the model"
		fi
		sleep 10
	done
	if [ "$READY" != "1" ]; then
		log "  WARNING: /health not ready after 15 min (still loading?) - check: journalctl -u strata -f"
	else
		log "  /health OK"
	fi
	# Vision gate: the server says in /health whether the encoder came up. Text-only
	# here means every image request 400s, so say it out loud instead of letting it
	# surface as a client error days later.
	if [ "$READY" = "1" ] && [ "$STRATA_VISION" != "no" ]; then
		HEALTH_JSON="$(curl -fsS -m 5 "http://127.0.0.1:${STRATA_PORT}/health" 2>/dev/null || true)"
		case "$HEALTH_JSON" in
			*'"images": true'*|*'"images":true'*)
				log "  Vision live: /health reports images=true" ;;
			*)
				log "  WARNING: vision=${STRATA_VISION} requested but /health does not report images=true - images will be refused. Check the encoder start in ${STRATA_DIR}/strata-$(printf '%s' "$MODEL_NAME" | tr '[:upper:]' '[:lower:]').log (VRAM: the encoder wants ~1.2 GB beside the 128K KV)." ;;
		esac
	fi
	# Host gate: "the endpoint works" and "the endpoint works under its name" are
	# different questions - the rebinding guard 403s any Host: it does not know,
	# and the CT's IP always passes, so a greenfield install can look healthy while
	# every client that uses the FQDN is locked out. Ask the way a client does.
	# Skipped for "*" and ".domain" entries: neither is a Host value to send.
	if [ "$READY" = "1" ] && [ -n "$STRATA_ALLOWED_HOSTS" ]; then
		_OLDIFS="$IFS"; IFS=,; read -r -a _HOSTS <<< "$STRATA_ALLOWED_HOSTS"; IFS="$_OLDIFS"
		for _h in "${_HOSTS[@]}"; do
			case "$_h" in "*"|.*) continue ;; esac
			_code="$(curl -s -o /dev/null -w '%{http_code}' -m 5 -H "Host: $_h" "http://127.0.0.1:${STRATA_PORT}/health" 2>/dev/null || echo 000)"
			if [ "$_code" = "200" ]; then
				log "  Host OK: $_h accepted (HTTP 200)"
			else
				log "  WARNING: Host: $_h -> HTTP $_code - the DNS-rebinding guard is refusing it. allowed_hosts in $CFG_JSON is $(python3 -c "import json,sys; print(json.load(open(sys.argv[1])).get('allowed_hosts','<unset>'))" "$CFG_JSON" 2>/dev/null || echo '?')"
			fi
		done
	fi
	echo ""
	echo "=============================================================="
	echo "  Strata bootstrap COMPLETE - LXC 115 (hlh-ai-engine-strata)"
	echo "=============================================================="
	nvidia-smi 2>&1 | head -15 || true
	echo ""
	echo "  Strata web UI + API : http://${LXC_IP}:${STRATA_PORT}  (OpenAI /v1, Anthropic /v1/messages)"
	if [ -n "$STRATA_ALLOWED_HOSTS" ]; then
		echo "                      also http://<allowed host>:${STRATA_PORT} - allowed_hosts: ${STRATA_ALLOWED_HOSTS}"
	fi
	echo "  Model               : Qwen3.8-Flash-Next ${MODEL_NAME} (${STRATA_CONTEXT} ctx, ${STRATA_KV} KV, ${VISION_LABEL})"
	echo "  Model shards        : ${GGUF_DIR} (SSD bind mp1, host rpool/strata-models) - no download"
	echo "  Model packs         : ${STRATA_MODEL_DIR} (shared host mount, pack output)"
	echo "  Engine              : ${STRATA_DIR}/engine-cuda12 (sm_70 EXPERIMENTAL, CUDA ${CUDA_MAJOR} - setup.py names the dir after the toolkit)"
	echo "  Service             : systemctl status strata / journalctl -u strata -f"
	echo ""
	echo "  Verify:"
	echo "    pct exec 115 -- nvidia-smi -L"
	echo "    curl -s http://${LXC_IP}:${STRATA_PORT}/health"
	echo "    curl -s http://${LXC_IP}:${STRATA_PORT}/v1/models"
	if [ -n "$STRATA_ALLOWED_HOSTS" ]; then
		echo "    by name (Host allow-list): curl -s -o /dev/null -w '%{http_code}\\n' -H 'Host: ${STRATA_ALLOWED_HOSTS%%,*}' http://127.0.0.1:${STRATA_PORT}/health   (want 200, 403 = refused)"
	fi
	if [ "$STRATA_VISION" != "no" ]; then
		echo "    images  : curl -s http://${LXC_IP}:${STRATA_PORT}/health | grep -o '\"images\": *[a-z]*'   (want true)"
		echo "            then one real picture through /v1/chat/completions (an image_url part);"
		echo "            a refusal naming 'the vision encoder' means the encoder did not come up."
	fi
	echo ""
	exit 0
fi

# --- Host-side: run bootstrap inside LXC (pct exec preferred, SSH fallback) ---
log() { echo "[configure-strata] $*"; }
fatal() { log "ERROR: $*" >&2; exit 1; }

log "Configuring Strata in LXC ${TARGET_LXC_ID} (${HOST_IP}) - CUDA $CUDA_MAJOR, sm_70 EXPERIMENTAL, ${MODEL_NAME}..."
command -v pct >/dev/null 2>&1 || fatal "pct not found. Run on Proxmox host."

if ! pct status "${TARGET_LXC_ID}" >/dev/null 2>&1; then
	fatal "LXC ${TARGET_LXC_ID} not found. Run deploy-hlh-ai-engine-strata.sh first."
fi
if ! pct status "${TARGET_LXC_ID}" 2>/dev/null | grep -q running; then
	log "Starting LXC ${TARGET_LXC_ID}..."
	pct start "${TARGET_LXC_ID}"
	sleep 3
fi

if ! pct exec "${TARGET_LXC_ID}" -- echo ok >/dev/null 2>&1; then
	fatal "pct exec failed - LXC not healthy. Check: pct status ${TARGET_LXC_ID}"
fi

log "Pushing configure script into LXC via pct exec..."
pct exec "${TARGET_LXC_ID}" -- mkdir -p /root/strata-bootstrap
pct push "${TARGET_LXC_ID}" "${SCRIPT_DIR}/configure-hlh-ai-engine-strata.sh" /root/strata-bootstrap/configure-hlh-ai-engine-strata.sh --perms 0755
log "  (CUDA $CUDA_MAJOR + userspace ${DRIVER_BRANCH}/${NVIDIA_DRIVER_VERSION} + Strata pinned ${STRATA_COMMIT:0:7} + ${MODEL_NAME} from ${GGUF_DIR:-download} + vision ${STRATA_VISION} + systemd strata.service)"
log "  This is the long step: engine compile ~10-40 min + pack from local shards (no model download; ~5 GB MTP draft fetched)"
if [ "$STRATA_VISION" != "no" ]; then
	log "    + image encoder: ${MMPROJ_NAME} (0.9 GB download into ${STRATA_MODEL_DIR}/models) + strata-vision compile ~10-20 min."
fi
pct push "${TARGET_LXC_ID}" "/usr/bin/nvidia-smi" "/tmp/nvidia-smi" --perms 0755
log "Running bootstrap inside LXC (pct exec)..."
# Forward model choices: the pushed script re-parses its own argv inside the LXC,
# so --model/--gguf-dir must be passed explicitly or the bootstrap silently falls
# back to compiled-in defaults after the push. Same for --vision: without it a
# --vision no/cpu run from the host would still pack text-only or GPU-only.
INNER_ARGS=(--bootstrap-inside --model "$MODEL_NAME" --vision "$STRATA_VISION")
if [ -n "$GGUF_DIR" ]; then
	INNER_ARGS+=(--gguf-dir "$GGUF_DIR")
fi
if [ -n "$STRATA_VISION_TOKENS" ]; then
	INNER_ARGS+=(--vision-tokens "$STRATA_VISION_TOKENS")
fi
if [ -n "$STRATA_ALLOWED_HOSTS" ]; then
	INNER_ARGS+=(--allowed-hosts "$STRATA_ALLOWED_HOSTS")
fi
pct exec "${TARGET_LXC_ID}" -- bash /root/strata-bootstrap/configure-hlh-ai-engine-strata.sh "${INNER_ARGS[@]}"
log "Strata configuration complete. LXC ${TARGET_LXC_ID} at ${HOST_IP}."
log "Verify: pct exec ${TARGET_LXC_ID} -- systemctl status strata && curl -s http://${HOST_IP}:${STRATA_PORT}/health"
