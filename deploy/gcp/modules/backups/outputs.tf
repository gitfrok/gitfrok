output "bucket_name" {
  description = "The value the CNPG Cluster's destinationPath must carry. Nothing cross-checks the two yet — recorded in T-0086."
  value       = google_storage_bucket.postgres_backups.name
}

output "destination_path" {
  description = "Paste-ready for the overlay's barmanObjectStore patch."
  value       = "gs://${google_storage_bucket.postgres_backups.name}/postgres"
}
