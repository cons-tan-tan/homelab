locals {
  proxmox = {
    subnet_mask = 20 # 255.255.240.0
    gateway     = "192.168.1.1"
    dns_domain  = "local"
    dns_servers = ["192.168.0.1"]
  }

  cluster = {
    name     = "homelab"
    endpoint = "https://192.168.2.12:6443"
  }

  node_list = {
    "pve01" = {
      name         = "pve01"
      ip           = "192.168.1.1"
      datastore_id = "local"
    }
    "pve02" = {
      name         = "pve02"
      ip           = "192.168.1.2"
      datastore_id = "local"
    }
  }

  vm_list = {
    "k8s-cp-02" = {
      node_name = local.node_list.pve02.name
      vm_id     = 2001
      cpu_cores = 4
      memory    = 8192
      disk_size = 50
      ip        = "192.168.2.12"
      type      = "controlplane"
    }
    "k8s-wk-02" = {
      node_name = local.node_list.pve02.name
      vm_id     = 2101
      cpu_cores = 10
      memory    = 73728 # 72GB
      disk_size = 200
      ip        = "192.168.2.22"
      type      = "worker"
    }
    "k8s-wk-01" = {
      node_name = local.node_list.pve01.name
      vm_id     = 1101
      cpu_cores = 6
      memory    = 24576 # 24GB
      disk_size = 100
      ip        = "192.168.2.21"
      type      = "worker"
    }
  }
}
