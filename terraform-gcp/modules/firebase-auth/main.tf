terraform {
  required_providers {
    google-beta = {
      source = "hashicorp/google-beta"
    }
  }
}

variable "project_id" { type = string }
variable "authorized_domains" { type = list(string) }
variable "google_client_id" { type = string }
variable "google_client_secret" {
  type      = string
  sensitive = true
}

# Identity Platform = the GCP/enterprise tier of Firebase Auth (same backend,
# same SDKs). Managed here via google-beta.
#
# NOTE: Identity Platform must be enabled on the project once (Console →
# Identity Platform → "Enable"), and if the frontend needs the Firebase web
# config (FIREBASE_API_KEY / AUTH_DOMAIN), register a web app via the Firebase
# console or `google_firebase_web_app` — those are not fully covered here.
resource "google_identity_platform_config" "default" {
  provider = google-beta
  project  = var.project_id

  autodelete_anonymous_users = true

  sign_in {
    allow_duplicate_emails = false

    email {
      enabled           = true
      password_required = true
    }
  }

  authorized_domains = var.authorized_domains
}

# "Sign in with Google" IdP — mirrors the optional Google provider in the AWS
# Cognito module. Enabled only when a client id is supplied.
resource "google_identity_platform_default_supported_idp_config" "google" {
  count = var.google_client_id != "" ? 1 : 0

  provider      = google-beta
  project       = var.project_id
  enabled       = true
  idp_id        = "google.com"
  client_id     = var.google_client_id
  client_secret = var.google_client_secret

  depends_on = [google_identity_platform_config.default]
}

output "identity_platform_project" {
  value = var.project_id
}
