terraform {
  required_version = "1.14.4"

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "8.2.0"
    }
  }
}
