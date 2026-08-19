{
  sops = {
    defaultSopsFile = ../../secrets/homelab-gateway.sops.yaml;
    age.sshKeyPaths = [ "/etc/ssh/ssh_host_ed25519_key" ];
    gnupg.sshKeyPaths = [ ];

    secrets.wireguard-private-key = {
      key = "wireguard_private_key";
      mode = "0400";
      restartUnits = [ "wireguard-wg0.service" ];
    };
  };
}
