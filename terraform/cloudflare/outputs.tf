output "kubectl_oidc_issuer_url" {
  description = "OIDC issuer URL for kubectl / k8s API server (Cloudflare Access for SaaS per-app path)"
  value       = "https://${local.cf_team_domain}/cdn-cgi/access/sso/oidc/${cloudflare_zero_trust_access_application.kubectl.saas_app.client_id}"
}

output "kubectl_oidc_client_id" {
  description = "OIDC client ID for kubelogin (PKCE, no secret needed)"
  value       = cloudflare_zero_trust_access_application.kubectl.saas_app.client_id
}

output "kubectl_oidc_client_secret" {
  description = "OIDC client secret (unused with PKCE, exposed for completeness)"
  value       = cloudflare_zero_trust_access_application.kubectl.saas_app.client_secret
  sensitive   = true
}
