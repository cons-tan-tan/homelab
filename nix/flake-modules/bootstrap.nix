{ inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    let
      clusterTerraform = pkgs.writeShellApplication {
        name = "homelab-cluster-terraform";
        runtimeInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.git
          pkgs.gnupg
          pkgs.jq
          pkgs.sops
          pkgs.talhelper
          pkgs.talosctl
          pkgs.yq-go
          inputs.nixpkgs-terraform.packages.${system}."terraform-1.14.4"
        ];
        text = ''
          cd "$(git rev-parse --show-toplevel)"
          if ! sops filestatus talos/talsecret.sops.yaml | yq -e '.encrypted == true' >/dev/null; then
            printf 'talos/talsecret.sops.yaml must be encrypted with SOPS.\n' >&2
            exit 1
          fi
          bash talos/generate-config.sh
          terraform -chdir=terraform/proxmox/k8s init -input=false
          exec terraform -chdir=terraform/proxmox/k8s "$@"
        '';
      };

      cluster = pkgs.writeShellApplication {
        name = "homelab-cluster";
        runtimeInputs = [ pkgs.secretspec ];
        text = ''
          if (( $# == 0 )); then
            set -- plan
          fi
          case "$1" in
            plan|apply) ;;
            -h|--help) echo "Usage: homelab-cluster [plan|apply] [Terraform options]"; exit 0 ;;
            *) echo "Expected plan or apply" >&2; exit 2 ;;
          esac
          exec secretspec run --scope proxmox --reason "Manage the Proxmox Kubernetes cluster" \
            -- ${pkgs.lib.getExe clusterTerraform} "$@"
        '';
      };

      bootstrapCore = pkgs.writeShellApplication {
        name = "homelab-bootstrap-core";
        runtimeInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.git
          (pkgs.callPackage ../packages/kubectl.nix { })
          pkgs.kubernetes-helm
          pkgs.talosctl
          pkgs.yq-go
        ];
        text = ''
          REPO_ROOT="$(git rev-parse --show-toplevel)"
          TALOS_DIR="''${REPO_ROOT}/talos"

          : "''${KUBERNETES_SOPS_AGE_KEY:?SecretSpec bootstrap scope did not provide KUBERNETES_SOPS_AGE_KEY}"
          kubernetes_sops_age_key="''${KUBERNETES_SOPS_AGE_KEY}"
          unset KUBERNETES_SOPS_AGE_KEY

          temporary_directory="$(mktemp -d)"
          KUBECONFIG_FILE="''${temporary_directory}/admin-kubeconfig"
          cleanup() {
            unset kubernetes_sops_age_key
            if [[ -f "''${KUBECONFIG_FILE}" ]]; then
              truncate -s 0 "''${KUBECONFIG_FILE}"
              rm -f "''${KUBECONFIG_FILE}"
            fi
            rmdir "''${temporary_directory}" 2>/dev/null || true
          }
          trap cleanup EXIT

          ${pkgs.lib.getExe clusterTerraform} apply
          export TALOSCONFIG="''${TALOS_DIR}/clusterconfig/talosconfig"

          talosctl kubeconfig \
            --merge=false \
            --force \
            "''${KUBECONFIG_FILE}"
          export KUBECONFIG="''${KUBECONFIG_FILE}"

          printf 'Waiting for Kubernetes API server...\n'
          timeout 300 bash -c 'until kubectl get --raw /readyz &>/dev/null; do sleep 5; done'

          CILIUM_VERSION="$(yq '.spec.chart.spec.version' "''${REPO_ROOT}/kubernetes/apps/kube-system/cilium/helmrelease.yaml")"
          yq '.spec.values' "''${REPO_ROOT}/kubernetes/apps/kube-system/cilium/helmrelease.yaml" | \
            helm upgrade --install cilium cilium \
              --repo https://helm.cilium.io/ \
              --version "''${CILIUM_VERSION}" \
              --namespace kube-system \
              --values - \
              --wait

          helm upgrade --install flux2 oci://ghcr.io/fluxcd-community/charts/flux2 \
            --version 2.19.0 \
            --namespace flux-system \
            --create-namespace \
            --wait

          printf '%s\n' "''${kubernetes_sops_age_key}" | \
            kubectl create secret generic sops-age \
              --namespace=flux-system \
              --from-file=age.agekey=/dev/stdin \
              --dry-run=client \
              --output=yaml | \
            kubectl apply -f -
          unset kubernetes_sops_age_key

          kubectl apply -f "''${REPO_ROOT}/kubernetes/flux/cluster/gotk-sync.yaml"
        '';
      };

      bootstrap = pkgs.writeShellApplication {
        name = "homelab-bootstrap";
        runtimeInputs = [
          pkgs.git
          pkgs.secretspec
        ];
        text = ''
          repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
            printf 'Run this app from the homelab Git checkout.\n' >&2
            exit 1
          }
          cd "$repo_root"

          git fetch --quiet --no-tags origin main
          if
            [[ -n "$(git status --porcelain)" ]] ||
            [[ "$(git rev-parse HEAD)" != "$(git rev-parse FETCH_HEAD)" ]]
          then
            printf 'Bootstrap requires a clean checkout at the current origin/main revision.\n' >&2
            exit 1
          fi

          exec secretspec run \
            --reason "Bootstrap the homelab Kubernetes cluster" \
            --profile default \
            --scope bootstrap \
            -- ${pkgs.lib.getExe bootstrapCore}
        '';
      };
    in
    {
      apps.bootstrap = {
        type = "app";
        program = pkgs.lib.getExe bootstrap;
        meta.description = "Bootstrap the homelab Kubernetes cluster";
      };
      apps.cluster = {
        type = "app";
        program = pkgs.lib.getExe cluster;
        meta.description = "Generate Talos configurations and run Terraform for the Proxmox Kubernetes cluster";
      };

      checks.cluster = cluster;
      checks.bootstrap = bootstrap;
      checks.talos-node-network =
        pkgs.runCommand "talos-node-network"
          {
            nativeBuildInputs = with pkgs; [
              jq
              talhelper
              talosctl
              yq-go
            ];
          }
          ''
            mkdir -p talos proxmox
            cp ${../../talos/talconfig.yaml} talos/talconfig.yaml
            cp ${../../talos/talenv.yaml} talos/talenv.yaml
            cp ${../../talos/generate-config.sh} talos/generate-config.sh
            cp ${../../proxmox/node-network.json} proxmox/node-network.json
            talhelper gensecret > talos/talsecret.sops.yaml
            mkdir talos/clusterconfig
            install -m 0644 /dev/null talos/clusterconfig/talosconfig
            bash talos/generate-config.sh
            test "$(stat -c %a talos/clusterconfig/talosconfig)" = 600
            for file in talos/clusterconfig/*.yaml; do
              test "$(stat -c %a "$file")" = 600
              node="$(basename "$file" .yaml)"
              yq -o=json -I=0 '.' "$file" | jq -se \
                --arg node "$node" --slurpfile inventory proxmox/node-network.json '
                $inventory[0] as $net |
                ($net.hosts[] | select(.nodes | index($node))) as $host |
                first(.[] | select(.version == "v1alpha1")) as $machine |
                first(.[] | select(.kind == "LinkConfig" and .name == "ens18")) as $lan |
                first(.[] | select(.kind == "LinkConfig" and .name == "ens19")) as $vnet |
                first(.[] | select(.kind == "DHCPv4Config" and .name == "ens19")) as $dhcp |
                $machine.machine.kubelet.nodeIP.validSubnets == [$host.subnet] and
                $vnet.routes == [{destination: $net.cidr, gateway: $host.gateway}] and
                $dhcp.clientIdentifier == "mac" and $dhcp.ignoreRoutes and $dhcp.ignoreHostname and
                ($lan.routes | any(.gateway != null)) and
                (if $machine.machine.type == "controlplane" then
                  $machine.cluster.etcd.advertisedSubnets == [($lan.addresses[0].address | split("/")[0]) + "/32"] and
                  (first(.[] | select(.kind == "KubeEtcdEncryptionConfig") | .config.resources[] |
                    select(.resources | index("secrets"))) | .providers[0].secretbox.keys |
                    map(.name) == ["key2", "key1"] and .[0].secret == .[1].secret and (.[0].secret | length > 0))
                else true end)' > /dev/null
            done
            sha256sum talos/clusterconfig/*.yaml talos/clusterconfig/talosconfig > checksums
            yq 'select(.kind == "KubeEtcdEncryptionConfig")' talos/clusterconfig/*.yaml > talos/extra-secrets-rule.yaml
            yq -i '.controlPlane.patches += ["@./extra-secrets-rule.yaml"]' talos/talconfig.yaml
            if bash talos/generate-config.sh > invalid.log 2>&1; then
              echo "Accepted overlapping Secrets encryption rules" >&2
              exit 1
            fi
            grep -F 'expected one Secrets encryption rule with a single key named key1' invalid.log
            sha256sum --check checksums
            touch "$out"
          '';
    };
}
