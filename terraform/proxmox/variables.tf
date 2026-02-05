variable "api_token" {
  type = string
}

variable "proxmox" {
  default = {
    subnet_mask = 20 # 255.255.240.0
    admin = {
      username = "root"
      key      = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEo+UB0bD4lNf31i7E0hPwt7/k8TwBsQzB/G4Wjb8ww0"
    }
  }
}

variable "node_list" {
  default = {
    "pve01" = {
      name         = "pve01"
      ip           = "192.168.1.1"
      datastore_id = "local"
    }
  }
}

variable "vm_common" {
  default = {
    image_url        = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
    username         = "cloudinit"
    public_key       = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICbFDAA+TFC77qh34llAGu80bDkt3sllBns1DCluddbl"
    private_key_path = "./keys/id_ed25519"
  }
}
