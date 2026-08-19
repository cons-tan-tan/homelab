{ inputs, self, ... }:
let
  system = "x86_64-linux";
in
{
  flake.nixosConfigurations.homelab-gateway = inputs.nixpkgs.lib.nixosSystem {
    inherit system;
    modules = [
      inputs.sops-nix.nixosModules.sops
      ../hosts/homelab-gateway
    ];
  };

  perSystem =
    { system, ... }:
    {
      packages = inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") {
        linode-image = self.nixosConfigurations.homelab-gateway.config.system.build.images.linode;
      };
    };
}
