{ inputs, ... }:
{
  perSystem =
    { pkgs, system, ... }:
    {
      devShells.default = pkgs.mkShell {
        packages = [
          inputs.deploy-rs.packages.${system}.default
          inputs.nixpkgs-terraform.packages.${system}."terraform-1.14.4"
          pkgs.go
          pkgs.google-cloud-sdk
          pkgs.linode-cli
          (pkgs.callPackage ../packages/kubectl.nix { })
          pkgs.kubelogin-oidc
          pkgs.kubernetes-helm
          pkgs.mcstatus
          pkgs.talosctl
          pkgs.talhelper
          pkgs.fluxcd
          pkgs.gnupg
          inputs.system-manager.packages.${system}.default
          pkgs.jq
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
        '';
      };

      formatter = pkgs.nixfmt;
    };
}
