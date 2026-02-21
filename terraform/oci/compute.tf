resource "oci_core_instance" "this" {
  availability_domain = local.availability_domain
  compartment_id      = local.compartment_id
  shape               = "VM.Standard.E2.1.Micro"
  display_name        = local.name

  create_vnic_details {
    subnet_id        = oci_core_subnet.this.id
    assign_public_ip = true
    display_name     = local.name
  }

  lifecycle {
    prevent_destroy = true
  }
}
