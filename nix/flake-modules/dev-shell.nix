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
    in
    {
      devShells.default = pkgs.mkShell {
        packages = [
          inputs.deploy-rs.packages.${system}.default
          terraform
          pkgs.google-cloud-sdk
          pkgs.linode-cli
          pkgs.kubectl
          pkgs.kubelogin-oidc
          pkgs.kubernetes-helm
          pkgs.mcstatus
          pkgs.talosctl
          pkgs.talhelper
          pkgs.fluxcd
          pkgs.gnupg
          # Keep Ansible dependencies out of the main Python environment.
          (pkgs.python3.withPackages (ps: [ ps.ansible-core ]))
          pkgs.sops
          pkgs.secretspec
          pkgs.age
          pkgs.ssh-to-age
          pkgs.wireguard-tools
          pkgs.yq-go
        ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          pkgs.proxmox-auto-install-assistant
        ];

        CLOUDSDK_ACTIVE_CONFIG_NAME = "personal";

        shellHook = ''
          repo_root="$(git rev-parse --show-toplevel)"
          export KUBECONFIG="$repo_root/.kubeconfig"
          export TALOSCONFIG="$repo_root/talos/clusterconfig/talosconfig"
          unset repo_root

          if secretspec_exports="$(${pkgs.lib.getExe pkgs.secretspec} export --reason "Load homelab development environment" --profile default --scope dev-shell)"; then
            eval "$secretspec_exports"
          fi
          unset secretspec_exports
        '';
      };

      formatter = pkgs.nixfmt;
    };
}
