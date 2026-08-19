resource "proxmox_virtual_environment_vm" "nfs" {
  name       = local.vm.name
  node_name  = local.vm.node_name
  vm_id      = local.vm.vm_id
  boot_order = ["scsi0", "net0"]
  on_boot    = true
  protection = true
  started    = true

  delete_unreferenced_disks_on_destroy = false
  stop_on_destroy                      = true

  agent {
    enabled = true
  }

  cpu {
    cores = local.vm.cpu_cores
    type  = "host"
  }

  memory {
    dedicated = local.vm.memory
  }

  operating_system {
    type = "l26"
  }

  scsi_hardware = "virtio-scsi-pci"

  serial_device {}

  disk {
    datastore_id      = local.node_list[local.vm.node_name].datastore_id
    discard           = "on"
    file_format       = "raw"
    interface         = "scsi0"
    path_in_datastore = "${local.vm.vm_id}/vm-${local.vm.vm_id}-disk-1.raw"
    size              = local.vm.disk_size
  }

  network_device {
    model  = "virtio"
    bridge = "vmbr0"
  }

  lifecycle {
    prevent_destroy = true
  }
}
