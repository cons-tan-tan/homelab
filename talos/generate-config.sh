#!/usr/bin/env bash
set -euo pipefail
umask 077

talos_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
output_dir=${1:-clusterconfig}
cd "$talos_dir"

talhelper genconfig \
  --secret-file talsecret.sops.yaml \
  --env-file talenv.yaml \
  --offline-mode \
  --no-gitignore \
  --out-dir "$output_dir"

for machine_config in "$output_dir"/*.yaml; do
  if [[ "$(yq '.kind' "$machine_config")" == *KubeEtcdEncryptionConfig* ]]; then
    # Existing Secrets use key2. Talos 1.14 generates key1 for the same key
    # material, so preserve both names and continue writing with key2.
    yq -e 'select(.kind == "KubeEtcdEncryptionConfig") |
      .config.resources[0].providers[0].secretbox.keys |
      ((length == 1) and (.[0].name == "key1") and (.[0].secret != null))' \
      "$machine_config" >/dev/null
    yq -i 'with(select(.kind == "KubeEtcdEncryptionConfig");
      .config.resources[0].providers[0].secretbox.keys = [
        {"name": "key2", "secret": .config.resources[0].providers[0].secretbox.keys[0].secret},
        {"name": "key1", "secret": .config.resources[0].providers[0].secretbox.keys[0].secret}
      ])' "$machine_config"
  fi
  talosctl validate --config "$machine_config" --mode metal
done
