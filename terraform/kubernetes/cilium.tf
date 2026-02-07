# Cilium CNI（初回インストール用）
# Flux HelmRelease が管理を引き継いだ後は Terraform は変更を加えない
resource "helm_release" "cilium" {
  name       = "cilium"
  repository = "https://helm.cilium.io/"
  chart      = "cilium"
  version    = "1.17.1"
  namespace  = "kube-system"

  # Talos Linux 固有の設定
  set {
    name  = "ipam.mode"
    value = "kubernetes"
  }
  set {
    name  = "kubeProxyReplacement"
    value = "true"
  }

  # Talos は cgroupv2 をマウント済みのため自動マウントを無効化
  set {
    name  = "cgroup.autoMount.enabled"
    value = "false"
  }
  set {
    name  = "cgroup.hostRoot"
    value = "/sys/fs/cgroup"
  }

  # Talos KubePrism 経由で Kubernetes API にアクセス
  set {
    name  = "k8sServiceHost"
    value = "localhost"
  }
  set {
    name  = "k8sServicePort"
    value = "7445"
  }

  # Talos 向けセキュリティコンテキスト（SYS_MODULE を除外）
  set {
    name  = "securityContext.capabilities.ciliumAgent"
    value = "{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}"
  }
  set {
    name  = "securityContext.capabilities.cleanCiliumState"
    value = "{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}"
  }

  # Flux が管理を引き継いだ後の競合を防止
  lifecycle {
    ignore_changes = all
  }
}
