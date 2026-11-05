# homelab

Configuration for my personal homelab. Terraform provisions infrastructure, Nix configures hosts and development tools, and Flux reconciles Kubernetes resources from Git.

## Repository layout

| Directory | Purpose |
| --- | --- |
| [`terraform/`](terraform/) | Infrastructure provisioning for local and cloud resources. |
| [`nix/`](nix/) | NixOS host configurations, packages, and development tooling. |
| [`talos/`](talos/) | Talos cluster definitions and configuration generation. |
| [`kubernetes/`](kubernetes/) | Flux configuration and Kubernetes resources. |
| [`ansible/`](ansible/) | Ansible playbooks and roles for Proxmox hosts. |
| [`proxmox/`](proxmox/) | Proxmox installation configuration. |
| [`tools/`](tools/) | Administration and configuration tools. |
| [`docs/`](docs/) | Design documents, operational guides, and investigation notes. |

## Development

Requires Nix with the `nix-command` and `flakes` experimental features enabled. Run the following commands from the repository root.

Enter the development shell:

```bash
nix develop
```

Run the flake checks for your current system:

```bash
nix flake check
```

For check definitions and CI coverage, see the [flake modules](nix/flake-modules/) and [CI workflow](.github/workflows/ci.yaml).
