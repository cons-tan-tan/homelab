locals {
  workload_identity_services = toset([
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])
}

resource "google_project_service" "workload_identity" {
  for_each = local.workload_identity_services

  project = local.project_id
  service = each.value

  disable_on_destroy = false
}
