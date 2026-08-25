include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
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
  # Deliberately thin. The data plane's stores are all in-cluster (ADR-0092 decision 5), so no pod
  # here needs a GCS bucket, a Cloud SQL instance or a KMS key. Image pull is the only cloud API a
  # data-plane workload touches, and the registry lives in the control-plane project — so the read
  # grant is made THERE, against this account's email, not here.
  accounts = {
    dataplane = {
      display_name = "gitfrok data plane"
      ksa          = "default/dataplane"
      roles        = []
    }
  }
}
