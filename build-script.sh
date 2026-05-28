#!/usr/bin/env bash
#
# build-script — gathers every offline artifact needed for an air-gapped
# Kubernetes install into the binaries/ directory.
#
# This script REQUIRES internet. It runs on the build machine (your laptop
# or a CI runner), never on the air-gapped target. Its whole purpose is to
# collect the binaries, tools and (later) container images so the target
# can install Kubernetes with no network access at all.
#
# Usage:  ./build-script
#
# ---------------------------------------------------------------------------

# set -E : ERR trap is inherited by functions and subshells
# set -e : exit immediately if any command fails
# set -u : treat use of an unset variable as an error
# set -o pipefail : a pipeline fails if ANY command in it fails, not just the last
set -Eeuo pipefail

# --- Version pinning -------------------------------------------------------
# One source of truth. Air-gapped installs MUST be reproducible, so we never
# use "latest" — the build machine and the target could otherwise drift.
K8S_VERSION="v1.35.5"          # baseline version a fresh master gets
CONTAINERD_VERSION="2.0.2"     # container runtime
RUNC_VERSION="v1.2.4"          # low-level OCI runtime that containerd calls
CNI_PLUGINS_VERSION="v1.6.2"   # standard CNI network plugins
HELM_VERSION="v3.17.0"         # extra tool requested by the assignment
KUSTOMIZE_VERSION="v5.6.0"     # extra tool requested by the assignment

ARCH="amd64"                   # target CPU architecture

# --- Paths -----------------------------------------------------------------
# Resolve the directory this script lives in, so it works no matter where
# it is called from. This is a standard bash idiom worth memorising.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${SCRIPT_DIR}/binaries"

# --- Simple logging --------------------------------------------------------
log()  { echo "[$(date '+%H:%M:%S')] [$1] ${*:2}"; }
info() { log INFO "$@"; }
err()  { log ERROR "$@" >&2; }

# --- ERR trap --------------------------------------------------------------
# If any command fails, this runs and tells us exactly which line broke.
trap 'err "build-script failed at line $LINENO"; exit 1' ERR

# --- Helper: download a file with SMART retries ----------------------------
# Networks are flaky, so we retry — but ONLY for transient failures.
# A 403/404 is permanent: the request itself is wrong, so retrying it just
# wastes time. We retry connection problems and 5xx server errors; we fail
# fast on 4xx client errors. Knowing which failures are worth healing is
# the heart of good self-healing logic.
fetch() {
  local url="$1" dest="$2" attempt=1 max=3 code

  while (( attempt <= max )); do
    info "Downloading ($attempt/$max): $url"

    # -w '%{http_code}' makes curl print the HTTP status to stdout.
    # We capture it. curl's own exit code (in $?) covers network-level
    # failures where there is no HTTP response at all.
    code="$(curl -sSL --connect-timeout 15 -o "$dest" \
                 -w '%{http_code}' "$url" 2>/dev/null)" || code="000"

    if [[ "$code" == "200" ]]; then
      info "Saved: $dest"
      return 0
    fi

    # 000 = no HTTP response (DNS/connection failure) -> transient, retry.
    # 5xx = server-side error -> transient, retry.
    # 4xx = client-side error (403/404/401) -> permanent, do NOT retry.
    if [[ "$code" =~ ^4[0-9][0-9]$ ]]; then
      err "Permanent error (HTTP $code) for: $url"
      err "Suggestion: check the version variable — the file likely does not exist at this URL."
      return 1
    fi

    err "Transient failure (HTTP $code), retrying in $((attempt * 3))s..."
    sleep $((attempt * 3))
    (( attempt++ ))
  done

  err "Gave up downloading after $max attempts: $url"
  return 1
}

# ===========================================================================
# MAIN
# ===========================================================================
info "Build starting — gathering artifacts into ${BIN_DIR}"
mkdir -p "${BIN_DIR}/k8s" "${BIN_DIR}/runtime" "${BIN_DIR}/tools" "${BIN_DIR}/images"

# --- 1. Kubernetes node binaries -------------------------------------------
# kubeadm, kubelet, kubectl are static Go binaries. No package manager,
# no dependencies — just download and mark executable.
info "=== Kubernetes binaries (${K8S_VERSION}) ==="
for b in kubeadm kubelet kubectl; do
  fetch "https://dl.k8s.io/release/${K8S_VERSION}/bin/linux/${ARCH}/${b}" \
        "${BIN_DIR}/k8s/${b}"
  chmod +x "${BIN_DIR}/k8s/${b}"
done

# --- 2. Container runtime --------------------------------------------------
info "=== Container runtime ==="
fetch "https://github.com/containerd/containerd/releases/download/v${CONTAINERD_VERSION}/containerd-${CONTAINERD_VERSION}-linux-${ARCH}.tar.gz" \
      "${BIN_DIR}/runtime/containerd.tar.gz"
fetch "https://github.com/opencontainers/runc/releases/download/${RUNC_VERSION}/runc.${ARCH}" \
      "${BIN_DIR}/runtime/runc"
chmod +x "${BIN_DIR}/runtime/runc"
fetch "https://github.com/containernetworking/plugins/releases/download/${CNI_PLUGINS_VERSION}/cni-plugins-linux-${ARCH}-${CNI_PLUGINS_VERSION}.tgz" \
      "${BIN_DIR}/runtime/cni-plugins.tgz"

# --- 3. Extra tools (kubectl already gathered above) -----------------------
info "=== Extra tools (helm, kustomize) ==="
fetch "https://get.helm.sh/helm-${HELM_VERSION}-linux-${ARCH}.tar.gz" \
      "${BIN_DIR}/tools/helm.tar.gz"
fetch "https://github.com/kubernetes-sigs/kustomize/releases/download/kustomize%2F${KUSTOMIZE_VERSION}/kustomize_${KUSTOMIZE_VERSION}_linux_${ARCH}.tar.gz" \
      "${BIN_DIR}/tools/kustomize.tar.gz"

# --- 4. Container images ---------------------------------------------------
# NOTE: pre-pulling container images for the air-gapped install is done
# in a later step — it needs a running containerd, which we don't have on
# a plain build machine. We leave a placeholder so the structure is clear.
info "=== Container images ==="
info "TODO: pre-pull and export kubeadm images (handled in a later step)"

# --- Record what we built --------------------------------------------------
cat > "${BIN_DIR}/MANIFEST.txt" <<EOF
Built: $(date '+%Y-%m-%d %H:%M:%S')
K8S_VERSION=${K8S_VERSION}
CONTAINERD_VERSION=${CONTAINERD_VERSION}
RUNC_VERSION=${RUNC_VERSION}
CNI_PLUGINS_VERSION=${CNI_PLUGINS_VERSION}
HELM_VERSION=${HELM_VERSION}
KUSTOMIZE_VERSION=${KUSTOMIZE_VERSION}
EOF

info "Build complete. Contents of ${BIN_DIR}:"
find "${BIN_DIR}" -type f -exec ls -lh {} \; | awk '{print "  " $5 "\t" $NF}'

