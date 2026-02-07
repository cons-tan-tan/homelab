# Talos machine secrets（証明書・トークン等を生成）
resource "talos_machine_secrets" "this" {}

# Talos machine configuration（各ノード用）
data "talos_machine_configuration" "nodes" {
  for_each = local.vm_list

  cluster_name     = local.cluster.name
  cluster_endpoint = local.cluster.endpoint
  machine_type     = each.value.type
  machine_secrets  = talos_machine_secrets.this.machine_secrets

  config_patches = [
    yamlencode({
      machine = {
        network = {
          interfaces = [{
            interface = "ens18"
            addresses = ["${each.value.ip}/${local.proxmox.subnet_mask}"]
            routes = [{
              network = "0.0.0.0/0"
              gateway = local.proxmox.gateway
            }]
          }]
          nameservers = local.proxmox.dns_servers
        }
        install = {
          disk  = "/dev/sda"
          image = "factory.talos.dev/installer-secureboot/ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515:v1.12.2"
        }
      }
    }),
    # デフォルトの Flannel CNI と kube-proxy を無効化（Cilium で置換するため）
    yamlencode({
      cluster = {
        network = {
          cni = {
            name = "none"
          }
        }
        proxy = {
          disabled = true
        }
      }
    }),
    # Talos v1.12 では HostnameConfig (auto: stable) が自動生成される。
    # machine.network.hostname で上書きしようとすると競合エラーになるため、
    # HostnameConfig ドキュメント自体をパッチして auto: off で無効化する。
    # ref: https://github.com/siderolabs/talos/issues/12541
    yamlencode({
      apiVersion = "v1alpha1"
      kind       = "HostnameConfig"
      hostname   = each.key
      auto       = "off"
    })
  ]
}

# 各ノードに設定を適用（Talos API経由）
resource "talos_machine_configuration_apply" "nodes" {
  for_each = local.vm_list

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.nodes[each.key].machine_configuration
  node                        = each.value.ip

  depends_on = [proxmox_virtual_environment_vm.talos]

  lifecycle {
    replace_triggered_by = [proxmox_virtual_environment_vm.talos[each.key].mac_addresses]
  }
}

# Control Plane でクラスター初期化
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.vm_list["k8s-cp"].ip

  depends_on = [talos_machine_configuration_apply.nodes]

  lifecycle {
    replace_triggered_by = [talos_machine_configuration_apply.nodes["k8s-cp"].id]
  }
}

# クライアント設定（talosctl用）
data "talos_client_configuration" "this" {
  cluster_name         = local.cluster.name
  client_configuration = talos_machine_secrets.this.client_configuration
  endpoints            = [local.vm_list["k8s-cp"].ip]
  nodes                = [for k, v in local.vm_list : v.ip]
}

# kubeconfig 取得
resource "talos_cluster_kubeconfig" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.vm_list["k8s-cp"].ip

  depends_on = [talos_machine_bootstrap.this]

  lifecycle {
    replace_triggered_by = [talos_machine_bootstrap.this.id]
  }
}
