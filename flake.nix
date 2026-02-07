{
  inputs = {
    nixpkgs-terraform.url = "github:stackbuilders/nixpkgs-terraform";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    systems.url = "github:nix-systems/default";
  };

  outputs =
    {
      self,
      nixpkgs-terraform,
      nixpkgs,
      systems,
    }:
    let
      forEachSystem = nixpkgs.lib.genAttrs (import systems);
    in
    {
      devShells = forEachSystem (
        system:
        let
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfree = true;
          };
          terraform = nixpkgs-terraform.packages.${system}."terraform-1.14.4";
        in
        {
          default = pkgs.mkShell {
            buildInputs = [
              terraform
              pkgs.google-cloud-sdk
              pkgs.kubectl
              pkgs.talosctl
              pkgs.sops
            ];
          };
        }
      );
    };
}
