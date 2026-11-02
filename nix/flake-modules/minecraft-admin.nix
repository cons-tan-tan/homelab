{ inputs, ... }:
{
  perSystem =
    { system, ... }:
    let
      pkgs = import inputs.nixpkgs { inherit system; };
    in
    pkgs.lib.optionalAttrs (system == "x86_64-linux") (
      let
        minecraftTools = pkgs.buildGoModule {
          pname = "minecraft-tools";
          version = "0.1.0";
          src = ../../tools/minecraft;
          vendorHash = null;
          subPackages = [
            "cmd/mc-admin"
            "cmd/forge-cfg"
          ];
          env.CGO_ENABLED = 0;
          meta.mainProgram = "forge-cfg";
          ldflags = [
            "-s"
            "-w"
          ];
          outputs = [
            "out"
            "forge"
          ];
          checkPhase = ''
            runHook preCheck
            go test ./...
            runHook postCheck
          '';
          postInstall = ''
            mkdir -p "$forge/bin"
            mv "$out/bin/forge-cfg" "$forge/bin/"
          '';
        };

        forgeCfg = minecraftTools.forge;

        minecraftAdmin = pkgs.writeShellApplication {
          name = "mc-admin";
          runtimeInputs = [ pkgs.kubectl ];
          text = ''
            exec ${minecraftTools}/bin/mc-admin "$@"
          '';
        };

        forgeCfgImage = pkgs.dockerTools.buildLayeredImage {
          name = "forge-cfg";
          tag = "main";
          contents = [ forgeCfg ];
          config = {
            Entrypoint = [ "${forgeCfg}/bin/forge-cfg" ];
            Cmd = [ "--help" ];
            User = "1000:3000";
            Labels = {
              "org.opencontainers.image.description" = "Static legacy Forge configuration merger";
              "org.opencontainers.image.source" = "https://github.com/cons-tan-tan/homelab";
            };
          };
        };

        minecraftAdminEntrypoint = pkgs.writeShellApplication {
          name = "minecraft-admin-entrypoint";
          runtimeInputs = with pkgs; [
            coreutils
            openssh
          ];
          text = builtins.readFile ../packages/minecraft-admin/entrypoint.sh;
        };

        minecraftAdminImage = pkgs.dockerTools.buildLayeredImage {
          name = "minecraft-admin";
          tag = "main";
          contents = with pkgs; [
            bashInteractive
            cacert
            coreutils
            findutils
            gawk
            gnugrep
            gnused
            gzip
            jq
            kubectl
            less
            minecraftAdmin
            minecraftAdminEntrypoint
            openssh
            procps
            rsync
            stdenv.cc.libc
            gnutar
            unzip
            util-linux
            zip
            zstd
          ];
          extraCommands = ''
            rm -rf etc/ssh
            mkdir -p etc/ssh home/minecraft run var/empty

            cat > etc/passwd <<'EOF'
            root:x:0:0:root:/root:/bin/bash
            sshd:x:74:74:Privilege-separated SSH:/var/empty:/bin/false
            minecraft:x:1000:3000:Minecraft operator:/home/minecraft:/bin/bash
            EOF

            cat > etc/group <<'EOF'
            root:x:0:
            sshd:x:74:
            minecraft:x:3000:
            minecraft-data:x:2000:minecraft
            EOF

            cat > etc/nsswitch.conf <<'EOF'
            passwd: files
            group: files
            shadow: files
            hosts: files dns
            networks: files dns
            EOF

            cat > etc/profile <<'EOF'
            if [ -d "''${MINECRAFT_DATA_DIR:-/data}" ]; then
              cd -- "''${MINECRAFT_DATA_DIR:-/data}"
            fi
            EOF

            cat > etc/ssh/sshd_config <<'EOF'
            Port 2222
            ListenAddress 0.0.0.0
            HostKey /run/minecraft-admin/ssh_host_ed25519_key
            PidFile /run/minecraft-admin/sshd.pid
            AuthorizedKeysFile /run/minecraft-admin/authorized_keys
            PermitRootLogin no
            PasswordAuthentication no
            KbdInteractiveAuthentication no
            PubkeyAuthentication yes
            AuthenticationMethods publickey
            UsePAM no
            AllowUsers minecraft
            DisableForwarding yes
            PermitUserEnvironment no
            StrictModes yes
            PrintMotd no
            LogLevel VERBOSE
            Subsystem sftp internal-sftp
            EOF

            chmod 0755 home/minecraft run var/empty
            chmod 0644 etc/passwd etc/group etc/nsswitch.conf etc/profile etc/ssh/sshd_config
          '';
          config = {
            Cmd = [ "${minecraftAdminEntrypoint}/bin/minecraft-admin-entrypoint" ];
            Env = [
              "HOME=/home/minecraft"
              "PATH=/bin:/usr/bin"
            ];
            ExposedPorts = {
              "2222/tcp" = { };
            };
            Labels = {
              "org.opencontainers.image.description" = "SSH toolbox for operating Minecraft servers";
              "org.opencontainers.image.source" = "https://github.com/cons-tan-tan/homelab";
            };
            User = "0:0";
            WorkingDir = "/home/minecraft";
          };
        };

        minecraftToolsTest =
          pkgs.runCommand "minecraft-tools-test"
            {
              nativeBuildInputs = with pkgs; [
                binutils
                coreutils
                gnugrep
                zip
              ];
            }
            ''
              for binary in ${minecraftTools}/bin/mc-admin ${forgeCfg}/bin/forge-cfg; do
                if readelf -l "$binary" | grep -q INTERP \
                  || readelf -d "$binary" | grep -q NEEDED; then
                  echo "Binary requires a dynamic runtime: $binary" >&2
                  exit 1
                fi
              done

              ${minecraftAdmin}/bin/mc-admin --help | grep -F 'Usage: mc-admin'
              mkdir -p "$TMPDIR/bin" "$TMPDIR/data/world" "$TMPDIR/data/backups"
              cat > "$TMPDIR/bin/kubectl" <<'EOF'
              #!/bin/sh
              case "$*" in
                *"get deployment"*) printf '%s\n' '{"spec":{"replicas":0},"status":{}}' ;;
                *"get pods"*) ;;
                *) echo "unexpected kubectl invocation: $*" >&2; exit 1 ;;
              esac
              EOF
              chmod +x "$TMPDIR/bin/kubectl"
              export PATH="$TMPDIR/bin:$PATH"
              export MINECRAFT_NAMESPACE=minecraft MINECRAFT_DEPLOYMENT=gtnh-minecraft
              export MINECRAFT_POD_SELECTOR=app=gtnh MINECRAFT_RESTORE_ROOTS=world
              export MINECRAFT_DATA_DIR="$TMPDIR/data"
              printf 'fixture\n' > "$TMPDIR/data/world/state.txt"
              (cd "$TMPDIR/data" && zip -qr backups/good.zip world)
              ${minecraftTools}/bin/mc-admin status | grep -F 'Desired replicas: 0'
              ${minecraftTools}/bin/mc-admin restore --yes good.zip
              ${minecraftTools}/bin/mc-admin rollback apply --yes latest
              grep -Fx fixture "$TMPDIR/data/world/state.txt"

              printf 'B:enabled=false\n' > "$TMPDIR/base.cfg"
              printf 'B:enabled=true\n' > "$TMPDIR/patch.cfg"
              ${forgeCfg}/bin/forge-cfg --install "$TMPDIR/forge-cfg" \
                "$TMPDIR/base.cfg" "$TMPDIR/patch.cfg"
              test ! -L "$TMPDIR/forge-cfg"
              "$TMPDIR/forge-cfg" --check "$TMPDIR/base.cfg" "$TMPDIR/patch.cfg"
              touch "$out"
            '';

        imageTest =
          name: archive: commandField:
          pkgs.runCommand "${name}-image-test"
            {
              nativeBuildInputs = with pkgs; [
                gnugrep
                gnutar
                gzip
                jq
              ];
            }
            ''
              image_dir="$TMPDIR/image"
              mkdir -p "$image_dir"
              gzip -dc ${archive} > "$TMPDIR/image.tar"
              tar -xf "$TMPDIR/image.tar" -C "$image_dir"

              config_file="$(jq -er '.[0].Config' "$image_dir/manifest.json")"
              entrypoint="$(jq -er '.config.${commandField} | select(length == 1) | .[0]' \
                "$image_dir/$config_file")"
              entrypoint_path="''${entrypoint#/}"
              found=false
              while IFS= read -r layer; do
                tar -tf "$image_dir/$layer" > "$TMPDIR/layer-contents"
                if grep -Fxq "$entrypoint" "$TMPDIR/layer-contents" \
                  || grep -Fxq "$entrypoint_path" "$TMPDIR/layer-contents" \
                  || grep -Fxq "./$entrypoint_path" "$TMPDIR/layer-contents"; then
                  found=true
                  break
                fi
              done < <(jq -r '.[0].Layers[]' "$image_dir/manifest.json")

              if [[ "$found" != true ]]; then
                echo "Image executable is missing from its layers: $entrypoint" >&2
                exit 1
              fi
              touch "$out"
            '';
      in
      {
        packages.minecraft-admin = minecraftAdmin;
        packages.minecraft-admin-image = minecraftAdminImage;
        packages.forge-cfg = forgeCfg;
        packages.forge-cfg-image = forgeCfgImage;
        checks.minecraft-tools = minecraftToolsTest;
        checks.minecraft-admin-image = imageTest "minecraft-admin" minecraftAdminImage "Cmd";
        checks.forge-cfg-image = imageTest "forge-cfg" forgeCfgImage "Entrypoint";
      }
    );
}
