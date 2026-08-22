{ inputs, ... }:
{
  perSystem =
    { system, ... }:
    let
      pkgs = import inputs.nixpkgs {
        inherit system;
        config.allowUnfree = true;
      };
      terraform = inputs.nixpkgs-terraform.packages.${system}."terraform-1.14.4";

      bootstrapCore = pkgs.writeShellApplication {
        name = "homelab-bootstrap-core";
        runtimeInputs = [
          pkgs.bash
          pkgs.coreutils
          pkgs.git
          pkgs.gnupg
          pkgs.kubectl
          pkgs.kubernetes-helm
          pkgs.sops
          pkgs.talhelper
          pkgs.talosctl
          pkgs.yq-go
          terraform
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

          if ! sops filestatus "''${TALOS_DIR}/talsecret.sops.yaml" | yq -e '.encrypted == true' >/dev/null; then
            printf 'talos/talsecret.sops.yaml must be encrypted with SOPS.\n' >&2
            exit 1
          fi
          (
            cd "''${TALOS_DIR}"
            talhelper genconfig \
              --secret-file talsecret.sops.yaml \
              --env-file talenv.yaml \
              --offline-mode \
              --no-gitignore
          )
          export TALOSCONFIG="''${TALOS_DIR}/clusterconfig/talosconfig"

          terraform -chdir="''${REPO_ROOT}/terraform/proxmox/k8s" init
          terraform -chdir="''${REPO_ROOT}/terraform/proxmox/k8s" apply

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

      checks.bootstrap = bootstrap;
    };
}
