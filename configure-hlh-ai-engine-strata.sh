#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LXC_ID=115
LXC_IP="192.168.1.15"

usage() {
	cat <<'EOF'
Usage:
	./configure-hlh-ai-engine-strata.sh [--lxc-id ID] [--host HOST] [--bootstrap-inside]

Strata path (Qwen3.8-Flash-Next IQ2_XS on Tesla V100 GV100GL 32GB via OCuLink) - CUDA:
	- host driver 580.65.06 (R580, last for Volta) already installed by
	  deploy-hlh-ai-engine-strata.sh (or hlh-ai-engine-egpu's)
	- container: CUDA $CUDA_MAJOR (sm_70 requires CUDA 12.x; 13 dropped sm_70) +
	  driver-branch userspace 580.65.06 (apt-pinned to the host kernel driver)
	- Strata at pinned commit (engine built -DSTRATA_EXPERIMENTAL_SM60=ON, sm_70
	  community path, Strata #295/#236)
	- IQ2_XS install (~68 GB download + pack) into /srv/ai/models/strata (shared
	  host mount), 128K context, int8 KV, vision off
	- systemd strata.service on port 80 (web UI + OpenAI /v1 + Anthropic /v1/messages)

Host side (default): pushes this script into LXC and runs it with --bootstrap-inside.
--bootstrap-inside: run the bootstrap directly inside the LXC (called by the deploy
	script or manually: pct exec 115 -- bash /root/strata-bootstrap/configure-hlh-ai-engine-strata.sh --bootstrap-inside).
EOF
}

# --- PINNED VERSIONS (V100 Volta cc 7.0) ---
# R580 580.65.06 = last driver supporting Volta (host kernel driver, installed via .run --dkms).
# CUDA 12.8 = final toolkit with sm_70 (CUDA 13 dropped sm_60/sm_70; Strata needs CUDA 12.x).
# Strata: v0.1.32 (sm60/slow-memory fixes #295, llama.cpp update #291).
CUDA_VERSION="${CUDA_VERSION:-12.8.0-1}"
CUDA_MAJOR="${CUDA_MAJOR:-12.8}"
NVIDIA_DRIVER_VERSION="${NVIDIA_DRIVER_VERSION:-580.65.06}"
DRIVER_BRANCH="${DRIVER_BRANCH:-580}"
STRATA_REPO="https://github.com/Niko1221/Strata.git"
STRATA_COMMIT="${STRATA_COMMIT:-c499bd102e7a4135c0de389dcfe38c399759ccc8}"   # 0.1.32
STRATA_DIR="/opt/strata"
STRATA_MODEL_DIR="/srv/ai/models/strata"
MODEL_FAMILY="qwen"
MODEL_NAME="IQ2_XS"
STRATA_CONTEXT="131072"      # 128K - required (16K is unusable for this workload)
STRATA_KV="int8"
STRATA_VISION="no"
STRATA_PORT="80"
STRATA_HOST="0.0.0.0"
STRATA_GPU="0"

BOOTSTRAP_INSIDE=false
HOST_IP="$LXC_IP"
TARGET_LXC_ID="$LXC_ID"

while [[ $# -gt 0 ]]; do
	case "$1" in
		--lxc-id) TARGET_LXC_ID="$2"; shift 2 ;;
		--host) HOST_IP="$2"; shift 2 ;;
		--bootstrap-inside) BOOTSTRAP_INSIDE=true; shift ;;
		-h|--help) usage; exit 0 ;;
		*) echo "ERROR: Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

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
		wget -q "https://developer.download.nvidia.com/compute/cuda/${CUDA_MAJOR}/keys/cuda-${CUDA_MAJOR}_prod.asc" -O /tmp/cuda_prod.asc
		gpg --dearmor --yes --output /etc/apt/keyrings/cuda.gpg /tmp/cuda_prod.asc
		rm -f /tmp/cuda_prod.asc
		echo "deb [signed-by=/etc/apt/keyrings/cuda.gpg] https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/ /" > /etc/apt/sources.list.d/cuda.list
		apt-get update
	fi
	log "  - Installing CUDA $CUDA_MAJOR (sm_70 supported; CUDA 13 dropped Volta)"
	apt-get install -y "cuda-toolkit-${CUDA_MAJOR}=${CUDA_VERSION}"
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
	)
	log "  - Pinning userspace branch $DRIVER_BRANCH to host kernel driver $NVIDIA_DRIVER_VERSION (5 packages)"
	RESOLVED_US="$(apt-cache madison "libnvidia-compute-${DRIVER_BRANCH}" 2>/dev/null | awk -F'|' -v v="${NVIDIA_DRIVER_VERSION}" '{gsub(/[ \t]/,"",$2); if (index($2, v "-")==1) {print $2; exit}}' || true)"
	if [ -z "$RESOLVED_US" ]; then
		log "  Available ${DRIVER_BRANCH} userspace in CUDA repo:"
		apt-cache madison "libnvidia-compute-${DRIVER_BRANCH}" 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print "    ", $2}' | head -10 || true
		fatal "no ${NVIDIA_DRIVER_VERSION} userspace in CUDA ubuntu2404 repo (host driver ${NVIDIA_DRIVER_VERSION}); if the repo rotated, upgrade the host driver to the current 580 tip and re-run"
	fi
	log "  - Resolved $DRIVER_BRANCH userspace: $RESOLVED_US (base matches host driver $NVIDIA_DRIVER_VERSION)"
	apt-mark unhold "${BRANCH_PKGS[@]}" 2>/dev/null || true
	if ! apt-get install -y --allow-downgrades --no-install-recommends \
		"libnvidia-compute-${DRIVER_BRANCH}=${RESOLVED_US}" \
		"libnvidia-cfg1-${DRIVER_BRANCH}=${RESOLVED_US}" \
		"libnvidia-decode-${DRIVER_BRANCH}=${RESOLVED_US}" \
		"libnvidia-gpucomp-${DRIVER_BRANCH}=${RESOLVED_US}" \
		"nvidia-utils-${DRIVER_BRANCH}=${RESOLVED_US}" 2>&1 | tail -n 30; then
		fatal "pinned userspace ${RESOLVED_US} install failed (host driver ${NVIDIA_DRIVER_VERSION}) - do NOT fall back to unpinned: NVML needs the base version to match"
	fi
	# Strata needs no persistenced; drop it if the branch pulled it (it also blocks downgrades while held)
	if dpkg -s nvidia-persistenced >/dev/null 2>&1; then
		systemctl disable --now nvidia-persistenced 2>/dev/null || true
		apt-mark unhold "${BRANCH_PKGS[@]}" 2>/dev/null || true
		apt-get remove -y nvidia-persistenced 2>&1 | tail -n 5 || true
	fi
	apt-mark hold "${BRANCH_PKGS[@]}" 2>/dev/null || true
	# FATAL gate: installed userspace base must match the host kernel driver base (NVML requirement)
	US_VER=$(dpkg-query -W -f='${Version}' "libnvidia-compute-${DRIVER_BRANCH}" 2>/dev/null || echo "missing")
	if ! case "$US_VER" in "${NVIDIA_DRIVER_VERSION}-"*) true ;; *) false ;; esac; then
		fatal "FATAL: libnvidia-compute-${DRIVER_BRANCH}=$US_VER but host kernel driver is $NVIDIA_DRIVER_VERSION (NVML version mismatch)"
	fi
	log "  - Userspace $US_VER matches host kernel driver $NVIDIA_DRIVER_VERSION (NVML exact-base match required)"
	# CUDA env for the user (systemd unit also sets it explicitly)
	cat > /etc/profile.d/cuda.sh <<CUDAEOF
export PATH=/usr/local/cuda-${CUDA_MAJOR}/bin:\$PATH
export LD_LIBRARY_PATH=/usr/local/cuda-${CUDA_MAJOR}/lib64:\$LD_LIBRARY_PATH
CUDAEOF
	# Host nvidia-smi (from deploy push at /tmp/nvidia-smi) + NVML
	if [ -f /tmp/nvidia-smi ]; then
		cp /tmp/nvidia-smi /usr/bin/nvidia-smi
		chmod +x /usr/bin/nvidia-smi
	fi
	ln -sf /usr/lib/x86_64-linux-gnu/libnvidia-ml.so /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.1 2>/dev/null || true
	ln -sf /usr/lib/x86_64-linux-gnu/libnvidia-ml.so /usr/lib/x86_64-linux-gnu/libnvidia-ml.so.580.65.06 2>/dev/null || true

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
	log "[3/6] Checking out Strata at pinned commit ${STRATA_COMMIT:0:7} (0.1.32)..."
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

	# --- 4/6 Strata setup: build engine (sm_70 EXPERIMENTAL) + IQ2_XS install ---
	# This is the long step: venv + pinned deps, llama.cpp fetch, engine compile
	# (~10-40 min on 12 cores), ~68 GB model download + pack, config + run script.
	log "[4/6] Strata setup (family=${MODEL_FAMILY} model=${MODEL_NAME} context=${STRATA_CONTEXT} kv=${STRATA_KV} vision=${STRATA_VISION} gpu=${STRATA_GPU} port=${STRATA_PORT})..."
	log "      STRATA_EXPERIMENTAL_SM60=1 -> builds -DSTRATA_EXPERIMENTAL_SM60=ON (Volta sm_70 community path)"
	cd "$STRATA_DIR"
	export STRATA_EXPERIMENTAL_SM60=1
	./setup.sh --setup \
		--family "$MODEL_FAMILY" \
		--model "$MODEL_NAME" \
		--context "$STRATA_CONTEXT" \
		--kv "$STRATA_KV" \
		--vision "$STRATA_VISION" \
		--gpu "$STRATA_GPU" \
		--port "$STRATA_PORT" \
		--host "$STRATA_HOST" \
		--data-dir "$STRATA_MODEL_DIR" \
		--low-ram auto \
		--no-start \
		--yes
	log "  Strata setup complete."

	# --- 5/6 systemd unit ---
	log "[5/6] Installing strata.service (port $STRATA_PORT)..."
	# Config JSON written by setup: /opt/strata/strata-<family-tag>.json (qwen -> strata-.json)
	CFG_JSON=""
	for f in "$STRATA_DIR"/strata-*.json; do
		[ -f "$f" ] || continue
		if grep -q "$MODEL_NAME" "$f" 2>/dev/null; then CFG_JSON="$f"; break; fi
		[ -z "$CFG_JSON" ] && CFG_JSON="$f"
	done
	[ -n "$CFG_JSON" ] || fatal "no Strata config JSON found in $STRATA_DIR (setup did not finish?)"
	log "  Using config: $CFG_JSON"
	cat > /etc/systemd/system/strata.service <<UNITEOF
[Unit]
Description=Strata AI Engine (Qwen3.8-Flash-Next ${MODEL_NAME}, ${STRATA_CONTEXT} ctx) - CUDA ${CUDA_MAJOR} sm_70 EXPERIMENTAL build on Tesla V100 32GB, port ${STRATA_PORT}
After=network.target

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
	# IQ2_XS: ~35.5 GB of experts copied into RAM + dense weights on GPU. 1-3 min,
	# longer the first time (page cache cold on the ZFS mount).
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
	echo ""
	echo "=============================================================="
	echo "  Strata bootstrap COMPLETE - LXC 115 (hlh-ai-engine-strata)"
	echo "=============================================================="
	nvidia-smi 2>&1 | head -15 || true
	echo ""
	echo "  Strata web UI + API : http://${LXC_IP}:${STRATA_PORT}  (OpenAI /v1, Anthropic /v1/messages)"
	echo "  Model               : Qwen3.8-Flash-Next ${MODEL_NAME} (${STRATA_CONTEXT} ctx, ${STRATA_KV} KV, vision off)"
	echo "  Model data          : ${STRATA_MODEL_DIR} (shared host mount, ~68 GB download + pack)"
	echo "  Engine              : ${STRATA_DIR}/engine (sm_70 EXPERIMENTAL, CUDA ${CUDA_MAJOR})"
	echo "  Service             : systemctl status strata / journalctl -u strata -f"
	echo ""
	echo "  Verify:"
	echo "    pct exec 115 -- nvidia-smi -L"
	echo "    curl -s http://${LXC_IP}:${STRATA_PORT}/health"
	echo "    curl -s http://${LXC_IP}:${STRATA_PORT}/v1/models"
	echo ""
	exit 0
fi

# --- Host-side: run bootstrap inside LXC (pct exec preferred, SSH fallback) ---
log() { echo "[configure-strata] $*"; }
fatal() { log "ERROR: $*" >&2; exit 1; }

log "Configuring Strata in LXC ${TARGET_LXC_ID} (${HOST_IP}) - CUDA $CUDA_MAJOR, sm_70 EXPERIMENTAL, IQ2_XS..."
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
log "  (CUDA $CUDA_MAJOR + userspace ${DRIVER_BRANCH}/${NVIDIA_DRIVER_VERSION} + Strata pinned ${STRATA_COMMIT:0:7} + IQ2_XS ~68 GB + systemd strata.service)"
log "  This is the long step: engine compile ~10-40 min + model download + pack."
pct push "${TARGET_LXC_ID}" "/usr/bin/nvidia-smi" "/tmp/nvidia-smi" --perms 0755
log "Running bootstrap inside LXC (pct exec)..."
pct exec "${TARGET_LXC_ID}" -- bash /root/strata-bootstrap/configure-hlh-ai-engine-strata.sh --bootstrap-inside
log "Strata configuration complete. LXC ${TARGET_LXC_ID} at ${HOST_IP}."
log "Verify: pct exec ${TARGET_LXC_ID} -- systemctl status strata && curl -s http://${HOST_IP}:${STRATA_PORT}/health"
