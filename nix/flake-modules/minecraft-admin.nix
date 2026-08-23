{ inputs, ... }:
{
  perSystem =
    { system, ... }:
    let
      pkgs = import inputs.nixpkgs { inherit system; };
    in
    pkgs.lib.optionalAttrs (system == "x86_64-linux") (
      let
        minecraftAdmin = pkgs.writeShellApplication {
          name = "mc-admin";
          runtimeInputs = with pkgs; [
            coreutils
            findutils
            gawk
            kubectl
            unzip
            util-linux
          ];
          text = builtins.readFile ../packages/minecraft-admin/mc-admin.sh;
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

        minecraftAdminScriptsTest =
          pkgs.runCommand "minecraft-admin-scripts-test"
            {
              nativeBuildInputs = with pkgs; [
                bash
                coreutils
                findutils
                gawk
                gnugrep
                minecraftAdmin
                unzip
                util-linux
                zip
              ];
            }
            ''
              test_root="$TMPDIR/test-root"
              data_dir="$test_root/data"
              fixture_dir="$test_root/fixture"
              fake_bin="$test_root/bin"
              mkdir -p "$data_dir/backups" "$data_dir/world" "$data_dir/visualprospecting" \
                "$fixture_dir/world" "$fixture_dir/visualprospecting/server" "$fake_bin"

              printf 'old world\n' > "$data_dir/world/state.txt"
              printf 'old visual prospecting\n' > "$data_dir/visualprospecting/state.txt"
              printf 'new world\n' > "$fixture_dir/world/state.txt"
              printf 'new visual prospecting\n' > "$fixture_dir/visualprospecting/server/state.txt"
              (cd "$fixture_dir" && zip -qr "$data_dir/backups/good.zip" world visualprospecting)

              cat > "$fake_bin/kubectl" <<'EOF'
              #!/bin/sh
              if [ "''${FAKE_KUBECTL_FAIL:-false}" = true ]; then
                echo 'simulated Kubernetes API failure' >&2
                exit 1
              fi
              case "$*" in
                *"get deployment"*) printf '%s' "''${FAKE_REPLICAS:-0}" ;;
                *"get pods"*) printf '%s' "''${FAKE_SERVER_PODS:-}" ;;
                *) echo "unexpected kubectl invocation: $*" >&2; exit 1 ;;
              esac
              EOF
              chmod +x "$fake_bin/kubectl"

              cat > "$fake_bin/mv" <<'EOF'
              #!/bin/sh
              set -eu
              if [ -n "''${FAKE_MV_FAIL_ON:-}" ]; then
                count=0
                if [ -f "''${FAKE_MV_COUNTER:?}" ]; then
                  count="$(cat "''${FAKE_MV_COUNTER}")"
                fi
                count=$((count + 1))
                printf '%s\n' "$count" > "''${FAKE_MV_COUNTER}"
                if [ "$count" -eq "''${FAKE_MV_FAIL_ON}" ]; then
                  echo 'simulated mv failure' >&2
                  exit 1
                fi
              fi
              exec "''${REAL_MV:?}" "$@"
              EOF
              chmod +x "$fake_bin/mv"

              run_admin() {
                PATH="$fake_bin:$PATH" \
                  REAL_MV=${pkgs.coreutils}/bin/mv \
                  MINECRAFT_NAMESPACE=minecraft \
                  MINECRAFT_DEPLOYMENT=gtnh-minecraft \
                  MINECRAFT_DATA_DIR="$data_dir" \
                  MINECRAFT_BACKUP_DIR="$data_dir/backups" \
                  MINECRAFT_POD_SELECTOR='app=gtnh-minecraft' \
                  MINECRAFT_RESTORE_ROOTS="''${MINECRAFT_RESTORE_ROOTS:-world visualprospecting}" \
                  ${pkgs.bash}/bin/bash ${../packages/minecraft-admin/mc-admin.sh} "$@"
              }

              ${minecraftAdmin}/bin/mc-admin --help | grep -F 'Usage: mc-admin <command> [options]'
              for command in status stop start backups restore rollback; do
                ${minecraftAdmin}/bin/mc-admin "$command" --help \
                  | grep -F "Usage: mc-admin $command"
              done
              for command in list apply delete; do
                ${minecraftAdmin}/bin/mc-admin rollback "$command" --help \
                  | grep -F "Usage: mc-admin rollback $command"
              done
              test ! -e ${minecraftAdmin}/bin/mc-stop

              if ${minecraftAdmin}/bin/mc-admin status unexpected; then
                echo 'mc-admin status accepted an unexpected argument' >&2
                exit 1
              fi

              run_admin restore --yes good.zip

              grep -Fx 'new world' "$data_dir/world/state.txt"
              grep -Fx 'new visual prospecting' "$data_dir/visualprospecting/server/state.txt"
              find "$data_dir/.minecraft-admin-rollbacks" -path '*/world/state.txt' \
                -exec grep -Fx 'old world' {} \; | grep -Fx 'old world'

              rollback_id="$(run_admin rollback list | awk 'NR == 2 { print $1 }')"
              test -n "$rollback_id"
              invalid_id=99999999T999999Z.ABC124
              mkdir -p "$data_dir/.minecraft-admin-rollbacks/$invalid_id"
              run_admin rollback list | grep -F "$invalid_id" | grep -F INVALID
              run_admin rollback apply --yes latest | grep -F "Applied rollback $rollback_id"
              grep -Fx 'old world' "$data_dir/world/state.txt"
              grep -Fx 'old visual prospecting' "$data_dir/visualprospecting/state.txt"
              test ! -e "$data_dir/.minecraft-admin-rollbacks/$rollback_id"
              run_admin rollback delete --yes "$invalid_id"

              replacement_id="$(run_admin rollback list | awk 'NR == 2 { print $1 }')"
              test -n "$replacement_id"
              grep -Fx 'new world' \
                "$data_dir/.minecraft-admin-rollbacks/$replacement_id/world/state.txt"
              MINECRAFT_RESTORE_ROOTS=world \
                run_admin rollback list | grep -F "$replacement_id"
              MINECRAFT_RESTORE_ROOTS=world \
                run_admin rollback delete --yes "$replacement_id" \
                | grep -F "Deleted rollback $replacement_id"
              run_admin rollback list | grep -Fx 'No rollbacks found'

              cp "$data_dir/backups/good.zip" "$data_dir/backups/newest backup.zip"
              touch -d '@4102444800' "$data_dir/backups/newest backup.zip"
              run_admin restore --yes latest | grep -F 'Restored newest backup.zip'

              if run_admin rollback delete --yes latest; then
                echo 'mc-admin rollback delete accepted latest instead of an explicit ID' >&2
                exit 1
              fi
              if run_admin rollback delete --yes ../world; then
                echo 'mc-admin rollback delete accepted a path instead of an ID' >&2
                exit 1
              fi

              incomplete_id=99999999T999999Z.ABC123
              mkdir -p "$data_dir/.minecraft-admin-rollbacks/$incomplete_id"
              printf '%s\n' world visualprospecting \
                > "$data_dir/.minecraft-admin-rollbacks/$incomplete_id/.roots"
              touch "$data_dir/.minecraft-admin-rollbacks/$incomplete_id/.incomplete"
              run_admin rollback list | grep -F "$incomplete_id" | grep -F INCOMPLETE
              if run_admin rollback apply --yes "$incomplete_id"; then
                echo 'mc-admin rollback apply accepted an incomplete transaction' >&2
                exit 1
              fi
              if output="$(run_admin start 2>&1)"; then
                echo 'mc-admin start accepted an incomplete rollback transaction' >&2
                exit 1
              fi
              printf '%s\n' "$output" \
                | grep -F 'Refusing to start while an incomplete data operation exists'
              run_admin rollback delete --yes "$incomplete_id"

              staging_dir="$data_dir/.minecraft-admin-restore.ABC123"
              mkdir "$staging_dir"
              if output="$(run_admin start 2>&1)"; then
                echo 'mc-admin start accepted an incomplete restore transaction' >&2
                exit 1
              fi
              printf '%s\n' "$output" \
                | grep -F 'Refusing to start while an incomplete data operation exists'
              rmdir "$staging_dir"

              for reserved_root in \
                .roots .incomplete .minecraft-admin-rollbacks \
                .minecraft-admin-operation.lock .minecraft-admin-restore.test; do
                if MINECRAFT_RESTORE_ROOTS="$reserved_root" \
                  run_admin restore --yes good.zip; then
                  echo "mc-admin restore accepted reserved root $reserved_root" >&2
                  exit 1
                fi
              done

              if output="$(MINECRAFT_RESTORE_ROOTS=world \
                run_admin rollback apply --yes latest 2>&1)"; then
                echo 'mc-admin rollback apply accepted a rollback for different roots' >&2
                exit 1
              fi
              printf '%s\n' "$output" \
                | grep -F 'Rollback roots do not match MINECRAFT_RESTORE_ROOTS'

              mv "$data_dir/world" "$data_dir/world.saved"
              ln -s missing-world "$data_dir/world"
              if run_admin rollback apply --yes latest; then
                echo 'mc-admin rollback apply accepted a dangling live-root symlink' >&2
                exit 1
              fi
              rm "$data_dir/world"
              mv "$data_dir/world.saved" "$data_dir/world"

              mv_counter="$test_root/mv-counter"
              if FAKE_MV_FAIL_ON=2 FAKE_MV_COUNTER="$mv_counter" \
                run_admin rollback apply --yes latest; then
                echo 'mc-admin rollback apply ignored an mv failure' >&2
                exit 1
              fi
              grep -Fx 'new world' "$data_dir/world/state.txt"
              grep -Fx 'new visual prospecting' \
                "$data_dir/visualprospecting/server/state.txt"
              test "$(find "$data_dir/.minecraft-admin-rollbacks" \
                -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1

              rm "$mv_counter"
              if FAKE_MV_FAIL_ON=2 FAKE_MV_COUNTER="$mv_counter" \
                run_admin restore --yes good.zip; then
                echo 'mc-admin restore ignored an mv failure' >&2
                exit 1
              fi
              grep -Fx 'new world' "$data_dir/world/state.txt"
              grep -Fx 'new visual prospecting' \
                "$data_dir/visualprospecting/server/state.txt"
              test "$(find "$data_dir/.minecraft-admin-rollbacks" \
                -mindepth 1 -maxdepth 1 -type d | wc -l)" -eq 1

              if FAKE_SERVER_PODS=pod/gtnh-minecraft-terminating \
                run_admin rollback apply --yes latest; then
                echo 'mc-admin rollback apply continued while a server Pod still existed' >&2
                exit 1
              fi
              grep -Fx 'new world' "$data_dir/world/state.txt"

              ln -s ../visualprospecting "$fixture_dir/world/link"
              (cd "$fixture_dir" && zip -y -qr "$data_dir/backups/symlink.zip" world visualprospecting)
              rm "$fixture_dir/world/link"
              if run_admin restore --yes symlink.zip; then
                echo 'mc-admin restore accepted a symbolic link from an archive' >&2
                exit 1
              fi

              mkdir -p "$fixture_dir/unexpected"
              printf 'bad\n' > "$fixture_dir/unexpected/state.txt"
              (cd "$fixture_dir" && zip -qr "$data_dir/backups/bad.zip" unexpected)
              if run_admin restore --yes bad.zip; then
                echo 'mc-admin restore accepted an unexpected archive root' >&2
                exit 1
              fi

              if FAKE_KUBECTL_FAIL=true run_admin restore --yes good.zip; then
                echo 'mc-admin restore continued after a Kubernetes API failure' >&2
                exit 1
              fi
              grep -Fx 'new world' "$data_dir/world/state.txt"

              if FAKE_SERVER_PODS=pod/gtnh-minecraft-terminating \
                run_admin restore --yes good.zip; then
                echo 'mc-admin restore continued while a server Pod still existed' >&2
                exit 1
              fi
              grep -Fx 'new world' "$data_dir/world/state.txt"

              touch "$out"
            '';

        minecraftAdminImageTest =
          pkgs.runCommand "minecraft-admin-image-test"
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
              gzip -dc ${minecraftAdminImage} > "$TMPDIR/image.tar"
              tar -xf "$TMPDIR/image.tar" -C "$image_dir"

              config_file="$(jq -er '.[0].Config' "$image_dir/manifest.json")"
              entrypoint="$(jq -er '.config.Cmd | select(length == 1) | .[0]' \
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
                echo "Image Cmd is missing from its layers: $entrypoint" >&2
                exit 1
              fi
              touch "$out"
            '';
      in
      {
        packages.minecraft-admin = minecraftAdmin;
        packages.minecraft-admin-image = minecraftAdminImage;
        checks.minecraft-admin-image = minecraftAdminImageTest;
        checks.minecraft-admin-scripts = minecraftAdminScriptsTest;
      }
    );
}
