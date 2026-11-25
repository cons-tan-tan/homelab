{
  config,
  host,
  hostName,
  lib,
  pkgs,
  ...
}:
let
  boostPath = "/sys/devices/system/cpu/cpufreq/boost";
  boostValue = "0";
  powerProfile = pkgs.writeShellApplication {
    name = "pve-power-profile";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.gnugrep
    ];
    text = builtins.readFile ./pve01-power-profile.sh;
  };
in
{
  nixpkgs.hostPlatform = "x86_64-linux";
  services.userborn.enable = false;
  security.enableWrappers = false;

  environment.etc = {
    "sysctl.d/90-proxmox-node-network.conf".text = "net.ipv4.ip_forward = 1\n";

    "systemd/system/pve-power-profile.service" = lib.mkIf (hostName == "pve01") {
      source = "${config.systemd.units."pve-power-profile.service".unit}/pve-power-profile.service";
      replaceExisting = true;
    };

    "frr/daemons" = {
      replaceExisting = true;
      text = ''
        ospfd=yes
        vtysh_enable=yes
        mgmtd_options="-A 127.0.0.1"
        zebra_options="-A 127.0.0.1"
        staticd_options="-A 127.0.0.1"
        ospfd_options="-A 127.0.0.1"
      '';
    };

    "frr/frr.conf" = {
      replaceExisting = true;
      mode = "0640";
      user = "frr";
      group = "frr";
      text = ''
        frr defaults traditional
        hostname ${hostName}
        log syslog informational
        !
        interface vmbr0
         ip ospf area 0.0.0.0
        exit
        !
        ip prefix-list LOCAL-VNET seq 5 permit ${host.subnet}
        route-map LOCAL-VNET permit 10
         match ip address prefix-list LOCAL-VNET
        exit
        !
        router ospf
         ospf router-id ${host.ip}
         passive-interface default
         no passive-interface vmbr0
         redistribute connected route-map LOCAL-VNET
        exit
      '';
    };
  };

  # Only Proxmox's per-zone dnsmasq instances should listen on the VNets.
  systemd.maskedUnits = [ "dnsmasq.service" ];

  systemd.tmpfiles.settings."pve-cpu-boost" = lib.mkIf (hostName == "pve01") {
    ${boostPath}.w.argument = boostValue;
  };

  systemd.services = {
    proxmox-node-routing = {
      description = "Apply IPv4 forwarding and the Proxmox node OSPF configuration";
      wantedBy = [ "multi-user.target" ];
      after = [ "frr.service" ];
      wants = [ "frr.service" ];
      restartTriggers = map (name: config.environment.etc.${name}.source) [
        "sysctl.d/90-proxmox-node-network.conf"
        "frr/daemons"
        "frr/frr.conf"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = [
          "/usr/sbin/sysctl -p /etc/sysctl.d/90-proxmox-node-network.conf"
          "/usr/bin/systemctl reload-or-restart frr.service"
        ];
      };
    };

    pve-power-profile = lib.mkIf (hostName == "pve01") {
      description = "Apply Proxmox host power profile";
      wantedBy = [ "multi-user.target" ];
      after = [
        "systemd-modules-load.service"
        "local-fs.target"
      ];
      before = [ "pve-guests.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.getExe powerProfile;
        ExecStartPost = [
          "/usr/bin/systemd-tmpfiles --create pve-cpu-boost.conf"
          "${lib.getExe pkgs.gnugrep} -qx ${boostValue} ${boostPath}"
        ];
        RemainAfterExit = true;
      };
    };
  };
}
