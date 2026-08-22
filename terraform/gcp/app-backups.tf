resource "google_storage_bucket" "app_backups_30d" {
  name     = "${local.project_id}-app-backups-30d"
  location = local.region

  storage_class = "NEARLINE"
  force_destroy = false

  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  lifecycle_rule {
    condition {
      age = 30
    }
    action {
      type = "Delete"
    }
  }

  soft_delete_policy {
    retention_duration_seconds = 604800 # 7 days
  }
}

resource "google_storage_bucket_iam_member" "minecraft_backup_creator" {
  bucket = google_storage_bucket.app_backups_30d.name
  role   = "roles/storage.objectCreator"
  member = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.kubernetes.name}/subject/${local.kubernetes_wif.subject}"

  condition {
    title       = "minecraft-backups-only"
    description = "Allow the Minecraft backup uploader to create objects only below minecraft/."
    expression  = "resource.name.startsWith(\"projects/_/buckets/${google_storage_bucket.app_backups_30d.name}/objects/minecraft/\")"
  }

  depends_on = [google_iam_workload_identity_pool_provider.talos]
}
