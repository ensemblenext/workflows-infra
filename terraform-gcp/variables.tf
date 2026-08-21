# ─── Core ────────────────────────────────────────────────────────────────────

variable "project_id" {
  description = "GCP project ID. Prefer one project per environment (prod/staging)."
  type        = string
}

variable "region" {
  description = "Default GCP region for regional resources (GCS, KMS, Artifact Registry)."
  type        = string
  default     = "us-west1"
}

variable "environment" {
  description = "Deployment environment (e.g. dev, staging, prod)."
  type        = string
}

variable "project_name" {
  description = "Logical project name, used for resource name prefixes."
  type        = string
  default     = "workflows"
}

# ─── GKE / Workload Identity wiring ──────────────────────────────────────────
# Mirrors the AWS IRSA wiring: bind a Kubernetes SA to a GCP service account.

variable "gke_namespace" {
  description = "Kubernetes namespace the workloads run in."
  type        = string
  default     = "workflows"
}

variable "gke_service_account_name" {
  description = "Kubernetes service account name the workloads use."
  type        = string
  default     = "workflows-sa"
}

# ─── Feature flags (mirror the AWS enable_* toggles) ─────────────────────────

variable "enable_firebase_auth" {
  description = "Provision Identity Platform (Firebase Auth) config."
  type        = bool
  default     = true
}

variable "enable_artifact_registry" {
  description = "Provision the Artifact Registry Docker repository."
  type        = bool
  default     = true
}

variable "enable_scheduler" {
  description = "Provision Cloud Scheduler wiring (invoker SA + API). NOTE: requires a GCP scheduler implementation in the app."
  type        = bool
  default     = false
}

variable "enable_apis" {
  description = "Enable the required Google APIs on the project via Terraform."
  type        = bool
  default     = true
}

# ─── GCS ─────────────────────────────────────────────────────────────────────

variable "gcs_force_destroy" {
  description = "Allow Terraform to destroy non-empty buckets (dev only)."
  type        = bool
  default     = false
}

variable "gcs_versioning_enabled" {
  description = "Enable object versioning on the buckets."
  type        = bool
  default     = true
}

variable "gcs_noncurrent_version_expiration_days" {
  description = "Delete noncurrent object versions after N days."
  type        = number
  default     = 90
}

# ─── Firebase / Identity Platform ────────────────────────────────────────────

variable "firebase_authorized_domains" {
  description = "Authorized domains for Identity Platform (redirect/callback domains)."
  type        = list(string)
  default     = ["localhost"]
}

variable "firebase_google_client_id" {
  description = "Google IdP client ID for 'Sign in with Google' (empty disables it)."
  type        = string
  default     = ""
}

variable "firebase_google_client_secret" {
  description = "Google IdP client secret. Pass via TF_VAR_firebase_google_client_secret, never in tfvars."
  type        = string
  default     = ""
  sensitive   = true
}

# ─── Artifact Registry ───────────────────────────────────────────────────────

variable "artifact_registry_repo_id" {
  description = "Artifact Registry repository ID (holds server/web/worker/migration images)."
  type        = string
  default     = "workflows"
}

variable "artifact_registry_keep_count" {
  description = "Number of most-recent image versions to keep per package."
  type        = number
  default     = 10
}

# ─── Scheduler ───────────────────────────────────────────────────────────────

variable "scheduler_callback_url" {
  description = "HTTPS endpoint Cloud Scheduler invokes (the server's scheduler callback)."
  type        = string
  default     = ""
}
