resource "talos_image_factory_schematic" "this" {
  schematic = yamlencode(local.talconfig.controlPlane.imageSchematic)

  lifecycle {
    precondition {
      condition     = local.talconfig.controlPlane.imageSchematic == local.talconfig.worker.imageSchematic
      error_message = "Control-plane and worker boot-image schematics must match because the Proxmox ISO is shared."
    }
    precondition {
      condition = alltrue([
        for node in values(local.talos_nodes) : try(
          node.machineSpec.mode == "metal" &&
          node.machineSpec.arch == "amd64" &&
          node.machineSpec.secureboot == true &&
          node.machineSpec.bootMethod == "iso",
          false,
        )
      ])
      error_message = "Every Talos node must use metal mode, amd64, Secure Boot, and ISO boot to match the shared Proxmox image."
    }
  }
}

data "talos_image_factory_urls" "this" {
  talos_version = local.talconfig.talosVersion
  schematic_id  = talos_image_factory_schematic.this.id
  platform      = "nocloud"
  architecture  = "amd64"
}
