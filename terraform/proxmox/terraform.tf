terraform {
  required_version = "1.14.4"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.94.0"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "0.10.1"
    }
  }
}
