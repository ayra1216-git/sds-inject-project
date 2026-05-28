#!/usr/bin/env bash
set -Eeuo pipefail
err_report() {
    err "Error on line $1, Check $LOG_FILE for details."
}

trap 'err_report $LINENO' ERR

log() { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [$1] ${*:2}"; } 
info() { log INFO "$@"; } 
warn() { log WARN "$@"; } 
err() { log ERROR "$@"; }
require_file() {
  if [[ ! -f "$1" ]]; then
    err "Missing bundled file: $1"
    err "Suggestion: run build-script and copy binaries/ next to automation-scripts/."
    exit 1
  fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${SCRIPT_DIR}/../logs"
LOG_FILE="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
BIN_DIR="${SCRIPT_DIR}/../binaries" 
mkdir -p "$LOG_DIR"
exec > >(tee -a "$LOG_FILE") 2>&1

usage() {
  if [[ -n "${1:-}" ]]; then
    echo "$1" > /dev/tty
  fi
  echo "Usage: $0 --role master|worker [--check] [--join-command]" > /dev/tty
  exit 1
}

ROLE=""
CHECK_ONLY=0
JOIN_COMMAND=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --role)
      if [[ -z "${2:-}" ]]; then
        usage "--role requires a value"
      fi
      ROLE="$2"
      shift 2
      ;;
    --check)
      CHECK_ONLY=1
      shift        
      ;;                   
    --join-command)
      if [[ -z "${2:-}" ]]; then
        usage "--join-command requires a value"
      fi
      JOIN_COMMAND="$2"
      shift 2
      ;;  
    *)
      usage "Unknown argument: $1"
      ;;
  esac
done

case "$ROLE" in
     master|worker) : ;;
     "")  usage "Missing --role" ;;
     *)   usage "Invalid role: $ROLE" ;;
esac

preflight(){
  info "Running preflight checks"
  local ok=1  
  
  if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root"
    ok=0
  fi
  
  if ! grep -qi ubuntu /etc/os-release; then
    err "OS is not ubuntu"
    ok=0
  fi
  
  if [[ ! -f /sys/fs/cgroup/cgroup.controllers ]]; then
    err "cgroup v2 not detected. Suggestion: use Ubuntu 22.04+."
    ok=0
  fi
  
  if [[ "$ROLE" == "master" ]]; then
    cpus=$(nproc)
    if [[ "$cpus" -lt 2 ]]; then
      err "Master needs >=2 CPUs. Suggestion: give VM more CPUs."
      ok=0
    fi
  fi
  
  if [[ "$ok" -eq 0 ]]; then
    err "Preflight failed. Fix issues above and re-run."
    exit 1
  fi
  
  info "Preflight checks passed."
}

prep_swap() {
  info "Disabling swap"
  swapoff -a
  sed -i.bak '/\sswap\s/s/^/#/' /etc/fstab
  
  SWAP_TOTAL=$(free | grep Swap | awk '{print $2}')
  if [[ "$SWAP_TOTAL" -ne 0 ]]; then
    warn "Swap still active — attempting self-heal."
    swapoff -a
    SWAP_TOTAL=$(free | grep Swap | awk '{print $2}')
    if [[ "$SWAP_TOTAL" -ne 0 ]]; then
      err "Could not disable swap. Suggestion: check for systemd swap units or zram."
      exit 1
    fi
  fi
  
  info "Swap is off."
}

prep_modules(){
  info "Loading kernel modules..."
  
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
  
  modprobe overlay
  modprobe br_netfilter
  sleep 1  
  
  for m in overlay br_netfilter; do
    if ! lsmod | grep -q "^${m}"; then
      warn "Module $m not loaded — retrying."
      modprobe "$m"
      if ! lsmod | grep -q "^${m}"; then
        err "Module $m failed to load. Suggestion: check kernel support with 'modinfo $m'."
        exit 1
      fi
    fi
  done
  
  info "Kernel modules loaded."
}

prep_sysctl(){
  info "Applying sysctl settings..."
  
cat > /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  
  sysctl --system >/dev/null
  
  val=$(sysctl -n net.ipv4.ip_forward)
  if [[ "$val" != "1" ]]; then
    warn "ip_forward not set — attempting self-heal."
    sysctl --system >/dev/null
    val=$(sysctl -n net.ipv4.ip_forward)
    if [[ "$val" != "1" ]]; then
      err "ip_forward not set. Suggestion: check /etc/sysctl.d/k8s.conf was written."
      exit 1
    fi
  fi
  info "Sysctl settings applied."
}

install_containerd() {
  if systemctl is-active --quiet containerd; then
    info "containerd already running, skipping"
    return 0
  fi
  
  info "Installing containerd, runc, CNI plugins..."
  require_file "${BIN_DIR}/runtime/containerd.tar.gz"
  require_file "${BIN_DIR}/runtime/runc"
  require_file "${BIN_DIR}/runtime/cni-plugins.tgz"
  
  tar -C /usr/local -xzf "${BIN_DIR}/runtime/containerd.tar.gz"
  install -m 755 "${BIN_DIR}/runtime/runc" /usr/local/sbin/runc  
  mkdir -p /opt/cni/bin
  tar -C /opt/cni/bin -xzf "${BIN_DIR}/runtime/cni-plugins.tgz" 
  
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml  
  
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  
  if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
    warn "SystemdCgroup not set by sed — appending."
    sed -i '/\[plugins.*runc.options\]/a\    SystemdCgroup = true' /etc/containerd/config.toml
    if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
      err "Could not set SystemdCgroup. Suggestion: inspect /etc/containerd/config.toml manually."
      exit 1
    fi
  fi
  
  install -m 644 "${SCRIPT_DIR}/../configs/containerd.service" \
    /etc/systemd/system/containerd.service
  systemctl daemon-reload
  
  if systemctl is-enabled containerd 2>/dev/null | grep -q masked; then
    warn "containerd unit is masked — unmasking."
    systemctl unmask containerd
    systemctl daemon-reload
  fi
  
  systemctl enable --now containerd
  
  sleep 2
  if ! systemctl is-active --quiet containerd; then
    warn "containerd not active — attempting restart."
    systemctl restart containerd
    sleep 2
    if ! systemctl is-active --quiet containerd; then
      err "containerd failed to start. Suggestion: journalctl -u containerd"
      exit 1
    fi
  fi
  
  info "containerd is running."
}

install_k8s_binaries(){
  info "Installing kubeadm, kubelet, kubectl..."
  for b in kubeadm kubelet kubectl; do
    require_file "${BIN_DIR}/k8s/${b}"
    install -m 755 "${BIN_DIR}/k8s/${b}" "/usr/local/bin/${b}"
  done
  
cat > /etc/systemd/system/kubelet.service <<EOF
[Unit]
Description=kubelet: The Kubernetes Node Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/bin/kubelet
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF
  
  mkdir -p /etc/systemd/system/kubelet.service.d
cat > /etc/systemd/system/kubelet.service.d/10-kubeadm.conf <<'EOF'
[Service]
Environment="KUBELET_KUBECONFIG_ARGS=--bootstrap-kubeconfig=/etc/kubernetes/bootstrap-kubelet.conf --kubeconfig=/etc/kubernetes/kubelet.conf"
Environment="KUBELET_CONFIG_ARGS=--config=/var/lib/kubelet/config.yaml"
EnvironmentFile=-/var/lib/kubelet/kubeadm-flags.env
EnvironmentFile=-/etc/default/kubelet
ExecStart=
ExecStart=/usr/local/bin/kubelet $KUBELET_KUBECONFIG_ARGS $KUBELET_CONFIG_ARGS $KUBELET_KUBEADM_ARGS $KUBELET_EXTRA_ARGS
EOF
  
  # Pin the pause image kubelet uses to the version we bundled.
  # Without this, kubelet's built-in default (pause:3.10) doesn't match
  # the bundled image (pause:3.10.1) and it tries to pull from the internet.
  mkdir -p /var/lib/kubelet
cat > /var/lib/kubelet/kubeadm-flags.env <<'EOF'
KUBELET_KUBEADM_ARGS="--pod-infra-container-image=registry.k8s.io/pause:3.10.1"
EOF
  
  systemctl daemon-reload 
  systemctl enable kubelet
  
  if ! kubeadm version >/dev/null 2>&1; then
    err "kubeadm not working. Suggestion: check bundled binary is linux/amd64."
    exit 1
  fi 
  
  info "Kubernetes binaries installed."
}

install_tools(){
  info "Installing helm and kustomize..."
  
  require_file "${BIN_DIR}/tools/helm.tar.gz"
  local tmp
  tmp=$(mktemp -d)
  tar -C "$tmp" -xzf "${BIN_DIR}/tools/helm.tar.gz"
  install -m 755 "$tmp"/*/helm /usr/local/bin/helm
  rm -rf "$tmp"
  
  require_file "${BIN_DIR}/tools/kustomize.tar.gz"
  tmp=$(mktemp -d)
  tar -C "$tmp" -xzf "${BIN_DIR}/tools/kustomize.tar.gz"
  install -m 755 "$tmp"/kustomize /usr/local/bin/kustomize
  rm -rf "$tmp"
  
  if ! helm version >/dev/null 2>&1; then
    err "helm not working. Suggestion: check bundled binary is linux/amd64."
    exit 1
  fi
  
  if ! kustomize version >/dev/null 2>&1; then
    err "kustomize not working. Suggestion: check bundled binary is linux/amd64."
    exit 1
  fi
  
  info "helm and kustomize installed."
}

import_images(){
  info "Importing bundled container images..."
  local img_dir="${BIN_DIR}/images"
  
  if ! ls "$img_dir"/*.tar >/dev/null 2>&1; then
    err "No image tars found in $img_dir"
    err "Suggestion: run gather-images.sh and copy binaries/images/."
    exit 1
  fi
  
  local count=0
  
  for tar in "$img_dir"/*.tar; do
    info "Importing $(basename "$tar")"
    if ! ctr -n k8s.io images import "$tar" >/dev/null 2>&1; then
      err "Failed to import $tar. Suggestion: check the tar is not corrupt."
      exit 1
    fi
    count=$((count + 1))
  done
  
  info "Imported $count image(s)."
}

install_master() {
  info "=== Installing master (control plane) ==="
  
  if [[ -f /etc/kubernetes/admin.conf ]]; then
    info "Control plane already initialized — skipping kubeadm init."
  else
    # Detect primary IP
    local primary_ip
    primary_ip=$(ip -4 addr show scope global | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1)
    if [[ -z "$primary_ip" ]]; then
      err "Could not detect a primary IP."
      exit 1
    fi
    info "Using API server bind address: $primary_ip"
    
    # Generate kubeadm config with the detected IP
cat > "${SCRIPT_DIR}/../configs/kubeadm-config.yaml" <<EOF
apiVersion: kubeadm.k8s.io/v1beta4
kind: ClusterConfiguration
kubernetesVersion: v1.35.5
networking:
  podSubnet: 10.244.0.0/16
---
apiVersion: kubeadm.k8s.io/v1beta4
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: ${primary_ip}
nodeRegistration:
  criSocket: unix:///run/containerd/containerd.sock
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
cgroupDriver: systemd
EOF
    
    if ! kubeadm init --config "${SCRIPT_DIR}/../configs/kubeadm-config.yaml" --upload-certs; then
      err "kubeadm init failed."
      exit 1
    fi
  fi
  
  local target_user="${SUDO_USER:-root}"
  local target_home; target_home="$(getent passwd "$target_user" | cut -d: -f6)"
  mkdir -p "${target_home}/.kube"
  cp -f /etc/kubernetes/admin.conf "${target_home}/.kube/config"
  chown -R "$target_user":"$target_user" "${target_home}/.kube"
  export KUBECONFIG=/etc/kubernetes/admin.conf
  
  if ! kubectl apply -f "${SCRIPT_DIR}/../configs/kube-flannel.yml"; then
    warn "Flannel apply failed, retrying in 5s..."
    sleep 5
    if ! kubectl apply -f "${SCRIPT_DIR}/../configs/kube-flannel.yml"; then
      err "Could not apply Flannel."
      exit 1
    fi
  fi  
  
  kubeadm token create --print-join-command > "${SCRIPT_DIR}/../configs/join-command.sh"
  chmod +x "${SCRIPT_DIR}/../configs/join-command.sh"
  info "Join command saved to configs/join-command.sh"
  
  info "Waiting for node Ready (up to 90s)..."
  local i=0
  while (( i < 18 )); do
    if kubectl get nodes 2>/dev/null | grep -qw Ready; then
      info "Node is Ready."
      break
    fi
    sleep 5
    i=$((i + 1))
  done
  if (( i >= 18 )); then
    warn "Node not Ready yet. Check 'kubectl get pods -n kube-flannel'."
  fi
  
  info "Master installation complete."
}

install_worker() {
  info "=== Installing worker ==="
  
  if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    info "Worker already joined — skipping kubeadm join."
    return 0
  fi
  
  local cmd="$JOIN_COMMAND"
  
  if [[ -z "$cmd" && -f "${SCRIPT_DIR}/../configs/join-command.sh" ]]; then
    cmd="$(cat "${SCRIPT_DIR}/../configs/join-command.sh")"
  fi
  
  if [[ -z "$cmd" ]]; then
    err "No join command provided."
    err "Suggestion: pass --join-command \"kubeadm join ...\" or place it in configs/join-command.sh."
    err "Get it from the master: sudo kubeadm token create --print-join-command"
    exit 1
  fi
  
  info "Running kubeadm join..."
  if ! eval "$cmd"; then
    err "kubeadm join failed. Token may be expired (24h default)."
    err "Regenerate on master with: sudo kubeadm token create --print-join-command"
    exit 1
  fi
  
  info "Worker joined the cluster."
}

main() {
  preflight   
  
  if [[ "$CHECK_ONLY" -eq 1 ]]; then
    info "Check-only mode — nothing changed. Exiting."
    exit 0
  fi
  
  prep_swap
  prep_modules 
  prep_sysctl
  install_containerd
  install_k8s_binaries
  install_tools
  import_images
  
  case "$ROLE" in
    master) install_master ;;
    worker) install_worker ;;
  esac
  
  info "Done. Log: $LOG_FILE"
}

main
