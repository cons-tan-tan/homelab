{
  image.modules.qemu =
    { lib, ... }:
    {
      # The image builder uses /dev/vda, while Proxmox scsi0 is /dev/sda.
      boot.loader.grub.device = lib.mkForce "/dev/vda";

      image.baseName = "nfs-nixos";
    };
}
