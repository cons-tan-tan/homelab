terraform {
  required_version = "1.14.4"

  required_providers {
    tailscale = {
      source  = "tailscale/tailscale"
      version = "0.28.0"
    }
  }
}
