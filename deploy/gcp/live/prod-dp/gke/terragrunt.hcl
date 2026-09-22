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

  # ZONAL, same lever as prod-cp: `min_nodes` on a regional cluster is per ZONE, so a floor of 1
  # was three nodes. Delete this line to restore the multi-zone spread; the module defaults to the
  # region, which is what this environment had.
  location = "asia-southeast1-a"

  system_pool = {
    machine_type = "e2-standard-4"

    # Two, for the reason prod-cp's unit spells out: nothing in deploy/k8s/platform/base declares
    # CPU or memory requests, so the cluster autoscaler never sees a pending pod and the floor is
    # the entire budget. Seven pods here -- Postgres 3, Redpanda 3, SeaweedFS 1.
    min_nodes = 2
    max_nodes = 4

    # 100GB pd-balanced, down from 500GB pd-ssd. The old size cited ADR-0033's live bare repos, but
    # that contract belongs to the git tier's PVCs -- which are their own persistent disks, not this
    # boot disk. The git tier landed on 2026-09-23 (deploy/k8s/dataplane) and did NOT need a bigger
    # boot disk. It also shipped its claim as standard-rwo, which VIOLATES ADR-0106 decision 4's
    # premium-rwo requirement for the git tier -- recorded in governance T-0092, not yet fixed.
    disk_size_gb = 100
    disk_type    = "pd-balanced"
  }

  # ADR-0012: CI jobs are untrusted build code and run gVisor-sandboxed. Scaled by KEDA on queue
  # depth from zero, hence min_nodes = 0 -- this pool is free while idle, and every number below is
  # about what it costs when it is NOT.
  runner_pool = {
    # e2-standard-4. GKE Sandbox refuses SHARED-CORE machine types, which is what the module's
    # variable comment means by "not a free choice" -- e2-micro/small/medium are out, e2-standard-4
    # is not shared-core and is allowed.
    machine_type = "e2-standard-4"
    min_nodes    = 0

    # Four, not twenty. The ceiling is the only thing standing between a busy queue and a four-figure
    # month, and no CI job has ever run here. Raise it when real throughput demands it -- that is a
    # one-line change with no rebuild, unlike everything else in this file.
    max_nodes    = 4
    disk_size_gb = 100
    disk_type    = "pd-balanced"
  }
}
