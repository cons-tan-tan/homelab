{ lib, ... }:
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
  };
}
