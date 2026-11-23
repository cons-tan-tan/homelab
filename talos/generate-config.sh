#!/usr/bin/env bash
set -euo pipefail
umask 077

talos_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
output_dir=${1:-clusterconfig}
cd "$talos_dir"

network=../proxmox/node-network.json
node_cidr=$(jq -er '.cidr' "$network")
mkdir -p "$output_dir"
temporary_dir=$(mktemp -d "$output_dir/.generate.XXXXXXXX")
trap 'rm -rf -- "$temporary_dir"' EXIT

talhelper genconfig \
  --secret-file talsecret.sops.yaml \
  --env-file talenv.yaml \
  --offline-mode \
  --no-gitignore \
  --out-dir "$temporary_dir"

for machine_config in "$temporary_dir"/*.yaml; do
  node=$(basename "$machine_config" .yaml)
  host=$(jq -ce --arg node "$node" '
    [.hosts[] | select(.nodes | index($node))] |
    if length == 1 then .[0] else error("expected one PVE host for " + $node) end
  ' "$network")
  subnet=$(jq -er '.subnet' <<< "$host")
  gateway=$(jq -er '.gateway' <<< "$host")
  SUBNET="$subnet" yq -i 'with(select(.version == "v1alpha1");
    .machine.kubelet.nodeIP.validSubnets = [strenv(SUBNET)])' "$machine_config"
  if [[ "$(yq 'select(.version == "v1alpha1") | .machine.type' "$machine_config")" == controlplane ]]; then
    lan_ip=$(NODE="$node" yq -er '.nodes[] | select(.hostname == strenv(NODE)) | .ipAddress' talconfig.yaml)
    # Existing Secrets need key2, while Talos 1.14 names the same key material key1.
    if ! yq -o=json -I=0 'select(.kind == "KubeEtcdEncryptionConfig")' "$machine_config" |
      jq -se '[.[].config.resources[] | select(.resources | index("secrets")) | .providers[0].secretbox.keys] |
        length == 1 and (.[0] | length == 1 and .[0].name == "key1" and (.[0].secret | length > 0))' >/dev/null; then
      echo "$node: expected one Secrets encryption rule with a single key named key1" >&2
      exit 1
    fi
    LAN_SUBNET="$lan_ip/32" yq -i '
      with(select(.version == "v1alpha1"); .cluster.etcd.advertisedSubnets = [strenv(LAN_SUBNET)]) |
      with(select(.kind == "KubeEtcdEncryptionConfig") | .config.resources[] |
        select(.resources | any_c(. == "secrets"));
        .providers[0].secretbox.keys |= [{"name": "key2", "secret": .[0].secret}, .[0]])
    ' "$machine_config"
  fi
  cat >> "$machine_config" <<EOF
---
apiVersion: v1alpha1
kind: LinkConfig
name: ens19
up: true
routes:
  - destination: $node_cidr
    gateway: $gateway
---
apiVersion: v1alpha1
kind: DHCPv4Config
name: ens19
clientIdentifier: mac
ignoreHostname: true
ignoreRoutes: true
EOF
  talosctl validate --config "$machine_config" --mode metal
done

mv -f -- "$temporary_dir"/*.yaml "$temporary_dir/talosconfig" "$output_dir/"
