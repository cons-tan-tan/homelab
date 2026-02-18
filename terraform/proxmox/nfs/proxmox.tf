# Debian 12 (Bookworm) cloud image
resource "proxmox_virtual_environment_download_file" "debian_cloud_image" {
  node_name    = local.vm.node_name
  datastore_id = local.node_list[local.vm.node_name].datastore_id
  content_type = "iso"
  url          = "https://cloud.debian.org/images/cloud/bookworm/20260129-2372/debian-12-generic-amd64-20260129-2372.qcow2"
  file_name    = "debian-12-generic-amd64.img"
}

resource "proxmox_virtual_environment_vm" "nfs" {
  name      = local.vm.name
  node_name = local.vm.node_name
  vm_id     = local.vm.vm_id

  cpu {
    cores = local.vm.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.memory
  }

  scsi_hardware = "virtio-scsi-pci"

  disk {
    datastore_id = local.node_list[local.vm.node_name].datastore_id
    file_id      = proxmox_virtual_environment_download_file.debian_cloud_image.id
    interface    = "scsi0"
    size         = local.vm.disk_size
    file_format  = "raw"
  }

  network_device {
    model  = "virtio"
    bridge = "vmbr0"
  }

  initialization {
    datastore_id = local.node_list[local.vm.node_name].datastore_id
    user_account {
      keys     = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKm+q7Q7YZOPoBRbEzJ7wIYKkUFrhmpIYk4PMn/obPnq openpgp:0xDA49D92C"]
      username = "constantan"
    }
    ip_config {
      ipv4 {
        address = "${local.vm.ip}/${local.proxmox.subnet_mask}"
        gateway = local.proxmox.gateway
      }
    }
    dns {
      domain  = local.proxmox.dns_domain
      servers = local.proxmox.dns_servers
    }
  }

  lifecycle {
    ignore_changes = [disk[0].file_id]
  }
}
