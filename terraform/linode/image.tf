resource "linode_image" "gateway" {
  label       = "${local.name}-nixos"
  description = "NixOS image for the homelab Minecraft gateway"
  region      = local.region

  file_path = abspath(pathexpand(var.nixos_image_path))

  lifecycle {
    # The custom image is only for bootstrapping. Runtime updates use deploy-rs.
    ignore_changes = [file_hash]
  }
}
