locals {
  domain = "constantan.dev"

  # Public Minecraft gateway (Linode homelab-gateway)
  minecraft_gateway_ip = "172.235.215.105"

  # Game server DNS records
  # external: gateway IP (public access via Linode gateway)
  # internal: managed by external-dns via mc-router Service annotation
  minecraft_servers = {
    gtnh = {}
    sb4  = {}
  }

  # Cloudflare Zero Trust
  cf_team_domain = "constantan.cloudflareaccess.com"
  cf_account_id  = data.cloudflare_zone.this.account.id

  # GitHub OAuth App (client_id is a public identifier per OAuth 2.0)
  github_oauth_client_id = "Ov23liIp9IkLudXtWRb1"

  # kubelogin local callback ports
  oidc_redirect_uris = [
    "http://localhost:8000",
    "http://localhost:18000",
  ]

  # Allowed users for kubectl access
  kubectl_allowed_emails = [
    "zhouchengt@gmail.com",
  ]
}
