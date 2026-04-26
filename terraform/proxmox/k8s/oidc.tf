locals {
  kubeconfig_oidc = templatefile("${path.module}/templates/kubeconfig-oidc.yaml.tftpl", {
    cluster_name       = local.cluster.name
    api_endpoint       = local.cluster.endpoint
    ca_certificate_b64 = talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate
    oidc_issuer_url    = local.oidc.issuer_url
    oidc_client_id     = local.oidc.client_id
  })
}

resource "local_file" "kubeconfig_oidc" {
  filename        = "${path.module}/../../../.kubeconfig"
  content         = local.kubeconfig_oidc
  file_permission = "0644"
}
