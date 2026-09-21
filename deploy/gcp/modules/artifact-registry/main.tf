# Where first-party images live. One of the four cloud APIs ADR-0092 decision 5 accepts, because
# Kubernetes has no registry of its own.
#
# ADR-0098 (Accepted 2026-09-22) makes this the publish target, replacing ADR-0047's ghcr.io. Two
# consequences live in the inputs rather than here: the repository is made publicly readable on
# purpose (decision 2 — a BYO customer must pull without a vendor credential), and exactly one
# principal may write to it (decision 5's keyless publisher).

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

# Write access, kept deliberately separate from read. There should be exactly one writer — the
# keyless publisher of ADR-0098 decision 5 — while readers include `allUsers`. Collapsing the two
# into one list is how a public registry acquires a public writer.
resource "google_artifact_registry_repository_iam_member" "writers" {
  for_each = toset(var.writer_members)

  project    = var.project_id
  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.writer"
  member     = each.value
}
