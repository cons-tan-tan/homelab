# Talos Linux nocloud ISO
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  node_name    = local.node_list.pve01.name
  datastore_id = local.node_list.pve01.datastore_id
  content_type = "iso"
  url          = "https://factory.talos.dev/image/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515/v1.12.2/nocloud-amd64.iso"
  file_name    = "talos-v1.12.2-nocloud-amd64.iso"
}

resource "proxmox_virtual_environment_vm" "talos" {
  for_each = local.vm_list

  name      = each.key
  node_name = each.value.node_name
  vm_id     = each.value.vm_id

  # UEFI ブート設定
  bios    = "ovmf"
  machine = "q35"

  efi_disk {
    datastore_id = local.node_list[each.value.node_name].datastore_id
    type         = "4m"
  }

  cpu {
    cores = each.value.cpu_cores
    type  = "host"
  }
  memory {
    dedicated = each.value.memory
  }

  # Talos ISO（初回インストール用）
  cdrom {
    file_id = proxmox_virtual_environment_download_file.talos_iso.id
  }

  # ディスク優先でブート（インストール後はディスクから起動）
  boot_order = ["scsi0", "ide2"]

  # ディスク設定
  scsi_hardware = "virtio-scsi-pci"
  disk {
    interface    = "scsi0"
    datastore_id = local.node_list[each.value.node_name].datastore_id
    size         = each.value.disk_size
    file_format  = "raw"
  }

  network_device {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # ネットワーク設定
  initialization {
    datastore_id = local.node_list[each.value.node_name].datastore_id
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${local.proxmox.subnet_mask}"
        gateway = local.proxmox.gateway
      }
    }
    dns {
      domain  = local.proxmox.dns_domain
      servers = local.proxmox.dns_servers
    }
  }
}
