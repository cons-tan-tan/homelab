locals {
  proxmox = {
    subnet_mask = 20 # 255.255.240.0
    gateway     = "192.168.1.1"
    dns_domain  = "local"
    dns_servers = ["192.168.0.1"]
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

  vm = {
    name      = "nfs"
    node_name = "pve02"
    vm_id     = 2201
    cpu_cores = 2
    memory    = 2048
    disk_size = 200
    ip        = "192.168.2.31"
  }
}
