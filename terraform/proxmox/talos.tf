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
          disk = "/dev/sda"
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
}

# Control Plane でクラスター初期化
resource "talos_machine_bootstrap" "this" {
  client_configuration = talos_machine_secrets.this.client_configuration
  node                 = local.vm_list["k8s-cp"].ip

  depends_on = [talos_machine_configuration_apply.nodes]
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
}

# 出力
output "talosconfig" {
  value     = data.talos_client_configuration.this.talos_config
  sensitive = true
}

output "kubeconfig" {
  value     = talos_cluster_kubeconfig.this.kubeconfig_raw
  sensitive = true
}
