variable "location" { type = string }
variable "repository_id" { type = string }
variable "keep_count" { type = number }
variable "workloads_sa_email" { type = string }

variable "additional_reader_members" {
  description = "Extra IAM members granted pull access, e.g. the GKE node pool SA ['serviceAccount:...']. Image pulls authenticate as the NODE SA, not the Workload Identity SA."
  type        = list(string)
  default     = []
}

# One Docker repository holds all images (server/web/worker/migration) as
# separate packages — this is the idiomatic Artifact Registry layout (unlike
# ECR's one-repo-per-image).
resource "google_artifact_registry_repository" "docker" {
  location      = var.location
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = "Container images for the workflows platform"

  cleanup_policies {
    id     = "keep-recent"
    action = "KEEP"
    most_recent_versions {
      keep_count = var.keep_count
    }
  }
}

resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each = toset(concat(
    ["serviceAccount:${var.workloads_sa_email}"],
    var.additional_reader_members,
  ))

  location   = google_artifact_registry_repository.docker.location
  repository = google_artifact_registry_repository.docker.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}

output "repo_url" {
  # e.g. us-west1-docker.pkg.dev/<project>/workflows  (append /server, /web, ...)
  value = "${google_artifact_registry_repository.docker.location}-docker.pkg.dev/${google_artifact_registry_repository.docker.project}/${google_artifact_registry_repository.docker.repository_id}"
}
