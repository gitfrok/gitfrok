# The vendor's own data-plane environment (ADR-0092 decision 2).
#
# This is us as our own first customer — a reference deployment, not a second control plane and not
# an exception to ADR-0009's BYO topology. It installs the ADR-0013 chart and enrols over the same
# outbound channel a customer's data plane would.
#
# The defining property: there is no inbound path (ADR-0011). The cluster's Kubernetes API is
# private, there is no DNS zone, and no unit here creates a load balancer. If a future change adds
# an inbound surface to this environment, that is a change to ADR-0011 and needs its own ADR.

locals {
  env_name   = "prod-dp"
  project_id = "gitfrok-prod-dp"      # TODO: set to the real project before first apply
  region     = "asia-southeast1"      # same region as the control plane; residency is a G7 fact

  labels = {
    managed-by = "terragrunt"
    plane      = "data"
    env        = "prod"
  }

  # Distinct from prod-cp's ranges. They are in separate VPCs and never peer, but keeping them
  # disjoint means a future peering or VPN is not blocked by an address collision.
  subnet_cidr   = "10.40.0.0/20"
  pods_cidr     = "10.48.0.0/14"
  services_cidr = "10.52.0.0/20"
  master_cidr   = "172.16.1.0/28"

  # Where this data plane pulls first-party images from. Cross-project, and public per ADR-0047.
  image_registry_project = "gitfrok-prod-cp"
}
