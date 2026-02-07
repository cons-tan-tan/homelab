provider "proxmox" {
  endpoint = "https://${local.node_list.pve01.ip}:8006/"
  insecure = true
}
