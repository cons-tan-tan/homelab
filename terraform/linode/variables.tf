variable "nixos_image_path" {
  description = "Path to the gzip-compressed raw NixOS image built for Linode."
  type        = string
  default     = "../../result/homelab-gateway-nixos.img.gz"

  validation {
    condition     = endswith(var.nixos_image_path, ".img.gz")
    error_message = "nixos_image_path must point to a .img.gz file."
  }
}
