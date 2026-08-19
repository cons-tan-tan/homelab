{
  systemd.tmpfiles.rules = [ "d /srv/nfs/ntfy 0755 root root -" ];

  services.nfs.server = {
    enable = true;
    createMountPoints = true;
    exports = {
      "/srv/nfs" = {
        "192.168.0.0/20" = [
          "rw"
          "sync"
          "no_subtree_check"
          "no_root_squash"
        ];
      };
    };
  };
}
