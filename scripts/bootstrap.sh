#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TALOS_DIR="${REPO_ROOT}/talos"

git -C "${REPO_ROOT}" fetch --quiet --no-tags origin main
if
  [[ -n "$(git -C "${REPO_ROOT}" status --porcelain)" ]] ||
  [[ "$(git -C "${REPO_ROOT}" rev-parse HEAD)" != "$(git -C "${REPO_ROOT}" rev-parse FETCH_HEAD)" ]]
then
  printf 'Bootstrap requires a clean checkout at the current origin/main revision.\n' >&2
  exit 1
fi

: "${KUBERNETES_SOPS_AGE_KEY:?Run this script with secretspec run --scope bootstrap}"
kubernetes_sops_age_key="${KUBERNETES_SOPS_AGE_KEY}"
unset KUBERNETES_SOPS_AGE_KEY

temporary_directory="$(mktemp -d)"
KUBECONFIG_FILE="${temporary_directory}/admin-kubeconfig"
cleanup() {
  unset kubernetes_sops_age_key
  if [[ -f "${KUBECONFIG_FILE}" ]]; then
    truncate -s 0 "${KUBECONFIG_FILE}"
    rm -f "${KUBECONFIG_FILE}"
  fi
  rmdir "${temporary_directory}" 2>/dev/null || true
}
trap cleanup EXIT

# Render the ignored machine configurations and client credential directly
# from the committed Talhelper and SOPS sources.
if ! sops filestatus "${TALOS_DIR}/talsecret.sops.yaml" | yq -e '.encrypted == true' >/dev/null; then
  printf 'talos/talsecret.sops.yaml must be encrypted with SOPS.\n' >&2
  exit 1
fi
(
  cd "${TALOS_DIR}"
  talhelper genconfig \
    --secret-file talsecret.sops.yaml \
    --env-file talenv.yaml \
    --offline-mode \
    --no-gitignore
)
export TALOSCONFIG="${TALOS_DIR}/clusterconfig/talosconfig"

# Terraform creates the VMs, applies the rendered Talos configurations through
# write-only provider inputs, and bootstraps etcd.
terraform -chdir="${REPO_ROOT}/terraform/proxmox/k8s" init
terraform -chdir="${REPO_ROOT}/terraform/proxmox/k8s" apply

# Obtain a temporary admin kubeconfig for bootstrap operations.
talosctl kubeconfig \
  --merge=false \
  --force \
  "${KUBECONFIG_FILE}"
export KUBECONFIG="${KUBECONFIG_FILE}"

printf 'Waiting for Kubernetes API server...\n'
timeout 300 bash -c 'until kubectl get --raw /readyz &>/dev/null; do sleep 5; done'

# Install Cilium using the same values managed by Flux.
CILIUM_VERSION="$(yq '.spec.chart.spec.version' "${REPO_ROOT}/kubernetes/apps/kube-system/cilium/helmrelease.yaml")"
yq '.spec.values' "${REPO_ROOT}/kubernetes/apps/kube-system/cilium/helmrelease.yaml" | \
  helm upgrade --install cilium cilium \
    --repo https://helm.cilium.io/ \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --values - \
    --wait

# Install Flux and provide its in-cluster SOPS age key.
helm upgrade --install flux2 oci://ghcr.io/fluxcd-community/charts/flux2 \
  --version 2.19.0 \
  --namespace flux-system \
  --create-namespace \
  --wait

printf '%s\n' "${kubernetes_sops_age_key}" | \
  kubectl create secret generic sops-age \
    --namespace=flux-system \
    --from-file=age.agekey=/dev/stdin \
    --dry-run=client \
    --output=yaml | \
  kubectl apply -f -
unset kubernetes_sops_age_key

kubectl apply -f "${REPO_ROOT}/kubernetes/flux/cluster/gotk-sync.yaml"
