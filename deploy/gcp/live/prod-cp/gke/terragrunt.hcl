include "root" {
  path = find_in_parent_folders("root.hcl")
}

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//gke-cluster"
}

dependency "network" {
  config_path                             = "../network"
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    network_name        = "mock-vpc"
    network_id          = "mock"
    subnet_name         = "mock-subnet"
    pods_range_name     = "pods"
    services_range_name = "services"
  }
}

inputs = {
  network_name        = dependency.network.outputs.network_name
  subnet_name         = dependency.network.outputs.subnet_name
  pods_range_name     = dependency.network.outputs.pods_range_name
  services_range_name = dependency.network.outputs.services_range_name

  master_cidr = local.env.master_cidr

  # Public API endpoint, restricted by list. The control plane is the side that must be reachable.
  private_endpoint           = false
  master_authorized_networks = local.env.admin_networks

  # No runner pool: the control plane runs no untrusted build code, so ADR-0012's gVisor pool has
  # nothing to isolate here.
  runner_pool = null

  system_pool = {
    machine_type = "n2-standard-4"
    min_nodes    = 1
    max_nodes    = 5
    disk_size_gb = 200
    disk_type    = "pd-ssd"
  }
}
