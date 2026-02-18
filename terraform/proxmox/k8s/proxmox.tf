# Talos Linux nocloud ISO（Secure Boot 対応）
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  for_each = local.node_list

  node_name    = each.value.name
  datastore_id = each.value.datastore_id
  content_type = "iso"
  url          = "https://factory.talos.dev/image/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515/v1.12.2/nocloud-amd64-secureboot.iso"
  file_name    = "talos-v1.12.2-nocloud-amd64-secureboot.iso"
}

resource "proxmox_virtual_environment_vm" "talos" {
  for_each = local.vm_list

  name      = each.key
  node_name = each.value.node_name
  vm_id     = each.value.vm_id

  agent {
    enabled = true
  }

  # UEFI ブート設定
  bios    = "ovmf"
  machine = "q35"

  # Secure Boot: 鍵を事前登録しない（セットアップモードで起動し、Talos が自動登録する）
  efi_disk {
    datastore_id      = local.node_list[each.value.node_name].datastore_id
    type              = "4m"
    pre_enrolled_keys = false
  }

  cpu {
    cores = each.value.cpu_cores
    type  = "host"
  }
  memory {
    dedicated = each.value.memory
  }

  # Talos ISO（初回インストール用）
  # Secure Boot では IDE が使えないため SATA バスを使用
  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_iso[each.value.node_name].id
    interface = "sata0"
  }

  # ディスク優先でブート（インストール後はディスクから起動）
  boot_order = ["scsi0", "sata0"]

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

  # ネットワーク設定（nocloud）
  # Secure Boot では IDE が使えないため SATA バスを使用
  initialization {
    datastore_id = local.node_list[each.value.node_name].datastore_id
    interface    = "sata1"
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
