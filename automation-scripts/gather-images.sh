#!/usr/bin/env bash
#
# gather-images.sh — pulls the container images kubeadm needs and exports
# them as tar files into binaries/images/ for an air-gapped install.
#
# REQUIRES: internet access AND a running containerd (ctr in PATH).
# Run this once, online, after the runtime is installed. The exported tars
# become part of the offline bundle; the install script imports them later.
#
# Usage:  sudo ./gather-images.sh
#
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMG_DIR="${SCRIPT_DIR}/../binaries/images"

log()  { echo "[$(date '+%H:%M:%S')] [$1] ${*:2}"; }
info() { log INFO  "$@"; }
err()  { log ERROR "$@"; }
trap 'err "gather-images failed at line $LINENO"; exit 1' ERR

# --- Preconditions ---------------------------------------------------------
if [[ "$(id -u)" -ne 0 ]]; then
  err "Must run as root (ctr needs it). Suggestion: re-run with sudo."
  exit 1
fi
if ! command -v ctr >/dev/null 2>&1; then
  err "ctr not found. Suggestion: install the runtime first (install-k8s.sh)."
  exit 1
fi
if ! command -v kubeadm >/dev/null 2>&1; then
  err "kubeadm not found. Suggestion: install the binaries first."
  exit 1
fi

mkdir -p "$IMG_DIR"

# --- 1. Ask kubeadm which images it needs ----------------------------------
# kubeadm prints the exact image list for its version. We never guess.
info "Asking kubeadm which images are required..."
mapfile -t IMAGES < <(kubeadm config images list 2>/dev/null)

if [[ "${#IMAGES[@]}" -eq 0 ]]; then
  err "kubeadm returned no images. Suggestion: check 'kubeadm config images list'."
  exit 1
fi
info "kubeadm needs ${#IMAGES[@]} images:"
printf '  %s\n' "${IMAGES[@]}"

# --- helper: pull one image with retries -----------------------------------
# Pulling is network-bound, so transient failures get retried.
pull_image() {
  local img="$1" attempt=1 max=3
  while (( attempt <= max )); do
    info "Pulling ($attempt/$max): $img"
    if ctr -n k8s.io images pull "$img" >/dev/null 2>&1; then
      return 0
    fi
    err "Pull failed, retrying in $((attempt * 3))s..."
    sleep $((attempt * 3))
    (( attempt++ ))
  done
  return 1
}

# --- 2. Pull every image into the k8s.io namespace -------------------------
# Kubernetes only looks in containerd's 'k8s.io' namespace, so we pull there.
info "=== Pulling images ==="
for img in "${IMAGES[@]}"; do
  if ! pull_image "$img"; then
    err "Could not pull: $img"
    err "Suggestion: check internet access and the image name."
    exit 1
  fi
done
info "All images pulled."

# --- 3. Export each image to a tar file ------------------------------------
# Each image becomes a portable tar. We turn the image name into a safe
# filename by replacing slashes and colons with underscores.
info "=== Exporting images to $IMG_DIR ==="
for img in "${IMAGES[@]}"; do
  safe_name="$(echo "$img" | tr '/:' '__')"
  out="${IMG_DIR}/${safe_name}.tar"
  info "Exporting: $img"
  ctr -n k8s.io images export "$out" "$img" >/dev/null 2>&1
  # Sanity check: the tar must exist and be non-trivially sized.
  if [[ ! -s "$out" ]]; then
    err "Export produced an empty file for $img."
    exit 1
  fi
done

# --- 4. Record what was gathered -------------------------------------------
printf '%s\n' "${IMAGES[@]}" > "${IMG_DIR}/images.list"

# --- 4. Flannel: download manifest, then gather its images -----------------
# Flannel is the pod network. It needs a YAML manifest AND container images.
# We download the manifest first, then read the image names straight out of
# it, so the bundled image always matches the bundled manifest.
FLANNEL_VERSION="v0.27.0"
CONFIG_DIR="${SCRIPT_DIR}/../configs"
mkdir -p "$CONFIG_DIR"

info "=== Flannel (${FLANNEL_VERSION}) ==="
info "Downloading Flannel manifest..."
flannel_url="https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml"
if ! curl -fsSL -o "${CONFIG_DIR}/kube-flannel.yml" "$flannel_url"; then
  err "Could not download Flannel manifest. Suggestion: check internet / version."
  exit 1
fi

# Pull the image name(s) out of the manifest: every 'image:' line.
mapfile -t FLANNEL_IMAGES < <(grep -oP '(?<=image:\s).*' "${CONFIG_DIR}/kube-flannel.yml" | tr -d '"' | sort -u)
if [[ "${#FLANNEL_IMAGES[@]}" -eq 0 ]]; then
  err "No images found in Flannel manifest. Suggestion: inspect kube-flannel.yml."
  exit 1
fi
info "Flannel needs ${#FLANNEL_IMAGES[@]} image(s):"
printf '  %s\n' "${FLANNEL_IMAGES[@]}"

for img in "${FLANNEL_IMAGES[@]}"; do
  if ! pull_image "$img"; then
    err "Could not pull Flannel image: $img"
    exit 1
  fi
  safe_name="$(echo "$img" | tr '/:' '__')"
  out="${IMG_DIR}/${safe_name}.tar"
  info "Exporting: $img"
  ctr -n k8s.io images export "$out" "$img" >/dev/null 2>&1
  [[ -s "$out" ]] || { err "Empty export for $img."; exit 1; }
done
info "Flannel manifest and images gathered."

info "Done. Exported $(ls -1 "${IMG_DIR}"/*.tar | wc -l) image tar(s):"
ls -lh "${IMG_DIR}"/*.tar | awk '{print "  " $5 "\t" $NF}'
