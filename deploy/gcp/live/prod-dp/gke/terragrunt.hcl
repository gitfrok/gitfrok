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

  # The whole point of this environment's shape. A private endpoint with no authorized networks is
  # reachable only from inside the VPC — reach it from a bastion or over IAP, never from the
  # internet. This is ADR-0011 made structural rather than aspirational.
  private_endpoint           = true
  master_authorized_networks = []

  system_pool = {
    machine_type = "n2-standard-4"
    min_nodes    = 1
    max_nodes    = 6
    # The git tier keeps live bare repos on block volumes (ADR-0033), and SeaweedFS FUSE serves only
    # large objects (ADR-0050) — so the node disk under the git PVCs is the latency-critical one.
    disk_size_gb = 500
    disk_type    = "pd-ssd"
  }

  # ADR-0012: CI jobs are untrusted build code and run gVisor-sandboxed. Scaled by KEDA on queue
  # depth from zero, hence min_nodes = 0.
  runner_pool = {
    machine_type = "n2-standard-8"
    min_nodes    = 0
    max_nodes    = 20
    disk_size_gb = 200
    disk_type    = "pd-balanced"
  }
}
