#!/usr/bin/env bash
set -euo pipefail

if [[ $(hostname -s) != "$1" ]] || ! command -v pveversion >/dev/null; then
  echo "Expected Proxmox host $1" >&2
  exit 1
fi

# System Manager needs a working Nix store before it can copy its first profile.
packages=(frr frr-pythontools dnsmasq)
nix_store=$(command -v nix-store || true)
if [[ -z $nix_store && -x /nix/var/nix/profiles/default/bin/nix-store ]]; then
  echo "Expose the existing nix-store on the noninteractive SSH PATH" >&2
  exit 1
fi
if [[ -z $nix_store || $nix_store == /usr/bin/nix-store ]]; then
  packages+=(nix-setup-systemd)
fi

missing=()
for package in "${packages[@]}"; do
  if [[ $(dpkg-query -W -f='${db:Status-Status}' "$package" 2>/dev/null) != installed ]]; then
    missing+=("$package")
    if [[ $package == dnsmasq ]]; then
      # Keep the package post-install script from starting the default instance.
      systemctl mask dnsmasq.service
    fi
  fi
done
if (( ${#missing[@]} )); then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install --yes --no-remove --no-install-recommends "${missing[@]}"
fi
