provider "proxmox" {
  endpoint  = "https://${var.node_list.pve01.ip}:8006/"
  api_token = var.api_token
  insecure  = true
  ssh {
    username = var.proxmox.admin.username
    agent    = true
  }
}

locals {
  vm_list = {
    "k8s-cp" = {
      node_name = var.node_list.pve01.name
      vm_id     = 1001
      cpu_cores = 2
      memory    = 8192
      disk_size = 30
      ip        = "192.168.2.11"
    }
    "k8s-wk" = {
      node_name = var.node_list.pve01.name
      vm_id     = 1101
      cpu_cores = 6
      memory    = 16384
      disk_size = 30
      ip        = "192.168.2.21"
    }
  }
  bootstrap_cmd = <<-EOF
  runcmd:
    - sudo apt -y install software-properties-common
    - sudo apt-add-repository -y --update ppa:ansible/ansible
    - sudo apt -y install ansible
    - cd /home/${var.vm_common.username}
    - git clone https://github.com/cons-tan-tan/home_infra.git
  EOF
}

resource "proxmox_virtual_environment_vm" "k8s-vm" {
  for_each = local.vm_list

  # VMの基本設定
  name      = each.key
  node_name = each.value.node_name
  vm_id     = each.value.vm_id

  # VMのハードウェア設定
  cpu {
    cores = each.value.cpu_cores
  }
  memory {
    dedicated = each.value.memory
  }
  scsi_hardware = "virtio-scsi-pci"
  disk {
    interface    = "scsi0"
    datastore_id = var.node_list[each.value.node_name].datastore_id
    size         = each.value.disk_size
    file_id      = proxmox_virtual_environment_download_file.ubuntu-cloud-image.id
  }
  network_device {
    model  = "virtio"
    bridge = "vmbr0"
  }

  # CloudInitの設定
  initialization {
    datastore_id = var.node_list[each.value.node_name].datastore_id
    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.proxmox.subnet_mask}"
        gateway = var.node_list[each.value.node_name].ip
      }
    }
    dns {
      domain  = data.proxmox_virtual_environment_dns.dns[each.value.node_name].domain
      servers = data.proxmox_virtual_environment_dns.dns[each.value.node_name].servers
    }
    user_data_file_id = proxmox_virtual_environment_file.cloud-config[each.key].id
  }

  provisioner "file" {
    source      = var.vm_common.private_key_path
    destination = "/home/${var.vm_common.username}/.ssh/id_ed25519"
    connection {
      user        = var.vm_common.username
      private_key = file(var.vm_common.private_key_path)
      host        = each.value.ip
    }
  }
}

resource "proxmox_virtual_environment_download_file" "ubuntu-cloud-image" {
  node_name    = var.node_list.pve01.name
  datastore_id = var.node_list.pve01.datastore_id
  url          = var.vm_common.image_url
  content_type = "iso"
}

resource "proxmox_virtual_environment_file" "cloud-config" {
  for_each     = local.vm_list
  content_type = "snippets"
  node_name    = var.node_list.pve01.name
  datastore_id = var.node_list.pve01.datastore_id

  source_raw {
    file_name = "cloud-config-${each.key}.yaml"
    data      = <<-EOF
    #cloud-config
    users:
      - name: ${var.vm_common.username}
        groups:
          - sudo
        ssh_authorized_keys:
          - ${var.vm_common.public_key}
          - ${var.proxmox.admin.key}
        sudo: ALL=(ALL) NOPASSWD:ALL
        shell: /bin/bash
    package_upgrade: true
    packages:
      - neofetch
    ${each.key == "k8s-cp" ? local.bootstrap_cmd : ""}
    EOF
  }
}

data "proxmox_virtual_environment_dns" "dns" {
  for_each  = var.node_list
  node_name = each.value.name
}
