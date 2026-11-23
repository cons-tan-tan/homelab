locals {
  node_list = jsondecode(file("${path.module}/../../../proxmox/node-network.json")).hosts

  vm = {
    name      = "nfs"
    node_name = "pve02"
    vm_id     = 2201
    cpu_cores = 2
    memory    = 8192
    disk_size = 200
  }
}
