output "service_account_email" {
  description = "Grant this `roles/artifactregistry.writer` on the repository it publishes to (the artifact-registry unit's `writer_members`)."
  value       = google_service_account.publisher.email
}

output "workload_identity_provider" {
  description = "The full provider resource name the workflow passes to google-github-actions/auth as `workload_identity_provider`."
  value       = google_iam_workload_identity_pool_provider.github.name
}

output "workflow_inputs" {
  description = "Everything the image-publish workflow needs, and none of it secret — which is the point of decision 5."
  value = {
    workload_identity_provider = google_iam_workload_identity_pool_provider.github.name
    service_account            = google_service_account.publisher.email
    allowed_repository         = var.github_repository
    allowed_environment        = var.github_environment
  }
}
