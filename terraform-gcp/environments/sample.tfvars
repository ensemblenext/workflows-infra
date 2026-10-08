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

# Background task queue (TASK_QUEUE_PROVIDER=cloud-tasks).
# Creates the Cloud Tasks queues and grants the workloads SA cloudtasks.enqueuer on
# each, plus iam.serviceAccountUser on itself so it may name itself as the OIDC token's
# identity. Create the queues before setting TASK_QUEUE_ENABLED=true on the server:
# with the queue enabled and nothing to enqueue into, every evaluation run is marked
# failed rather than falling back. `terraform output task_queue_env` prints the server
# settings; unlike the SQS stack, the worker needs nothing.
enable_task_queue = false

# Queues to create, keyed by logical name. Each becomes <prefix>-<key>, e.g.
# workflows-prod-evaluation-cases. max_concurrent_dispatches defaults to 2 and is the
# only brake on concurrent model calls, since each case invokes an agent and then a
# judge. Override a queue's limits like:
#
#   "webhook-processor" = { max_concurrent_dispatches = 10, max_attempts = 5 }
task_queues = {
  "evaluation-cases"  = {}
  "webhook-processor" = {}
}

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
