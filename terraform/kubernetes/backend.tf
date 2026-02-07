terraform {
  backend "gcs" {
    bucket = "constantan-homelab-tfstate"
    prefix = "kubernetes/terraform.tfstate"
  }
}
