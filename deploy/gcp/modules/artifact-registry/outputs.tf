output "repository_url" {
  description = "The prefix an image pin is written against."
  value       = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}
