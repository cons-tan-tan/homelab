{
  networking.firewall.allowedTCPPorts = [ 25565 ];

  services.haproxy = {
    enable = true;
    config = ''
      global
        log stdout format raw local0

      defaults
        log global
        mode tcp
        option tcplog
        timeout connect 5s
        timeout client 1h
        timeout server 1h

      frontend minecraft
        bind 0.0.0.0:25565
        default_backend minecraft-backend

      backend minecraft-backend
        option tcp-check
        server home 10.90.0.2:25565 check inter 5s rise 2 fall 3
    '';
  };
}
