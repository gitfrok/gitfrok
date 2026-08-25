output "cluster_name" {
  value = google_container_cluster.this.name
}

output "cluster_endpoint" {
  description = "Kubernetes API endpoint. Private on the data plane."
  value       = google_container_cluster.this.endpoint
  sensitive   = true
}

output "workload_identity_pool" {
  value = "${var.project_id}.svc.id.goog"
}

output "runner_pool_taint" {
  description = "What a CI job's pod spec must tolerate to land on a sandboxed node."
  value       = var.runner_pool == null ? null : "gitfrok.io/runners=true:NoSchedule"
}

output "get_credentials_command" {
  description = "How an operator points kubectl at this cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --region ${var.region} --project ${var.project_id}"
}
