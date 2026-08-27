{ lib, pkgs, ... }:
{
  users.mutableUsers = false;

  nix.settings.trusted-users = [ "constantan" ];

  users.users.constantan = {
    isNormalUser = true;
    extraGroups = [ "wheel" ];
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKm+q7Q7YZOPoBRbEzJ7wIYKkUFrhmpIYk4PMn/obPnq"
    ];
  };

  # Keep the restricted jump account during the direct-SSH migration. Remove
  # it only after the public path has been deployed and verified end to end.
  # Per-server authorization is enforced again by the target Pod's keys.
  users.users.tunnel = {
    isNormalUser = true;
    shell = "${pkgs.shadow}/bin/nologin";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKm+q7Q7YZOPoBRbEzJ7wIYKkUFrhmpIYk4PMn/obPnq"
    ];
  };

  security.sudo.extraRules = [
    {
      users = [ "constantan" ];
      commands = [
        {
          command = "ALL";
          options = [ "NOPASSWD" ];
        }
      ];
    }
  ];

  services.openssh = {
    enable = true;
    openFirewall = true;
    authorizedKeysFiles = lib.mkForce [ "/etc/ssh/authorized_keys.d/%u" ];

    settings = {
      KbdInteractiveAuthentication = false;
      MaxAuthTries = 3;
      PasswordAuthentication = false;
      PermitRootLogin = lib.mkForce "no";
    };

    extraConfig = ''
      Match User tunnel
        AuthenticationMethods publickey
        AllowAgentForwarding no
        AllowStreamLocalForwarding no
        AllowTcpForwarding local
        GatewayPorts no
        PermitOpen 10.90.0.2:2222
        PermitTTY no
        X11Forwarding no
        ForceCommand ${pkgs.coreutils}/bin/false
    '';
  };
}
