provider "linode" {
  # linode-cli configure で作成したブラウザ認証済みプロファイルを共有する。
  config_path    = pathexpand("~/.config/linode-cli")
  config_profile = "constantan"

  # ローカルファイルからのCustom Imageアップロードに必要。
  api_version = "v4beta"
}
