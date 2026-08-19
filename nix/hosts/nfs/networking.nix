{
  networking = {
    domain = "local";
    firewall = {
      enable = true;
      allowedTCPPorts = [ 2049 ];
    };
    hostName = "nfs";
    useDHCP = false;
    useNetworkd = true;
  };

  services.resolved.enable = true;

  systemd.network = {
    enable = true;
    networks."10-lan" = {
      matchConfig.Name = "en* eth*";
      address = [ "192.168.2.31/20" ];
      routes = [ { Gateway = "192.168.1.1"; } ];
      networkConfig = {
        DNS = [ "192.168.0.1" ];
        Domains = [ "local" ];
        IPv6AcceptRA = false;
      };
    };
  };
}
