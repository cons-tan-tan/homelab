locals {
  kubernetes_service_account_issuer = "https://192.168.2.12:6443"
  kubernetes_wif_audience           = "https://iam.googleapis.com/${google_iam_workload_identity_pool.kubernetes.name}/providers/talos"
}

resource "google_iam_workload_identity_pool" "kubernetes" {
  workload_identity_pool_id = "homelab-k8s"
  display_name              = "Homelab Kubernetes"
  description               = "Workload identities issued by the homelab Kubernetes cluster."

  depends_on = [google_project_service.workload_identity]
}

resource "google_iam_workload_identity_pool_provider" "talos" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.kubernetes.workload_identity_pool_id
  workload_identity_pool_provider_id = "talos"
  display_name                       = "Homelab Talos"
  description                        = "ServiceAccount OIDC tokens issued by the homelab Talos cluster."

  attribute_mapping = {
    "google.subject"                 = "assertion.sub"
    "attribute.namespace"            = "assertion['kubernetes.io']['namespace']"
    "attribute.service_account_name" = "assertion['kubernetes.io']['serviceaccount']['name']"
  }
  attribute_condition = "assertion['kubernetes.io']['serviceaccount']['name'] == 'app-backup-uploader'"

  oidc {
    issuer_uri        = local.kubernetes_service_account_issuer
    allowed_audiences = [local.kubernetes_wif_audience]
    jwks_json         = file("${path.module}/kubernetes-jwks.json")
  }
}
