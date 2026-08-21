variable "name_prefix" { type = string }
variable "workloads_sa_email" { type = string }

# Single Secret Manager secret holding a JSON blob of app secrets. External
# Secrets Operator syncs it into the k8s `app-secrets` secret via
# `dataFrom.extract` (each JSON key becomes an env var).
resource "google_secret_manager_secret" "app_secrets" {
  secret_id = "${var.name_prefix}-app-secrets"

  replication {
    auto {}
  }
}

# Seed an initial version with EMPTY placeholders. Real values are written
# out-of-band (console / CI), so we ignore changes to the data afterwards.
resource "google_secret_manager_secret_version" "initial" {
  secret = google_secret_manager_secret.app_secrets.id

  secret_data = jsonencode({
    # Required
    PG_BASE_URL      = ""
    TEMPORAL_API_KEY = ""
    # Firebase Admin (server-side token verification)
    FIREBASE_PROJECT_ID   = ""
    FIREBASE_CLIENT_EMAIL = ""
    FIREBASE_PRIVATE_KEY  = ""
    # Optional integrations (add as needed)
    OPENAI_API_KEY           = ""
    ANTHROPIC_API_KEY        = ""
    GEMINI_API_KEY           = ""
    VECTOR_EMBEDDING_API_KEY = ""
  })

  lifecycle {
    ignore_changes = [secret_data]
  }
}

# Allow the workloads SA (and thus External Secrets Operator running as it) to
# read the secret.
resource "google_secret_manager_secret_iam_member" "accessor" {
  secret_id = google_secret_manager_secret.app_secrets.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${var.workloads_sa_email}"
}

output "secret_id" {
  value = google_secret_manager_secret.app_secrets.secret_id
}
