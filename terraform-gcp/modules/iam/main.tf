variable "name_prefix" { type = string }
variable "project_id" { type = string }
variable "gke_namespace" { type = string }
variable "gke_service_account_name" { type = string }

# Service account the workloads run as (GKE Workload Identity target).
# Equivalent of the AWS "workloads" IRSA role.
resource "google_service_account" "workloads" {
  account_id   = "${var.name_prefix}-workloads"
  display_name = "${var.name_prefix} workloads (server/web/worker)"
  project      = var.project_id
}

# Bind the Kubernetes SA to this GCP SA (Workload Identity).
# member format: serviceAccount:<project>.svc.id.goog[<namespace>/<ksa>]
resource "google_service_account_iam_member" "workload_identity" {
  service_account_id = google_service_account.workloads.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.gke_namespace}/${var.gke_service_account_name}]"
}

# Project-level roles that aren't scoped to a single resource.
# Resource-scoped grants (buckets, KMS keys, the secret, the AR repo) are made
# in their own modules against this SA's email.
locals {
  project_roles = [
    "roles/aiplatform.user",   # Vertex AI (Gemini / vertex-anthropic)
    "roles/logging.logWriter", # write app logs
  ]
}

resource "google_project_iam_member" "workloads" {
  for_each = toset(local.project_roles)

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.workloads.email}"
}

output "workloads_sa_email" {
  value = google_service_account.workloads.email
}
