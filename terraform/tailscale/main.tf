resource "tailscale_acl" "this" {
  acl = jsonencode({
    tagOwners = {
      (local.tags.k8s_operator) = []
      (local.tags.k8s)          = [local.tags.k8s_operator]
    }

    acls = [
      {
        action = "accept"
        src    = ["*"]
        dst    = ["*:*"]
      }
    ]
  })

  overwrite_existing_content = true
}

resource "tailscale_oauth_client" "k8s_operator" {
  description = "homelab k8s operator"
  scopes      = ["devices:core", "auth_keys"]
  tags        = [local.tags.k8s_operator]
}
