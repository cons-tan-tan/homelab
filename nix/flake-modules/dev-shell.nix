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
          pkgs.oci-cli
          pkgs.kubectl
          pkgs.kubelogin-oidc
          pkgs.kubernetes-helm
          pkgs.talosctl
          pkgs.fluxcd
          # Keep Ansible dependencies out of the main Python environment.
          (pkgs.python3.withPackages (ps: [ ps.ansible-core ]))
          pkgs.sops
          pkgs.age
          pkgs.ssh-to-age
          pkgs.wireguard-tools
          pkgs.yq-go
        ]
        ++ pkgs.lib.optionals pkgs.stdenv.hostPlatform.isLinux [
          pkgs.proxmox-auto-install-assistant
        ];
      };

      formatter = pkgs.nixfmt;
    };
}
