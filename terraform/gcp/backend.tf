terraform {
  backend "gcs" {
    bucket = "constantan-homelab-tfstate"
    prefix = "gcp/terraform.tfstate"
  }
}
