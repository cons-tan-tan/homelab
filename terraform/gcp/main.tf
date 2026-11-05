resource "google_storage_bucket" "tfstate" {
  name     = "${local.project_id}-tfstate"
  location = local.region

  # Guard against accidental deletion of Terraform state.
  force_destroy = false

  # Preserve state history through versioning.
  versioning {
    enabled = true
  }

  # Uniform bucket-level access control.
  uniform_bucket_level_access = true

  # Prevent public access.
  public_access_prevention = "enforced"

  # Manage the lifecycle of older versions.
  lifecycle_rule {
    condition {
      num_newer_versions = 5
      with_state         = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }
}
