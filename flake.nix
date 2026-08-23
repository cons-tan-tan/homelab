{
  inputs = {
    deploy-rs = {
      url = "github:serokell/deploy-rs";
      inputs.nixpkgs.follows = "nixpkgs";
    };
    flake-parts.url = "github:hercules-ci/flake-parts";
    nixpkgs-terraform.url = "github:stackbuilders/nixpkgs-terraform";
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    sops-nix = {
      url = "github:Mic92/sops-nix";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };

  outputs =
    inputs@{ flake-parts, ... }:
    flake-parts.lib.mkFlake { inherit inputs; } {
      imports = [
        ./nix/flake-modules/bootstrap.nix
        ./nix/flake-modules/dev-shell.nix
        ./nix/flake-modules/deploy.nix
        ./nix/flake-modules/minecraft-admin.nix
        ./nix/flake-modules/nixos.nix
      ];

      systems = [
        "aarch64-darwin"
        "aarch64-linux"
        "x86_64-linux"
      ];
    };
}
