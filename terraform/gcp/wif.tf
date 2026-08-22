locals {
  kubernetes_wif = {
    pool_id     = local.wifconfig.poolId
    provider_id = local.wifconfig.providerId
    subject     = local.wifconfig.subject
  }
  kubernetes_wif_audience = "https://iam.googleapis.com/${google_iam_workload_identity_pool.kubernetes.name}/providers/${local.kubernetes_wif.provider_id}"
}

resource "google_iam_workload_identity_pool" "kubernetes" {
  workload_identity_pool_id = local.kubernetes_wif.pool_id
  display_name              = "Homelab Kubernetes"
  description               = "Workload identities issued by the homelab Kubernetes cluster."

  depends_on = [google_project_service.workload_identity]
}

resource "google_iam_workload_identity_pool_provider" "talos" {
  workload_identity_pool_id          = google_iam_workload_identity_pool.kubernetes.workload_identity_pool_id
  workload_identity_pool_provider_id = local.kubernetes_wif.provider_id
  display_name                       = "Homelab Talos"
  description                        = "ServiceAccount OIDC tokens issued by the homelab Talos cluster."

  attribute_mapping = {
    "google.subject" = "assertion.sub"
  }
  attribute_condition = "assertion.sub == '${local.kubernetes_wif.subject}'"

  oidc {
    issuer_uri        = local.wifconfig.issuerUri
    allowed_audiences = [local.kubernetes_wif_audience]
    jwks_json         = file("${path.module}/kubernetes-jwks.json")
  }
}
