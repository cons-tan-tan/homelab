resource "google_storage_bucket" "tfstate" {
  name     = "${local.project_id}-tfstate"
  location = local.region

  # tfstateの誤削除防止
  force_destroy = false

  # バージョニングでstate履歴を保持
  versioning {
    enabled = true
  }

  # 均一なバケットレベルアクセス制御
  uniform_bucket_level_access = true

  # 公開アクセス防止
  public_access_prevention = "enforced"

  # 古いバージョンのライフサイクル管理
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
