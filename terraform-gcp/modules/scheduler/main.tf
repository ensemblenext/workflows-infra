variable "name_prefix" { type = string }
variable "callback_url" { type = string }

variable "workloads_sa_email" {
  description = "Workloads SA that creates schedules at runtime (needs scheduler admin + actAs on the invoker SA)."
  type        = string
  default     = ""
}

# The AWS side used EventBridge Scheduler + API destinations. The GCP equivalent
# is Cloud Scheduler jobs that call the app's callback with an OIDC token minted
# by a dedicated invoker SA. Schedules are created by the app at runtime, so
# Terraform only provisions the invoker identity + permissions.
#
# ⚠️ REQUIRES app-side support: a GCP implementation in `@repo/shared/scheduler`
# that creates Cloud Scheduler jobs (the current abstraction is EventBridge-only).
resource "google_service_account" "invoker" {
  account_id   = "${var.name_prefix}-scheduler-invoker"
  display_name = "${var.name_prefix} Cloud Scheduler invoker (OIDC to callback)"
}

# Let the workloads SA create schedule jobs and run them as the invoker SA.
resource "google_project_iam_member" "scheduler_admin" {
  count = var.workloads_sa_email != "" ? 1 : 0

  project = google_service_account.invoker.project
  role    = "roles/cloudscheduler.admin"
  member  = "serviceAccount:${var.workloads_sa_email}"
}

resource "google_service_account_iam_member" "act_as_invoker" {
  count = var.workloads_sa_email != "" ? 1 : 0

  service_account_id = google_service_account.invoker.name
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.workloads_sa_email}"
}

output "invoker_sa_email" {
  value = google_service_account.invoker.email
}

output "callback_url" {
  value = var.callback_url
}
