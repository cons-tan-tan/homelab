#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# 1. Proxmox/Talos クラスタ構築
terraform -chdir="${REPO_ROOT}/terraform/proxmox/k8s" init
terraform -chdir="${REPO_ROOT}/terraform/proxmox/k8s" apply -auto-approve

# 2. kubeconfig 取得
KUBECONFIG_FILE=$(mktemp)
trap 'rm -f "${KUBECONFIG_FILE}"' EXIT
terraform -chdir="${REPO_ROOT}/terraform/proxmox/k8s" output -raw kubeconfig > "${KUBECONFIG_FILE}"
export KUBECONFIG="${KUBECONFIG_FILE}"

# 3. Kubernetes API サーバーの起動を待機
echo "Waiting for Kubernetes API server..."
timeout 300 bash -c 'until kubectl get --raw /readyz &>/dev/null; do sleep 5; done'

# 4. Cilium CNI インストール（values は Flux HelmRelease から抽出）
CILIUM_VERSION=$(yq '.spec.chart.spec.version' "${REPO_ROOT}/infrastructure/controllers/cilium.yaml")
helm repo add cilium https://helm.cilium.io/ --force-update
yq '.spec.values' "${REPO_ROOT}/infrastructure/controllers/cilium.yaml" | \
  helm install cilium cilium/cilium \
    --version "${CILIUM_VERSION}" \
    --namespace kube-system \
    --values - \
    --wait

# 5. Flux インストール
helm install flux2 oci://ghcr.io/fluxcd-community/charts/flux2 \
  --namespace flux-system \
  --create-namespace \
  --wait

# 6. SOPS 復号用の age 鍵を Flux に登録
kubectl create secret generic sops-age \
  --namespace=flux-system \
  --from-file=age.agekey="${REPO_ROOT}/keys.txt"

# 7. Flux 同期設定を適用
kubectl apply -f "${REPO_ROOT}/clusters/homelab/gotk-sync.yaml"
