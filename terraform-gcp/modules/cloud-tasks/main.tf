variable "name_prefix" { type = string }
variable "project_id" { type = string }
variable "location" { type = string }

variable "workloads_sa_email" {
  description = "Workloads SA that creates tasks at runtime and is named as the OIDC token's identity."
  type        = string
}

variable "queues" {
  description = <<-EOT
    Queues to create, keyed by logical name. Each is created as
    "<name_prefix>-<key>", so one project can hold several environments.

    The application addresses queues by name, so these keys must match the queue
    settings on the server -- see the queue_env_values output.
  EOT

  type = map(object({
    # Cloud Tasks dispatches concurrently by itself, so this is the brake on how many
    # cases hit the model provider at once. An evaluation case makes at least two model
    # calls (the agent, then a judge), which is how a generous default exhausts a
    # provider's concurrent-connection allowance.
    max_concurrent_dispatches = optional(number, 2)
    max_dispatches_per_second = optional(number, 1)

    # Attempts before Cloud Tasks gives up. Note this applies to any non-2xx: unlike
    # the SQS consumer, which drops a message the handler called permanently invalid,
    # Cloud Tasks has no such signal and will spend every attempt.
    max_attempts = optional(number, 3)
  }))

  default = {
    "evaluation-cases"  = {}
    "webhook-processor" = {}
  }
}

# ─── Queues ──────────────────────────────────────────────────────────────────
# The GCP counterpart to the AWS stack's SQS queues, and the shape differs in a way
# that matters: Cloud Tasks performs the HTTP request itself, with an OIDC token it
# mints per dispatch, so there is no consumer to run and no dead-letter queue to
# create. A task that exhausts max_attempts is simply dropped, and the run's staleness
# sweep is what settles a run whose cases stopped arriving.
resource "google_cloud_tasks_queue" "task" {
  for_each = var.queues

  name     = "${var.name_prefix}-${each.key}"
  project  = var.project_id
  location = var.location

  rate_limits {
    max_concurrent_dispatches = each.value.max_concurrent_dispatches
    max_dispatches_per_second = each.value.max_dispatches_per_second
  }

  retry_config {
    max_attempts = each.value.max_attempts
  }
}

# ─── Permissions ─────────────────────────────────────────────────────────────
# Scoped to each queue rather than granted project-wide, following this stack's
# convention of making resource-scoped grants in the module that owns the resource.
resource "google_cloud_tasks_queue_iam_member" "enqueuer" {
  for_each = google_cloud_tasks_queue.task

  project  = each.value.project
  location = each.value.location
  name     = each.value.name
  role     = "roles/cloudtasks.enqueuer"
  member   = "serviceAccount:${var.workloads_sa_email}"
}

# Naming a service account as an OIDC token's identity is an impersonation, so the
# principal creating the task needs iam.serviceAccounts.actAs on it -- which is what
# roles/iam.serviceAccountUser carries. Here the creator and the identity are the same
# account, and a service account does not hold actAs on itself implicitly, so the grant
# is still required.
#
# Not serviceAccountTokenCreator: that governs minting tokens directly through the IAM
# Credentials API, which is a different operation from asking Cloud Tasks to mint one.
resource "google_service_account_iam_member" "act_as_self" {
  service_account_id = "projects/${var.project_id}/serviceAccounts/${var.workloads_sa_email}"
  role               = "roles/iam.serviceAccountUser"
  member             = "serviceAccount:${var.workloads_sa_email}"
}

# ─── Outputs ─────────────────────────────────────────────────────────────────

output "queue_names" {
  description = "Actual queue names, keyed by logical name."
  value       = { for k, q in google_cloud_tasks_queue.task : k => q.name }
}

output "queue_ids" {
  description = "Fully qualified queue ids."
  value       = { for k, q in google_cloud_tasks_queue.task : k => q.id }
}

output "queue_env_values" {
  description = <<-EOT
    The queue-name settings the server needs. Queues are prefixed per environment, so
    the application defaults ("evaluation-cases", "webhook-processor") do not match and
    must be set explicitly.

    Only the server needs these: Cloud Tasks delivers over HTTP by itself, so unlike
    the SQS path there is no consumer in the worker to configure.
  EOT
  value = {
    EVALUATION_QUEUE_NAME = try(google_cloud_tasks_queue.task["evaluation-cases"].name, null)
    WEBHOOK_QUEUE_NAME    = try(google_cloud_tasks_queue.task["webhook-processor"].name, null)
  }
}
