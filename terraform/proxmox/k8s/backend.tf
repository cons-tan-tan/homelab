terraform {
  backend "gcs" {
    bucket = "constantan-homelab-tfstate"
    prefix = "proxmox/k8s"
  }
}
