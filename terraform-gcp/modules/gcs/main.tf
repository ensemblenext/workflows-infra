variable "name_prefix" { type = string }
variable "project_id" { type = string }
variable "location" { type = string }
variable "force_destroy" { type = bool }
variable "versioning_enabled" { type = bool }
variable "noncurrent_version_expiration_days" { type = number }
variable "workloads_sa_email" { type = string }

variable "user_files_cors_origins" {
  description = "Origins allowed to hit the user-files bucket directly (browser uploads). Empty = no CORS."
  type        = list(string)
  default     = []
}

locals {
  # key -> globally-unique bucket name. GCS names are global, so prefix with the
  # project id (which is unique per environment when using project-per-env).
  buckets = {
    user_files        = "${var.project_id}-user-files"
    documents         = "${var.project_id}-documents"
    tenant_migrations = "${var.project_id}-tenant-migrations"
  }
}

resource "google_storage_bucket" "this" {
  for_each = local.buckets

  name                        = each.value
  project                     = var.project_id
  location                    = var.location
  force_destroy               = var.force_destroy
  uniform_bucket_level_access = true

  versioning {
    enabled = var.versioning_enabled
  }

  dynamic "lifecycle_rule" {
    for_each = var.versioning_enabled ? [1] : []
    content {
      condition {
        days_since_noncurrent_time = var.noncurrent_version_expiration_days
      }
      action {
        type = "Delete"
      }
    }
  }

  # CORS only on the user-files bucket, and only for explicitly-listed origins
  # (avoid the wide-open "*" the AWS bucket used).
  dynamic "cors" {
    for_each = each.key == "user_files" && length(var.user_files_cors_origins) > 0 ? [1] : []
    content {
      origin          = var.user_files_cors_origins
      method          = ["GET", "PUT", "POST", "HEAD"]
      response_header = ["Content-Type", "Authorization"]
      max_age_seconds = 3600
    }
  }
}

# Grant the workloads SA read/write on each bucket's objects.
resource "google_storage_bucket_iam_member" "workloads" {
  for_each = google_storage_bucket.this

  bucket = each.value.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${var.workloads_sa_email}"
}

output "bucket_names" {
  value = { for k, v in google_storage_bucket.this : k => v.name }
}
