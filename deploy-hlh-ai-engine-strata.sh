#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOOTSTRAP_SCRIPT="${SCRIPT_DIR}/configure-hlh-ai-engine-strata.sh"

usage() {
	cat <<'EOF'
Usage:
	./deploy-hlh-ai-engine-strata.sh [--skip-host-driver] [--keep-111] [--no-bootstrap] [--yes]

Strata path (Qwen3.8-Flash-Next IQ2_XS on Tesla V100 GV100GL 32GB via OCuLink) - CUDA:
	1) Verify host NVIDIA 580.65.06 (R580, last for Volta GV100 cc 7.0) + V100 present
	2) Ensure Ubuntu 24.04 LXC template
	3) Remove stale LXC 115 leftovers (115.conf.bak.*) / confirm delete if 115 exists
	4) FREE THE V100: stop hlh-ai-engine-egpu (LXC 111, llama.cpp) + onboot 0
	   (Strata and llama.cpp both want the 32 GB of VRAM; 111's config is kept intact
	    for revert: pct set 111 --onboot 1 && pct start 111)
	5) Create privileged LXC 115 (hlh-ai-engine-strata) at 192.168.1.15
	6) Add cgroup + /dev/nvidia* bind-mounts for single GV100 (c5:00.0)
	7) Start container + push/run Strata bootstrap
	   (CUDA 12.8 + engine build sm_70 EXPERIMENTAL -DSTRATA_EXPERIMENTAL_SM60=ON
	    + IQ2_XS install ~68 GB download + systemd strata.service on :80)

NOTES:
	- V100 is Volta (cc 7.0). Strata's upstream engine needs cc 7.5+; the sm_70 build is
	  the community/experimental path (STRATA_EXPERIMENTAL_SM60=1, Strata #295/#236) and
	  REQUIRES a CUDA 12.x toolkit (CUDA 13 dropped sm_60/sm_70).
	- Host driver: R580 580.65.06 (last supporting Volta) on proxmox-kernel-6.14.11-9-pve
	  (6.17+ breaks 550/580 closed DKMS). Install path mirrors hlh-ai-engine-egpu.
	- Model storage: same /srv/ai/models bind mount as hlh-ai-engine-egpu; Strata keeps
	  its own subfolder /srv/ai/models/strata (packed shards, not GGUFs).
	- First bootstrap is long: engine compile ~10-40 min + ~68 GB model download + pack.
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
LXC_ROOTFS_SIZE="64"
# IQ2_XS: ~35.5 GB of experts in RAM + ~10 GB beside (Strata's own math: fits 48 GB).
# 48 GB is the max sensible limit for this model on a 64 GB host (more buys nothing:
# the expert arena is fixed and the rest of the model lives in VRAM).
LXC_MEMORY="49152"
LXC_CORES="12"
LXC_SWAP="512"
LXC_IP_CONFIG="192.168.1.15/24"
LXC_GATEWAY="192.168.1.1"
LXC_DESC="Strata AI engine (Qwen3.8-Flash-Next IQ2_XS, 128K ctx) - CUDA $CUDA_MAJOR sm_70 EXPERIMENTAL build (-DSTRATA_EXPERIMENTAL_SM60=ON) + driver $NVIDIA_DRIVER_VERSION_SHORT for Tesla V100 (GV100 32GB cc 7.0) via OCuLink c5:00.0, model storage on $POOL:/srv/ai/models/strata, port 80"

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
		-h|--help) usage; exit 0 ;;
		*) echo "ERROR: Unknown option: $1" >&2; usage; exit 1 ;;
	esac
done

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
if [ ! -f "/var/lib/vz/template/ct/${TEMPLATE_FILE}" ]; then
	echo "  Template missing - updating repo index and installing (~1 GB)..."
	pveam update
	pveam install "$TEMPLATE_FILE" || { echo "ERROR: pveam install failed for $TEMPLATE_FILE" >&2; exit 1; }
fi
echo "  Template present."

# --- 2/7 Stale LXC 115 leftovers ---
echo "[2/7] Cleaning stale LXC ${LXC_ID} leftovers..."
rm -f "/etc/pve/lxc/${LXC_ID}.conf.bak."* 2>/dev/null || true
if pct status "${LXC_ID}" >/dev/null 2>&1; then
	confirm "hlh-ai-engine-strata (LXC ${LXC_ID}) already exists. Delete it and redeploy? (its /srv/ai/models/strata data on ${POOL} survives)"
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

# --- 4/7 Create LXC ---
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
	echo "[6/7] Running in-container Strata bootstrap (CUDA $CUDA_MAJOR, sm_70 EXPERIMENTAL, IQ2_XS ~68 GB)..."
	echo "      This is the long step: engine compile ~10-40 min + model download + pack."
	pct exec "${LXC_ID}" -- mkdir -p /root/strata-bootstrap
	pct push "${LXC_ID}" "$BOOTSTRAP_SCRIPT" /root/strata-bootstrap/configure-hlh-ai-engine-strata.sh --perms 0755
	pct push "${LXC_ID}" "/usr/bin/nvidia-smi" "/tmp/nvidia-smi" --perms 0755
	pct exec "${LXC_ID}" -- bash /root/strata-bootstrap/configure-hlh-ai-engine-strata.sh --bootstrap-inside
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
fi

echo ""
echo "Deployment complete. LXC ${LXC_ID} (${LXC_NAME}) at ${LXC_IP_CONFIG%%/*}."
echo "  Strata web UI + API : http://192.168.1.15:80   (OpenAI /v1, Anthropic /v1/messages)"
echo "  Model data          : ${MODEL_HOST_DIR}/strata (host) <-> ${MODEL_LXC_DIR}/strata (LXC) on ${POOL}"
echo "  Strata source       : /opt/strata (pinned commit, engine in /opt/strata/engine)"
echo "  V100 freed from     : LXC ${EGPU_LXC_ID} (hlh-ai-engine-egpu, stopped, onboot 0, config intact)"
echo "  Host driver pinned  : $NVIDIA_DRIVER_VERSION_SHORT (branch $DRIVER_BRANCH) CUDA $CUDA_MAJOR Volta V100 32GB sm70"
echo "Verify inside LXC: nvidia-smi -L && systemctl status strata && curl -s http://127.0.0.1:80/health"
