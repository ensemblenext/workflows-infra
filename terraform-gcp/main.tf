locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # APIs the stack needs. Firebase/scheduler ones are only enabled with their flags.
  required_apis = concat(
    [
      "cloudkms.googleapis.com",
      "storage.googleapis.com",
      "secretmanager.googleapis.com",
      "iam.googleapis.com",
      "iamcredentials.googleapis.com",
      "aiplatform.googleapis.com", # Vertex AI (the Bedrock equivalent)
    ],
    var.enable_artifact_registry ? ["artifactregistry.googleapis.com"] : [],
    var.enable_firebase_auth ? ["identitytoolkit.googleapis.com", "firebase.googleapis.com"] : [],
    var.enable_scheduler ? ["cloudscheduler.googleapis.com"] : [],
  )
}

data "google_project" "current" {}

resource "google_project_service" "enabled" {
  for_each = var.enable_apis ? toset(local.required_apis) : toset([])

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# ─── IAM: workloads service account + Workload Identity binding ──────────────
module "iam" {
  source = "./modules/iam"

  name_prefix              = local.name_prefix
  project_id               = var.project_id
  gke_namespace            = var.gke_namespace
  gke_service_account_name = var.gke_service_account_name

  depends_on = [google_project_service.enabled]
}

# ─── KMS: key ring + per-purpose crypto keys ─────────────────────────────────
module "kms" {
  source = "./modules/kms"

  name_prefix        = local.name_prefix
  location           = var.region
  workloads_sa_email = module.iam.workloads_sa_email

  depends_on = [google_project_service.enabled]
}

# ─── GCS: user-files / documents / tenant-migrations buckets ─────────────────
module "gcs" {
  source = "./modules/gcs"

  name_prefix                        = local.name_prefix
  project_id                         = var.project_id
  location                           = var.region
  force_destroy                      = var.gcs_force_destroy
  versioning_enabled                 = var.gcs_versioning_enabled
  noncurrent_version_expiration_days = var.gcs_noncurrent_version_expiration_days
  workloads_sa_email                 = module.iam.workloads_sa_email

  depends_on = [google_project_service.enabled]
}

# ─── Secret Manager: app-secrets blob (synced into k8s by External Secrets) ──
module "secrets" {
  source = "./modules/secrets"

  name_prefix        = local.name_prefix
  workloads_sa_email = module.iam.workloads_sa_email

  depends_on = [google_project_service.enabled]
}

# ─── Firebase Auth / Identity Platform ───────────────────────────────────────
module "firebase_auth" {
  source = "./modules/firebase-auth"
  count  = var.enable_firebase_auth ? 1 : 0

  project_id           = var.project_id
  authorized_domains   = var.firebase_authorized_domains
  google_client_id     = var.firebase_google_client_id
  google_client_secret = var.firebase_google_client_secret

  depends_on = [google_project_service.enabled]
}

# ─── Artifact Registry: Docker repo for server/web/worker/migration images ───
module "artifact_registry" {
  source = "./modules/artifact-registry"
  count  = var.enable_artifact_registry ? 1 : 0

  location           = var.region
  repository_id      = var.artifact_registry_repo_id
  keep_count         = var.artifact_registry_keep_count
  workloads_sa_email = module.iam.workloads_sa_email

  depends_on = [google_project_service.enabled]
}

# ─── Cloud Scheduler wiring (invoker SA). Requires app-side GCP support. ──────
module "scheduler" {
  source = "./modules/scheduler"
  count  = var.enable_scheduler ? 1 : 0

  name_prefix        = local.name_prefix
  callback_url       = var.scheduler_callback_url
  workloads_sa_email = module.iam.workloads_sa_email

  depends_on = [google_project_service.enabled]
}
