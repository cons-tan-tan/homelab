resource "linode_firewall" "gateway" {
  label = local.name

  inbound_policy  = "DROP"
  outbound_policy = "ACCEPT"

  inbound {
    label    = "allow-ssh"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "22"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "allow-wireguard"
    action   = "ACCEPT"
    protocol = "UDP"
    ports    = "51820"
    ipv4     = ["0.0.0.0/0"]
  }

  # Path MTU Discovery and basic network diagnostics.
  inbound {
    label    = "allow-icmp"
    action   = "ACCEPT"
    protocol = "ICMP"
    ipv4     = ["0.0.0.0/0"]
    ipv6     = ["::/0"]
  }

  inbound {
    label    = "allow-minecraft"
    action   = "ACCEPT"
    protocol = "TCP"
    ports    = "25565"
    ipv4     = ["0.0.0.0/0"]
  }
}
