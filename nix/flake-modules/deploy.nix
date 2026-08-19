{ inputs, self, ... }:
let
  system = "x86_64-linux";
in
{
  flake.deploy.nodes.nfs = {
    hostname = "192.168.2.31";
    sshUser = "constantan";

    profiles.system = {
      user = "root";
      path = inputs.deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.nfs;
    };
  };

  flake.deploy.nodes.homelab-gateway = {
    hostname = "172.235.215.105";
    sshUser = "constantan";

    profiles.system = {
      user = "root";
      path = inputs.deploy-rs.lib.${system}.activate.nixos self.nixosConfigurations.homelab-gateway;
    };
  };

  perSystem =
    { system, ... }:
    {
      checks = inputs.nixpkgs.lib.optionalAttrs (system == "x86_64-linux") (
        inputs.deploy-rs.lib.${system}.deployChecks self.deploy
      );
    };
}
