# PVE also needs a commit after the last zone has been deleted.
resource "proxmox_virtual_environment_sdn_applier" "finalizer" {
  on_create  = false
  on_destroy = true
}

resource "proxmox_virtual_environment_sdn_zone_simple" "nodes" {
  for_each = local.node_list

  id    = "z${each.key}"
  nodes = [each.key]
  # An implicit zero here produces an invalid dnsmasq RA configuration.
  mtu  = 1500
  ipam = "pve"
  dhcp = "dnsmasq"

  depends_on = [proxmox_virtual_environment_sdn_applier.finalizer]
}

resource "proxmox_virtual_environment_sdn_vnet" "nodes" {
  for_each = local.node_list

  id   = each.value.vnet
  zone = proxmox_virtual_environment_sdn_zone_simple.nodes[each.key].id
}

resource "proxmox_virtual_environment_sdn_subnet" "nodes" {
  for_each = local.node_list

  cidr    = each.value.subnet
  vnet    = proxmox_virtual_environment_sdn_vnet.nodes[each.key].id
  gateway = each.value.gateway
  dhcp_range = {
    start_address = cidrhost(each.value.subnet, 10)
    end_address   = cidrhost(each.value.subnet, -2)
  }

  lifecycle {
    precondition {
      condition = (
        cidrnetmask(each.value.subnet) == "255.255.255.0" &&
        each.value.subnet == cidrsubnet(each.value.subnet, 0, 0) &&
        length(distinct(local.host_subnets)) == length(local.host_subnets)
      )
      error_message = "Each Proxmox host needs a distinct IPv4 /24 subnet written with its network address."
    }
    precondition {
      condition = (
        local.node_prefix <= 24 &&
        cidrsubnet("${cidrhost(each.value.subnet, 0)}/${local.node_prefix}", 0, 0) == local.node_network.cidr
      )
      error_message = "The VNet subnet for ${each.key} must fit inside the node network ${local.node_network.cidr}."
    }
  }
}

# Resource collection triggers alone miss hosts added to or removed from for_each.
resource "terraform_data" "sdn_hosts" {
  input = { for host, subnet in proxmox_virtual_environment_sdn_subnet.nodes : host => subnet.id }
}

resource "proxmox_virtual_environment_sdn_applier" "nodes" {
  on_destroy = false

  lifecycle {
    replace_triggered_by = [
      terraform_data.sdn_hosts,
      proxmox_virtual_environment_sdn_zone_simple.nodes,
      proxmox_virtual_environment_sdn_vnet.nodes,
      proxmox_virtual_environment_sdn_subnet.nodes,
    ]
  }

  depends_on = [proxmox_virtual_environment_sdn_subnet.nodes]
}
