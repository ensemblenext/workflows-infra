# Dev / template environment. Copy to <env>.tfvars and adjust.
# NEVER put secrets here — pass them via TF_VAR_* env vars (see README).

project_id   = "workflows-dev"
region       = "us-west1"
environment  = "dev"
project_name = "workflows"

# GKE / Workload Identity
gke_namespace            = "workflows"
gke_service_account_name = "workflows-sa"

# Feature flags
enable_firebase_auth     = true
enable_artifact_registry = true
enable_scheduler         = false # flip on once app has a GCP scheduler impl
enable_apis              = true

# GCS (permissive for dev)
gcs_force_destroy                      = true
gcs_versioning_enabled                 = true
gcs_noncurrent_version_expiration_days = 30

# Identity Platform / Firebase
firebase_authorized_domains = ["localhost"]
# firebase_google_client_id  = "xxx.apps.googleusercontent.com"
# firebase_google_client_secret -> set via TF_VAR_firebase_google_client_secret

# Artifact Registry
artifact_registry_repo_id    = "workflows"
artifact_registry_keep_count = 10
