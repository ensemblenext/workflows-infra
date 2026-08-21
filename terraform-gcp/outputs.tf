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
    },
    var.enable_scheduler ? {
      SCHEDULER_SERVICE_URL = var.scheduler_callback_url
    } : {},
  )
}

output "service_account_annotation" {
  description = "Annotation for the Kubernetes ServiceAccount (Workload Identity, replaces IRSA)."
  value = {
    "iam.gke.io/gcp-service-account" = module.iam.workloads_sa_email
  }
}
