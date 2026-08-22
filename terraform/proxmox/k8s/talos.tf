resource "talos_machine_configuration_apply" "nodes" {
  for_each = local.vm_list

  node     = each.value.ip
  endpoint = each.value.ip

  client_configuration_wo = local.talos_client_configuration
  machine_configuration_input_wo = sensitive(file(
    "${local.clusterconfig_dir}/${each.key}.yaml"
  ))

  # Apply changes which need a reboot on the next explicit reboot instead of
  # restarting multiple nodes during a Terraform run.
  apply_mode = "staged_if_needing_reboot"

  depends_on = [proxmox_virtual_environment_vm.talos]

  lifecycle {
    precondition {
      condition     = length(local.control_plane_names) == 1
      error_message = "Exactly one Talos control-plane node is currently required."
    }
    replace_triggered_by = [
      proxmox_virtual_environment_vm.talos[each.key].mac_addresses,
    ]
  }
}

resource "talos_machine_bootstrap" "this" {
  # This repository currently models one bootstrap target and one control plane.
  for_each = local.control_plane_nodes

  node     = each.value.ipAddress
  endpoint = each.value.ipAddress

  client_configuration_wo = local.talos_client_configuration

  depends_on = [talos_machine_configuration_apply.nodes]

  lifecycle {
    replace_triggered_by = [
      proxmox_virtual_environment_vm.talos[each.key].mac_addresses,
    ]
  }
}
