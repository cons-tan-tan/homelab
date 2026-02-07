locals {
  proxmox = {
    subnet_mask = 20 # 255.255.240.0
    gateway     = "192.168.1.1"
    dns_domain  = "local"
    dns_servers = ["192.168.0.1"]
  }

  cluster = {
    name     = "homelab"
    endpoint = "https://192.168.2.11:6443"
  }

  node_list = {
    "pve01" = {
      name         = "pve01"
      ip           = "192.168.1.1"
      datastore_id = "local"
    }
  }

  vm_list = {
    "k8s-cp" = {
      node_name = local.node_list.pve01.name
      vm_id     = 1001
      cpu_cores = 2
      memory    = 8192
      disk_size = 30
      ip        = "192.168.2.11"
      type      = "controlplane"
    }
    "k8s-wk" = {
      node_name = local.node_list.pve01.name
      vm_id     = 1101
      cpu_cores = 6
      memory    = 16384
      disk_size = 30
      ip        = "192.168.2.21"
      type      = "worker"
    }
  }
}
