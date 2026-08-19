terraform {
  required_version = "1.14.4"

  required_providers {
    linode = {
      source  = "linode/linode"
      version = "4.3.0"
    }
  }
}
