resource "linode_instance" "gateway" {
  label  = local.name
  region = local.region
  type   = "g6-nanode-1"

  image           = linode_image.gateway.id
  authorized_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKm+q7Q7YZOPoBRbEzJ7wIYKkUFrhmpIYk4PMn/obPnq"]
  kernel          = "linode/grub2"
  network_helper  = false
  disk_encryption = "enabled"
  backups_enabled = false

  firewall_id      = linode_firewall.gateway.id
  booted           = true
  watchdog_enabled = true

  lifecycle {
    prevent_destroy = true

    # These values are only used while provisioning the first disk. NixOS
    # and its SSH keys are updated in place after the initial deployment.
    ignore_changes = [image, authorized_keys]
  }
}
