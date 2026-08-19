{ modulesPath, ... }:
{
  imports = [
    "${modulesPath}/profiles/qemu-guest.nix"
    ./image.nix
    ./networking.nix
    ./nfs.nix
    ./ssh.nix
  ];

  boot.loader.grub = {
    enable = true;
    device = "/dev/sda";
  };
  boot.kernelParams = [ "console=ttyS0" ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  services.qemuGuest.enable = true;

  system.stateVersion = "26.05";
}
