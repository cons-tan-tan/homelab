locals {
  project_id = "constantan-homelab"
  region     = "asia-northeast1"
  wifconfig  = yamldecode(file("${path.module}/wif-config.yaml"))
}
