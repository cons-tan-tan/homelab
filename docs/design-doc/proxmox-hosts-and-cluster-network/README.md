# Proxmox host configuration and the Kubernetes node network

Talos VMs use a dedicated network for Kubernetes node traffic. The home LAN
still carries management traffic and gives household devices direct access to
published services.

## Configuration ownership

The node network inventory defines the Proxmox hosts, their VNet subnets and
gateways, and the placement of each Talos VM. Terraform, Nix and the Talos
configuration generator all read it. [Node network inventory](../../../proxmox/node-network.json)

| Owner | Responsibility |
| --- | --- |
| Terraform | Create one Proxmox SDN Simple Zone and VNet per host, attach VM NICs and apply the generated Talos configuration. The API account needs `SDN.Audit` and `SDN.Allocate` on `/sdn` for these SDN operations. |
| Nix System Manager | Manage IPv4 forwarding and FRRouting (FRR) on both hosts, and the power profile on `pve01`. Host deployment installs missing Debian packages over SSH before activating the profile. |
| Proxmox SDN | Allocate node addresses through PVE IPAM and serve them through a dnsmasq instance per zone. System Manager masks the host-wide instance to keep DHCP scoped to the VNets. |
| Flux | Manage Cilium's devices, LoadBalancer address pool and L2 announcement policy. |

Terraform ties etcd bootstrap to the single control-plane VM's identity.
An in-place NIC change preserves its etcd member. [Talos lifecycle](../../../terraform/proxmox/k8s/talos.tf)

## Traffic paths

| Talos NIC | Address and route | Use |
| --- | --- | --- |
| `ens18` on `vmbr0` | Static LAN address and default route | Talos management, Kubernetes API and LAN-facing services. The control plane also advertises its LAN address to etcd. |
| `ens19` on the host's VNet | DHCP address from the host's /24. Talos ignores DHCP routes and reaches other subnets in `10.77.0.0/16` through the local VNet gateway. | Kubelet selects this address as the node's InternalIP. Cilium uses the same address for cross-node Pod traffic. |

For traffic between hosts, a node sends packets to its local Proxmox gateway.
FRR peers over `vmbr0` using OSPF. Each host advertises its own connected
VNet subnet, so peers learn the route when a host joins. System Manager owns
the FRR configuration because the pinned Proxmox provider's OSPF Fabric
resource lacks the redistribution policy used here.
[Host routing configuration](../../../nix/hosts/proxmox/default.nix) ·
[Reference deployment](https://github.com/nnaka2992/kube_on_proxmox/blob/f5ce2d0d6a1ca45c6921ea4e6d14cc83fcede84d/terraform/network/templates/frr.conf.tftpl) ·
[Provider schema](https://github.com/bpg/terraform-provider-proxmox/blob/v0.94.0/docs/resources/virtual_environment_sdn_fabric_ospf.md)

A home LAN client reaches the Kubernetes API at `192.168.2.12:6443`. For a
LoadBalancer service such as Minecraft, a worker answers ARP on `ens18` for
the service IP. LAN clients can reach it directly using the worker's MAC address.
The workers remain attached to the home LAN, so isolating household devices
from servers would require a separate access-control design.
[Talos addressing](../../../talos/talconfig.yaml) ·
[Cilium L2 policy](../../../kubernetes/apps/kube-system/cilium/l2-policy.yaml) ·
[LoadBalancer IP pool](../../../kubernetes/apps/kube-system/cilium/ip-pool.yaml)
