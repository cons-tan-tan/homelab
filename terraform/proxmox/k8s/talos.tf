resource "talos_machine_configuration_apply" "nodes" {
  for_each = local.vm_list

  node     = each.value.ip
  endpoint = each.value.ip

  client_configuration_wo = local.talos_client_configuration
  machine_configuration_input_wo = sensitive(file(
    "${local.clusterconfig_dir}/${each.key}.yaml"
  ))

  # A single apply could otherwise reboot several nodes together.
  apply_mode = "staged_if_needing_reboot"

  depends_on = [proxmox_virtual_environment_vm.talos]

  lifecycle {
    precondition {
      condition     = length(local.control_plane_nodes) == 1
      error_message = "Exactly one Talos control-plane node is currently required."
    }
    replace_triggered_by = [
      proxmox_virtual_environment_vm.talos[each.key].id,
    ]
  }
}

resource "talos_machine_bootstrap" "this" {
  for_each = local.control_plane_nodes

  node     = each.value.ipAddress
  endpoint = each.value.ipAddress

  client_configuration_wo = local.talos_client_configuration

  depends_on = [talos_machine_configuration_apply.nodes]

  lifecycle {
    # Triggering on the whole VM would bootstrap etcd again on an in-place NIC change.
    replace_triggered_by = [
      proxmox_virtual_environment_vm.talos[each.key].id,
    ]
  }
}
