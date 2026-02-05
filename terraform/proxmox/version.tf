terraform {
  backend "remote" {
    hostname     = "app.terraform.io"
    organization = "constantan"
    workspaces {
      name = "home-infra"
    }
  }
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.69.0"
    }
  }
}
