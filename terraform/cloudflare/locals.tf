locals {
  domain = "constantan.dev"

  # VPS (OCI homelab-gateway)
  vps_ip = "217.142.228.246"

  # Game server DNS records
  # external: VPS IP (public access via VPS gateway)
  # internal: managed by external-dns via mc-router Service annotation
  minecraft_servers = {
    gtnh = {}
    sb4  = {}
  }
}
