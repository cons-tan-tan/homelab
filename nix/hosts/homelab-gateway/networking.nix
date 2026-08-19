{ config, ... }:
{
  networking = {
    hostName = "homelab-gateway";
    firewall = {
      enable = true;
      allowedUDPPorts = [ 51820 ];
    };
    nftables.enable = true;

    wireguard.interfaces.wg0 = {
      ips = [ "10.90.0.1/24" ];
      listenPort = 51820;
      privateKeyFile = config.sops.secrets.wireguard-private-key.path;
      peers = [
        {
          publicKey = "9XpgD8enHjBDYsDR4mFExbx+4k79zkqX/RRxSYh85Ac=";
          allowedIPs = [ "10.90.0.2/32" ];
        }
      ];
    };
  };
}
