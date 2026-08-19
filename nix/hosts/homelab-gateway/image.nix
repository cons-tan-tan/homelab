{
  image.modules.linode =
    { lib, ... }:
    {
      # Runtime secrets are encrypted to the SSH host key generated after boot.
      # Keep the bootstrap image deployable without an existing host identity.
      # Keep SSH reachable on the first boot. Runtime-only proxy ports stay closed.
      networking.firewall.allowedTCPPorts = lib.mkForce [ 22 ];
      networking.firewall.allowedUDPPorts = lib.mkForce [ ];
      networking.wireguard.interfaces = lib.mkForce { };
      services.haproxy.enable = lib.mkForce false;
      sops.secrets = lib.mkForce { };

      image.baseName = "homelab-gateway-nixos";
    };
}
