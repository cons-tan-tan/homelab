# Flux v2（初回インストール用）
resource "helm_release" "flux" {
  name             = "flux2"
  repository       = "oci://ghcr.io/fluxcd-community/charts"
  chart            = "flux2"
  namespace        = "flux-system"
  create_namespace = true

  depends_on = [helm_release.cilium]
}

# Flux の初期同期設定（GitRepository + Kustomization）
# kubernetes_manifest は CRD が plan 時に存在する必要があり、
# クリーンビルド時にべき等性が壊れるため kubectl apply を使用する
resource "null_resource" "flux_sync" {
  provisioner "local-exec" {
    command     = <<-EOT
      kubectl --kubeconfig <(printenv KUBECONFIG_RAW) apply -f - <<'EOF'
      apiVersion: source.toolkit.fluxcd.io/v1
      kind: GitRepository
      metadata:
        name: homelab
        namespace: flux-system
      spec:
        interval: 5m
        url: https://github.com/cons-tan-tan/homelab.git
        ref:
          branch: main
      ---
      apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata:
        name: flux-system
        namespace: flux-system
      spec:
        interval: 10m
        sourceRef:
          kind: GitRepository
          name: homelab
        path: ./clusters/homelab
        prune: true
      EOF
    EOT
    interpreter = ["bash", "-c"]
    environment = {
      KUBECONFIG_RAW = data.terraform_remote_state.cluster.outputs.kubeconfig
    }
  }

  depends_on = [helm_release.flux]
}
