locals {
  talos_dir         = "${path.module}/../../../talos"
  clusterconfig_dir = "${local.talos_dir}/clusterconfig"
  talconfig         = yamldecode(file("${local.talos_dir}/talconfig.yaml"))
  talos_nodes = {
    for node in local.talconfig.nodes : node.hostname => node
  }
  control_plane_nodes = {
    for name, node in local.talos_nodes : name => node if node.controlPlane
  }

  talosconfig = sensitive(yamldecode(file("${local.clusterconfig_dir}/talosconfig")))
  talos_context = sensitive(
    local.talosconfig.contexts[local.talosconfig.context]
  )
  talos_client_configuration = {
    ca_certificate     = local.talos_context.ca
    client_certificate = local.talos_context.crt
    client_key         = local.talos_context.key
  }

  node_network = jsondecode(file("${path.module}/../../../proxmox/node-network.json"))
  node_list    = local.node_network.hosts
  node_hosts   = transpose({ for host, spec in local.node_list : host => spec.nodes })
  node_prefix  = tonumber(split("/", local.node_network.cidr)[1])
  host_subnets = [for host in local.node_list : host.subnet]

  vm_hardware = {
    "k8s-cp-02" = {
      vm_id     = 2001
      cpu_cores = 4
      memory    = 8 * 1024
      disk_size = 50
    }
    "k8s-wk-02" = {
      vm_id          = 2101
      cpu_cores      = 10
      memory         = 72 * 1024
      disk_size      = 200
      data_disk_size = 100
    }
    "k8s-wk-01" = {
      vm_id     = 1101
      cpu_cores = 6
      memory    = 24 * 1024
      disk_size = 100
    }
  }

  talos_networks = {
    for name, node in local.talos_nodes : name => {
      addresses = flatten([
        for interface in node.networkInterfaces : interface.addresses
        if interface.interface == "ens18"
      ])
      default_gateways = flatten([
        for interface in node.networkInterfaces : [
          for route in interface.routes : route.gateway
          if route.network == "0.0.0.0/0"
        ] if interface.interface == "ens18"
      ])
    }
  }

  vm_list = {
    for name, hardware in local.vm_hardware : name => merge(hardware, {
      node_name   = one(local.node_hosts[name])
      ip          = try(local.talos_nodes[name].ipAddress, null)
      address     = try(one(local.talos_networks[name].addresses), null)
      gateway     = try(one(local.talos_networks[name].default_gateways), null)
      dns_servers = try(local.talos_nodes[name].nameservers, [])
    })
  }
}
