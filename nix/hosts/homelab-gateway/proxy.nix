{
  networking.firewall.allowedTCPPorts = [
    2222
    25565
  ];

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

      frontend gtnh-admin-ssh
        bind 0.0.0.0:2222
        maxconn 16
        # This is the only hop that sees and logs the original client address.
        # Apply per-client limits before the two proxies replace that address.
        stick-table type ip size 100k expire 10m store conn_cur,conn_rate(10s)
        tcp-request connection track-sc0 src
        tcp-request connection reject if { sc_conn_cur(0) gt 3 }
        tcp-request connection reject if { sc_conn_rate(0) gt 10 }
        default_backend gtnh-admin-ssh-backend

      backend minecraft-backend
        option tcp-check
        server home 10.90.0.2:25565 check inter 5s rise 2 fall 3

      backend gtnh-admin-ssh-backend
        timeout queue 5s
        server home 10.90.0.2:2222 maxconn 16
    '';
  };
}
