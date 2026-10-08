# ─── Individual resource outputs ─────────────────────────────────────────────

output "workloads_service_account_email" {
  description = "GCP service account the GKE workloads impersonate via Workload Identity."
  value       = module.iam.workloads_sa_email
}

output "gcs_bucket_names" {
  description = "Map of the three storage bucket names."
  value       = module.gcs.bucket_names
}

output "kms_key_ring" {
  description = "KMS key ring name (shared by all app crypto keys)."
  value       = module.kms.key_ring_name
}

output "kms_key_names" {
  description = "Map of purpose -> crypto key name."
  value       = module.kms.key_names
}

output "app_secret_id" {
  description = "Secret Manager secret id holding the app-secrets JSON blob."
  value       = module.secrets.secret_id
}

output "artifact_registry_repo_url" {
  description = "Base Docker path for pushing/pulling images (append /server, /web, ...)."
  value       = try(module.artifact_registry[0].repo_url, null)
}

# ─── Terraform → Helm bridge (mirrors the AWS helm_config_values output) ─────

output "helm_config_values" {
  description = "Non-secret env vars for the Helm chart's <component>.config."
  value = merge(
    {
      CLOUD_PROVIDER         = "gcp"
      AUTH_PROVIDER          = "firebase"
      SERVERLESS_ENVIRONMENT = "false"

      GOOGLE_CLOUD_PROJECT = var.project_id
      GCP_REGION           = var.region

      STORAGE_USER_FILES_BUCKET        = module.gcs.bucket_names["user_files"]
      STORAGE_DOCUMENTS_BUCKET         = module.gcs.bucket_names["documents"]
      STORAGE_TENANT_MIGRATIONS_BUCKET = module.gcs.bucket_names["tenant_migrations"]

      KMS_LOCATION_ID = var.region

      KMS_SECRETS_KEYRING     = module.kms.key_ring_name
      KMS_SECRETS_KEY         = module.kms.key_names["secrets"]
      KMS_CONNECTIONS_KEYRING = module.kms.key_ring_name
      KMS_CONNECTIONS_KEY     = module.kms.key_names["connections"]
      KMS_ENVIRONMENT_KEYRING = module.kms.key_ring_name
      KMS_ENVIRONMENT_KEY     = module.kms.key_names["environment"]

      FIREBASE_PROJECT_ID = var.project_id

      # Required on GCP generally, and specifically the account the server requires a
      # Cloud Tasks OIDC token to have come from -- it fails closed without this.
      GCP_SERVICE_ACCOUNT = module.iam.workloads_sa_email
    },
    var.enable_scheduler ? {
      SCHEDULER_SERVICE_URL = var.scheduler_callback_url
    } : {},
    # Merged in rather than left to task_queue_env alone: this output is the documented
    # way to populate the chart's config, so a queue setting that only appeared
    # elsewhere would be missed by anyone following it.
    # queue_env_values rather than indexing queue_names here: the module guards those
    # lookups, so overriding task_queues without one of the default keys does not break
    # the plan with an error about a missing map element.
    var.enable_task_queue ? merge(module.cloud_tasks[0].queue_env_values, {
      TASK_QUEUE_ENABLED  = "true"
      TASK_QUEUE_PROVIDER = "cloud-tasks"
    }) : {},
  )
}

output "service_account_annotation" {
  description = "Annotation for the Kubernetes ServiceAccount (Workload Identity, replaces IRSA)."
  value = {
    "iam.gke.io/gcp-service-account" = module.iam.workloads_sa_email
  }
}

# ─── Cloud Tasks ─────────────────────────────────────────────────────────────

output "task_queue_names" {
  description = "Cloud Tasks queue names, keyed by logical name."
  value       = var.enable_task_queue ? module.cloud_tasks[0].queue_names : {}
}

output "task_queue_env" {
  description = <<-EOT
    Queue-related environment values for the SERVER. Cloud Tasks delivers over HTTP by
    itself, so the worker needs none of these -- unlike the SQS path, where the worker
    runs the consumer.

    Queue names are prefixed per environment, so the application's own defaults do not
    match and must be set explicitly.
  EOT
  value = var.enable_task_queue ? merge(
    module.cloud_tasks[0].queue_env_values,
    {
      TASK_QUEUE_ENABLED  = "true"
      TASK_QUEUE_PROVIDER = "cloud-tasks"
    }
  ) : {}
}
