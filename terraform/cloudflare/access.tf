resource "cloudflare_zero_trust_access_identity_provider" "github" {
  account_id = local.cf_account_id
  name       = "GitHub"
  type       = "github"
  config = {
    client_id     = local.github_oauth_client_id
    client_secret = data.sops_file.secrets.data["github_oauth_client_secret"]
  }
}

resource "cloudflare_zero_trust_access_policy" "kubectl" {
  account_id = local.cf_account_id
  name       = "kubectl-allowed-users"
  decision   = "allow"

  include = [
    for email in local.kubectl_allowed_emails : {
      email = {
        email = email
      }
    }
  ]
}

resource "cloudflare_zero_trust_access_application" "kubectl" {
  account_id           = local.cf_account_id
  name                 = "kubectl"
  type                 = "saas"
  app_launcher_visible = false
  allowed_idps         = [cloudflare_zero_trust_access_identity_provider.github.id]
  session_duration     = "24h"

  saas_app = {
    auth_type                        = "oidc"
    redirect_uris                    = local.oidc_redirect_uris
    grant_types                      = ["authorization_code", "authorization_code_with_pkce", "refresh_tokens"]
    scopes                           = ["openid", "email", "profile", "groups"]
    allow_pkce_without_client_secret = true
    refresh_token_options = {
      lifetime = "24h"
    }
  }

  policies = [{
    id         = cloudflare_zero_trust_access_policy.kubectl.id
    precedence = 1
  }]
}
