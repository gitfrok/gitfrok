output "service_account_emails" {
  value = { for key, account in google_service_account.this : key => account.email }
}

output "ksa_annotations" {
  description = <<-DESC
    The annotation each Kubernetes service account needs, keyed by namespace/name. OpenTofu does not
    apply these — a Kubernetes object is the workload layer's (ADR-0092 decision 4). Hand them to
    whatever renders the manifests.
  DESC
  value = {
    for key, account in var.accounts :
    account.ksa => "iam.gke.io/gcp-service-account=${google_service_account.this[key].email}"
  }
}
