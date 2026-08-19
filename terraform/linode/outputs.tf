output "gateway_ipv4" {
  value = one(linode_instance.gateway.ipv4)
}
