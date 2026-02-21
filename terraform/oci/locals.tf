locals {
  tenancy_id     = "ocid1.tenancy.oc1..aaaaaaaapdzhrkgisyngkuj65ithxp2f3u6wlamvixj22palojm5o5o7btiq"
  compartment_id = local.tenancy_id
  region         = "ap-osaka-1"
  name           = "homelab-gateway"

  vcn = {
    cidr_block = "10.0.0.0/16"
    dns_label  = "vcn12020406"
  }

  subnet = {
    cidr_block = "10.0.0.0/24"
    dns_label  = "subnet12020406"
  }

  availability_domain = "jRXt:AP-OSAKA-1-AD-1"

  # VPS gateway: game server ports to expose
  gateway_tcp_ports = [
    25565, # Minecraft
  ]

  # Tailscale P2P direct connection
  tailscale_udp_port = 41641
}
