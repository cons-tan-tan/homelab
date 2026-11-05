# Talos Linux nocloud ISO with Secure Boot support
resource "proxmox_virtual_environment_download_file" "talos_iso" {
  for_each = local.node_list

  node_name    = each.value.name
  datastore_id = each.value.datastore_id
  content_type = "iso"
  url          = data.talos_image_factory_urls.this.urls.iso_secureboot
  file_name    = "talos-${local.talconfig.talosVersion}-nocloud-amd64-secureboot.iso"

}

resource "proxmox_virtual_environment_vm" "talos" {
  for_each = local.vm_list

  name      = each.key
  node_name = each.value.node_name
  vm_id     = each.value.vm_id

  lifecycle {
    precondition {
      condition     = toset(keys(local.talos_nodes)) == toset(keys(local.vm_hardware))
      error_message = "talconfig nodes and Proxmox VM hardware definitions must match."
    }
    precondition {
      condition = (
        each.value.address != null &&
        each.value.gateway != null &&
        length(each.value.dns_servers) > 0 &&
        try(split("/", each.value.address)[0] == each.value.ip, false)
      )
      error_message = "Each Talos node must have one ens18 address matching ipAddress, one default gateway, and at least one nameserver."
    }
  }

  agent {
    enabled = true
  }

  # UEFI boot configuration
  bios    = "ovmf"
  machine = "q35"

  # Do not pre-enroll Secure Boot keys; start in setup mode so Talos can enroll them automatically.
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

  # Talos ISO for initial installation
  # Use SATA because IDE is unavailable with Secure Boot.
  cdrom {
    file_id   = proxmox_virtual_environment_download_file.talos_iso[each.value.node_name].id
    interface = "sata0"
  }

  # Boot from disk first after installation.
  boot_order = ["scsi0", "sata0"]

  # Disk configuration
  scsi_hardware = "virtio-scsi-pci"
  disk {
    interface    = "scsi0"
    datastore_id = local.node_list[each.value.node_name].datastore_id
    size         = each.value.disk_size
    file_format  = "raw"
  }

  # Data disk for local-path-provisioner
  dynamic "disk" {
    for_each = try(each.value.data_disk_size, null) != null ? [each.value.data_disk_size] : []
    content {
      interface    = "scsi1"
      datastore_id = local.node_list[each.value.node_name].datastore_id
      size         = disk.value
      file_format  = "raw"
    }
  }

  network_device {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # Network configuration (nocloud)
  # Use SATA because IDE is unavailable with Secure Boot.
  initialization {
    datastore_id = local.node_list[each.value.node_name].datastore_id
    interface    = "sata1"
    ip_config {
      ipv4 {
        address = each.value.address
        gateway = each.value.gateway
      }
    }
    dns {
      domain  = local.proxmox.dns_domain
      servers = each.value.dns_servers
    }
  }
}
