{
  users.mutableUsers = false;

  nix.settings.trusted-users = [ "constantan" ];

  users.users.constantan = {
    isNormalUser = true;
    uid = 1000;
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
    authorizedKeysInHomedir = false;

    settings = {
      KbdInteractiveAuthentication = false;
      MaxAuthTries = 3;
      PasswordAuthentication = false;
      PermitRootLogin = "no";
    };
  };
}
