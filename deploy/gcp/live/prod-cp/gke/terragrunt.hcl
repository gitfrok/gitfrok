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

  # PRIVATE API endpoint (ADR-0097 decision 1). The control plane is the side whose APPLICATION
  # surface must be reachable — ADR-0095's Gateway and L4 door serve that — and its Kubernetes API is
  # a different door entirely. Operators reach it through Cloudflare Zero Trust over a tunnel from
  # inside the VPC (ADR-0097 decisions 2-4), so there is no authorized-network list to maintain and
  # nothing reaches the API from the internet. This now matches prod-dp exactly.
  #
  # Create-time in practice: toggling this on a live cluster is not reliably in-place across provider
  # versions, which is why ADR-0097 landed before the first apply rather than after.
  private_endpoint           = true
  master_authorized_networks = local.env.admin_networks

  # No runner pool: the control plane runs no untrusted build code, so ADR-0012's gVisor pool has
  # nothing to isolate here.
  runner_pool = null

  # ZONAL, deliberately, and this is the single largest cost lever in the tree. A regional cluster
  # creates `min_nodes` nodes PER ZONE, so `min_nodes = 1` across asia-southeast1's three zones was
  # three nodes, not one. Zonal trades the managed control plane's multi-zone spread for roughly a
  # third of the node bill. Residency is untouched: the zone is inside the same region (G7).
  #
  # To restore multi-zone HA, delete this line. The module defaults to the region.
  location = "asia-southeast1-a"

  system_pool = {
    # Same 4 vCPU / 16 GB as n2-standard-4, cheaper family.
    machine_type = "e2-standard-4"

    # TWO, not one, and the reason is that autoscaling cannot rescue an undersized floor here: no
    # workload in deploy/k8s/platform/base sets CPU or memory requests, so every pod is schedulable
    # and the cluster autoscaler never sees a pending pod to scale up FOR. The floor is the whole
    # budget. Twelve pods -- OpenBao 3, Postgres 3, Redpanda 3, Zitadel 2, Valkey 1 -- do not fit in
    # one node's ~13 GB allocatable alongside kube-system; they would not fail to schedule, they
    # would get evicted under memory pressure, which is a much worse failure to read.
    min_nodes = 2
    max_nodes = 4

    # pd-balanced, not pd-ssd. The pd-ssd default is justified by ADR-0033's live bare repos on
    # block volumes -- and the git tier is a DATA-PLANE concern. Nothing on the control plane has
    # that latency contract, so prod-dp keeps the module default and this environment does not.
    disk_size_gb = 100
    disk_type    = "pd-balanced"
  }
}
