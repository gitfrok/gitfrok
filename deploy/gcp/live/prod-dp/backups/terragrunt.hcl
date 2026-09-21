include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//backups"
}

dependency "services" {
  config_path                             = "../project-services"
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    enabled_services = []
  }
}

dependency "wi" {
  config_path                             = "../workload-identity"
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    service_account_emails = { postgres = "mock-postgres@example.iam.gserviceaccount.com" }
  }
}

inputs = {
  # CloudNativePG reaches the bucket with `googleCredentials.gkeEnvironment: true`, which means the
  # pod's Workload Identity — so the writer is a Google service account bound to the cluster's
  # Kubernetes service account, and no key exists.
  writer_members = ["serviceAccount:${dependency.wi.outputs.service_account_emails["postgres"]}"]

  # A starting value. ADR-0099's register row asks for a real recovery objective.
  retention_days = 30
}
