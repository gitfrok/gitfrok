# Where first-party images live. One of the four cloud APIs ADR-0092 decision 5 accepts, because
# Kubernetes has no registry of its own.
#
# This module does not decide that Artifact Registry becomes the *publish* target for releases —
# ADR-0047 leaves that to whichever registry can be verified offline, and it stays a follow-up.

resource "google_artifact_registry_repository" "images" {
  project       = var.project_id
  location      = var.region
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = "gitfrok first-party images (${var.env_name})"

  labels = var.labels

  docker_config {
    immutable_tags = var.immutable_tags
  }
}

resource "google_artifact_registry_repository_iam_member" "readers" {
  for_each = toset(var.reader_members)

  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}
