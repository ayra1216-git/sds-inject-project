#!/usr/bin/env bash
#
# deploy.sh — connect to a target machine, detect its Kubernetes role,
# and deploy the installer accordingly.
#
# Decision logic (per the assignment spec):
#   * No k8s installed   -> install MASTER, notify "only master installed"
#   * Existing master    -> leave it alone (idempotent, do not reinstall)
#   * Existing worker    -> reinstall with the NEWER k8s version
#
# Usage:
#   ./deploy.sh <installer.run> <target-host> [ssh-user]
#
# Example:
#   ./deploy.sh ./k8s-installer.run 192.168.56.101 vboxuser
#

set -Eeuo pipefail

# --- Args ------------------------------------------------------------------
INSTALLER="${1:-}"
TARGET="${2:-}"
SSH_USER="${3:-vboxuser}"

if [[ -z "$INSTALLER" || -z "$TARGET" ]]; then
  echo "Usage: $0 <installer.run> <target-host> [ssh-user]"
  exit 1
fi
if [[ ! -f "$INSTALLER" ]]; then
  echo "ERROR: installer not found: $INSTALLER"
  exit 1
fi

# --- Logging ---------------------------------------------------------------
log()    { echo "[$(date '+%Y-%m-%dT%H:%M:%S')] [$1] ${*:2}"; }
info()   { log INFO   "$@"; }
err()    { log ERROR  "$@" >&2; }
notify() { log NOTIFY "$@"; }   # mirrored to whatever notification channel

# --- SSH helper ------------------------------------------------------------
# StrictHostKeyChecking=no avoids the interactive yes/no prompt on first
# connect. ConnectTimeout caps how long we wait if the target is offline.
SSH_OPTS=(-o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes)

ssh_run()  { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${TARGET}" "$@"; }
scp_to()   { scp "${SSH_OPTS[@]}" "$1" "${SSH_USER}@${TARGET}:$2"; }

# --- ERR trap --------------------------------------------------------------
trap 'err "deploy.sh failed at line $LINENO"; exit 1' ERR

info "=== Deploying ${INSTALLER} to ${SSH_USER}@${TARGET} ==="

# ---------------------------------------------------------------------------
# 1. Confirm target is reachable
# ---------------------------------------------------------------------------
info "Checking SSH connectivity to ${TARGET}..."
if ! ssh_run "echo ok" >/dev/null; then
  err "Cannot SSH to ${SSH_USER}@${TARGET}. Suggestion: verify host, user, and SSH key."
  exit 1
fi
info "SSH reachable."

# ---------------------------------------------------------------------------
# 2. Detect the target's current Kubernetes role.
#
#    We run a small bash snippet on the target that prints one of:
#      master | worker | none
#
#    Detection rules:
#      * kube-apiserver static-pod manifest -> master (the canonical sign)
#      * kubelet.conf present but no apiserver manifest -> worker
#      * neither -> no k8s installed
# ---------------------------------------------------------------------------
info "Detecting role on target..."
ROLE="$(ssh_run '
  if [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
    echo master
  elif [[ -f /etc/kubernetes/kubelet.conf ]]; then
    echo worker
  else
    echo none
  fi
')"

info "Detected role: ${ROLE}"

# ---------------------------------------------------------------------------
# 3. Copy the installer to the target (always — needed for install/upgrade)
# ---------------------------------------------------------------------------
REMOTE_PATH="/tmp/k8s-installer.run"
info "Copying installer to ${TARGET}:${REMOTE_PATH}..."
scp_to "$INSTALLER" "$REMOTE_PATH"
ssh_run "chmod +x ${REMOTE_PATH}"

# ---------------------------------------------------------------------------
# 4. Branch on the detected role
# ---------------------------------------------------------------------------
case "$ROLE" in
  none)
    info "No Kubernetes detected. Installing MASTER."
    ssh_run "sudo ${REMOTE_PATH} -- --role master"
    notify "Only MASTER was installed on ${TARGET}. No worker was provisioned."
    ;;

  master)
    # The spec says: "only if the node is worker node it should reinstall".
    # So an existing master is intentionally left alone.
    info "Existing MASTER detected. Leaving it alone (per spec)."
    notify "Skipped ${TARGET}: already a master, no action taken."
    ;;

  worker)
    info "Existing WORKER detected. Reinstalling with newer k8s version."
    # The installer's install_worker is idempotent on kubelet.conf, so we
    # explicitly reset the worker first so the newer-version reinstall
    # actually replaces things.
    ssh_run "sudo kubeadm reset -f || true"
    ssh_run "sudo rm -rf /usr/local/bin/kubeadm /usr/local/bin/kubelet /usr/local/bin/kubectl /etc/kubernetes /var/lib/kubelet"
    ssh_run "sudo ${REMOTE_PATH} -- --role worker"
    notify "Worker on ${TARGET} reinstalled with newer Kubernetes version."
    ;;

  *)
    err "Unknown role detected: '${ROLE}'"
    exit 1
    ;;
esac

# ---------------------------------------------------------------------------
# 5. Clean up the remote installer (optional but tidy)
# ---------------------------------------------------------------------------
ssh_run "rm -f ${REMOTE_PATH}" || true

info "=== Deployment complete (role=${ROLE}) ==="
