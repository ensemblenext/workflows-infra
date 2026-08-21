terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    # Identity Platform / Firebase resources only exist in the google-beta provider.
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 6.0"
    }
  }

  # Remote state in GCS (native state locking). Configure per-environment via a
  # backend config file: `terraform init -backend-config=environments/prod.gcs.tfbackend`
  # Example prod.gcs.tfbackend:
  #   bucket = "workflows-prod-tf-state"
  #   prefix = "terraform/state"
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project     = var.project_name
    environment = var.environment
    managed_by  = "terraform"
  }
}

provider "google-beta" {
  project = var.project_id
  region  = var.region

  default_labels = {
    project     = var.project_name
    environment = var.environment
    managed_by  = "terraform"
  }
}
