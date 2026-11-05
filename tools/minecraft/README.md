# Minecraft tools

This Go module provides `mc-admin` and `forge-cfg`, using only the standard
library. Nix builds static Linux/amd64 executables with `CGO_ENABLED=0`, runs the
Go tests, and packages the executables into separate container images.

Each CLI's implementation and tests live together in `cmd/mc-admin` or
`cmd/forge-cfg`. They are standalone programs, with no shared library package.

## mc-admin

`mc-admin` operates a Kubernetes Deployment and restores local ZIP backups.
The existing commands, environment variables, confirmation prompts, and retained
rollback directory format are preserved. See the
[operator guide](../../docs/manual/gtnh-admin/README.md) and
`mc-admin --help` for usage.

Kubernetes operations call `kubectl` directly, without a shell. The Nix package
adds `kubectl` to `PATH`; ZIP handling, validation, locking, file operations, and
rollback recovery use Go. The admin image still includes the interactive SSH
toolbox and its small SSH entrypoint script.

A restore snapshots the selected archive, verifies its checksums and paths,
and extracts into a private directory on the data filesystem. It checks that
the Deployment is stopped and its Pods have terminated both before preparation
and immediately before moving live data. Archives containing symlinks, special
files, duplicate or noncanonical paths, unexpected roots, or missing configured
roots are rejected. These checks do not depend on parsing `unzip` output.

Data operations share a filesystem lock. Each completed directory move is
recorded and reversed on failure or cancellation. If recovery also fails, the
retained data and incomplete markers remain for inspection. A forced kill can
also leave these markers; `start` refuses to run until the interrupted operation
has been resolved. Moving several roots is not a single atomic filesystem
transaction, and the lock does not prevent another operator from scaling the
Deployment outside this tool.

Existing rollback IDs and `.roots` manifests remain usable. Applying a rollback
consumes it and retains the replaced live data as a new rollback. Restoring or
applying a rollback never starts the server automatically.

## forge-cfg

```console
forge-cfg BASE_CFG PATCH_CFG
forge-cfg --check BASE_CFG PATCH_CFG
forge-cfg --install /minecraft-tools/forge-cfg BASE_CFG PATCH_CFG
```

The patch supports scalar `B`, `I`, `D`, and `S` properties inside nested Forge
categories. Every target must already exist exactly once with the same type.
Invalid values, duplicate targets, missing targets, and malformed category
boundaries fail before the base file is replaced. Base lists are opaque and
cannot accidentally supply scalar patch targets.

The merger preserves unrelated bytes, indentation, comments, line endings,
ownership, permissions, and modification time. A sibling temporary file is
renamed into place only after validation. An unchanged file is not replaced.
`--check` only verifies the patch values and returns a failure on drift.

GTNH's merge initContainer uses `--install` to copy the static executable into
a shared `emptyDir` before merging the configuration. This option requires the
base and patch paths; there is no separate installation-only mode. The main
Minecraft container mounts the tools volume read-only and runs the copied
binary after `mc-health` in its startup probe. The image and copied executable
need no shell, Nix store runtime, or language interpreter for the merge.

## Development and release

From this directory:

```console
go test ./...
go test -race ./...
go vet ./...
```

From the repository root:

```console
nix build .#minecraft-admin .#forge-cfg
nix build .#minecraft-admin-image .#forge-cfg-image --no-link
nix flake check --all-systems --no-build
nix flake check --keep-going --option system x86_64-linux
```

Flake checks exercise the packaged CLIs, verify that the executables have no
dynamic loader or shared-library dependencies, and check that both images
contain their configured entrypoints. The release workflow publishes both
images after CI succeeds on the default branch. Runtime manifests pin image
digests; publish the corresponding built images before reconciling those
manifests. Renovate proposes subsequent digest updates for review.
