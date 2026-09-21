include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//workload-identity"
}

dependency "gke" {
  config_path                             = "../gke"
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    cluster_name           = "mock"
    workload_identity_pool = "mock.svc.id.goog"
  }
}

inputs = {
  # One account, and it exists only to pull images. The control plane's own secrets are OpenBao's
  # (ADR-0066) and its database is in-cluster (ADR-0092 decision 5), so there is nothing else in GCP
  # for a control-plane pod to reach.
  accounts = {
    # CloudNativePG assumes this to write backups (ADR-0099 decision 5). The KSA is the one
    # CNPG creates for the `postgres` Cluster, in the namespace the platform overlay installs
    # into. Bucket-scoped object admin is granted by the `backups` unit, not project-wide here.
    postgres = {
      display_name = "CloudNativePG backups"
      ksa          = "gitfrok/postgres"
      roles        = []
    }
    controlplane = {
      display_name = "gitfrok control plane"
      ksa          = "default/controlplane"
      roles        = ["roles/artifactregistry.reader"]
    }
  }
}
