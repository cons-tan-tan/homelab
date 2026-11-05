provider "linode" {
  # Reuse the browser-authenticated profile created by linode-cli configure.
  config_path    = pathexpand("~/.config/linode-cli")
  config_profile = "constantan"

  # Required to upload a Custom Image from a local file.
  api_version = "v4beta"
}
