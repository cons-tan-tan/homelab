data "cloudflare_zone" "this" {
  filter = {
    name = local.domain
  }
}

# External access: *.constantan.dev -> VPS IP
resource "cloudflare_dns_record" "minecraft_external" {
  for_each = local.minecraft_servers

  zone_id = data.cloudflare_zone.this.zone_id
  name    = each.key
  type    = "A"
  content = local.vps_ip
  ttl     = 1 # automatic
  proxied = false
}
