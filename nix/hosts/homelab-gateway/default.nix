{ modulesPath, ... }:
{
  imports = [
    "${modulesPath}/virtualisation/linode-config.nix"
    ./image.nix
    ./networking.nix
    ./proxy.nix
    ./secrets.nix
    ./ssh.nix
  ];

  system.stateVersion = "26.05";
}
