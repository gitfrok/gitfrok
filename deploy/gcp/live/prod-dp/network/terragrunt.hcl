include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//network"
}

dependency "services" {
  config_path                             = "../project-services"
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    enabled_services = []
  }
}

inputs = {
  subnet_cidr   = local.env.subnet_cidr
  pods_cidr     = local.env.pods_cidr
  services_cidr = local.env.services_cidr
  master_cidr   = local.env.master_cidr

  # NAT is not optional here. With a private endpoint and private nodes, this is the only route out,
  # and without a route out the agent cannot dial the control plane at all (ADR-0011).
  enable_nat = true
}
