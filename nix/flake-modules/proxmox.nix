{ inputs, self, ... }:
let
  network = builtins.fromJSON (builtins.readFile ../../proxmox/node-network.json);
in
{
  flake.systemConfigs = builtins.mapAttrs (
    hostName: host:
    inputs.system-manager.lib.makeSystemConfig {
      modules = [ ../hosts/proxmox ];
      specialArgs = { inherit hostName host; };
    }
  ) network.hosts;

  perSystem =
    {
      lib,
      pkgs,
      system,
      ...
    }:
    let
      commands = lib.mapAttrs (
        name: host:
        let
          target = lib.escapeShellArg "root@${host.ip}";
        in
        pkgs.writeShellApplication {
          name = "proxmox-${name}";
          runtimeInputs = [
            pkgs.openssh
            inputs.system-manager.packages.${system}.default
          ];
          text = ''
            if (( $# > 0 )); then
              echo "Usage: proxmox-${name}"
              [[ $1 == --help || $1 == -h ]] && exit 0
              exit 2
            fi
            # An ARM or Darwin client may lack a builder for the x86_64-linux profile.
            nix build --no-link ${lib.escapeShellArg "${self.outPath}#systemConfigs.${name}"}
            ssh ${target} bash -s -- ${lib.escapeShellArg name} < ${../../proxmox/prepare-host.sh}
            exec system-manager --target-host ${target} switch --flake ${lib.escapeShellArg "${self.outPath}#${name}"}
          '';
        }
      ) network.hosts;
    in
    {
      apps = lib.mapAttrs' (
        name: command:
        lib.nameValuePair "proxmox-${name}" {
          type = "app";
          program = lib.getExe command;
          meta.description = "Apply the Proxmox host configuration to ${name}";
        }
      ) commands;

      checks = lib.optionalAttrs (system == "x86_64-linux") (
        lib.mapAttrs' (name: profile: lib.nameValuePair "proxmox-${name}" profile) self.systemConfigs
        // lib.mapAttrs' (name: command: lib.nameValuePair "deploy-${name}" command) commands
        // {
          proxmox-bootstrap = pkgs.runCommand "proxmox-bootstrap" { } ''
            hostname() { echo pve01; }
            pveversion() { :; }
            nix-store() { :; }
            dpkg-query() {
              [[ ''${!#} != dnsmasq || -e installed ]] && echo installed
            }
            systemctl() { echo "systemctl $*"; }
            apt-get() { echo "apt-get $*"; }
            export -f hostname pveversion nix-store dpkg-query systemctl apt-get
            bash ${../../proxmox/prepare-host.sh} pve01 > actual
            cat > expected <<'EOF'
            systemctl mask dnsmasq.service
            apt-get update
            apt-get install --yes --no-remove --no-install-recommends dnsmasq
            EOF
            diff -u expected actual
            touch installed
            bash ${../../proxmox/prepare-host.sh} pve01 > actual
            test ! -s actual
            if bash ${../../proxmox/prepare-host.sh} pve02; then exit 1; fi
            touch "$out"
          '';
        }
      );
    };
}
