resource "oci_core_vcn" "this" {
  compartment_id = local.compartment_id
  cidr_blocks    = [local.vcn.cidr_block]
  display_name   = local.name
  dns_label      = local.vcn.dns_label
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = local.compartment_id
  vcn_id         = oci_core_vcn.this.id
  display_name   = local.name
  enabled        = true
}

resource "oci_core_default_route_table" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_route_table_id
  display_name               = local.name

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

resource "oci_core_default_security_list" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_security_list_id
  display_name               = local.name

  # Egress: allow all
  egress_security_rules {
    destination = "0.0.0.0/0"
    protocol    = "all"
  }

  # SSH
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "6" # TCP
    tcp_options {
      min = 22
      max = 22
    }
  }

  # ICMP: Path MTU Discovery
  ingress_security_rules {
    source   = "0.0.0.0/0"
    protocol = "1" # ICMP
    icmp_options {
      type = 3
      code = 4
    }
  }

  # ICMP: from VCN
  ingress_security_rules {
    source   = local.vcn.cidr_block
    protocol = "1" # ICMP
    icmp_options {
      type = 3
    }
  }

  # Tailscale: P2P direct connection
  ingress_security_rules {
    source      = "0.0.0.0/0"
    protocol    = "17" # UDP
    description = "Tailscale direct connection"
    udp_options {
      min = local.tailscale_udp_port
      max = local.tailscale_udp_port
    }
  }

  # Game server ports
  dynamic "ingress_security_rules" {
    for_each = local.gateway_tcp_ports
    content {
      source      = "0.0.0.0/0"
      protocol    = "6" # TCP
      description = "Game server port ${ingress_security_rules.value}"
      tcp_options {
        min = ingress_security_rules.value
        max = ingress_security_rules.value
      }
    }
  }
}

resource "oci_core_subnet" "this" {
  compartment_id             = local.compartment_id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = local.subnet.cidr_block
  display_name               = local.name
  dns_label                  = local.subnet.dns_label
  prohibit_internet_ingress  = false
  prohibit_public_ip_on_vnic = false
  route_table_id             = oci_core_default_route_table.this.id
  security_list_ids          = [oci_core_default_security_list.this.id]
  dhcp_options_id            = oci_core_vcn.this.default_dhcp_options_id
}
