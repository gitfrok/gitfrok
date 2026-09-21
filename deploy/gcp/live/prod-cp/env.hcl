# The control-plane environment (ADR-0092 decision 2).
#
# This is the side that holds multi-tenant metadata, billing, the release service and OpenBao
# custody (ADR-0066), and it is the side the ADR-0011 agent dials INTO — so unlike the data plane it
# has a public address and a name.
#
# Terragrunt creates this environment's state bucket as PROJECT-tfstate on first run.
#
# There is no dns_name here any more: ADR-0095 decision 4 made Cloudflare authoritative for
# `7.solutions` and decision 10 retired the Cloud DNS unit, so this environment serves no zone. The
# three records — app-gitfrok, auth-gitfrok, agents-gitfrok — live in the Cloudflare apex zone and
# are created operator-side, not here.

locals {
  env_name   = "prod-cp"
  project_id = "gitfrok-prod-cp"      # created 2026-09-22, billing 2025-10280-7Solutions
  region     = "asia-southeast1"      # Singapore — nearest GKE region; residency is a G7 fact

  labels = {
    managed-by = "terragrunt"
    plane      = "control"
    env        = "prod"
  }

  # Nodes, pods, services, and the managed endpoint's /28. Declared rather than auto-allocated.
  subnet_cidr   = "10.10.0.0/20"
  pods_cidr     = "10.20.0.0/14"
  services_cidr = "10.24.0.0/20"
  master_cidr   = "172.16.0.0/28"

  # Who may reach the Kubernetes API. This is the operator's own network, NOT the agent path — the
  # agent talks to the application surface over gRPC/mTLS (ADR-0017), never to the Kubernetes API.
  #
  # DELIBERATELY EMPTY, AND THAT MEANS AN OPEN PUBLIC ENDPOINT. The deciding owner accepted an
  # unrestricted Kubernetes API on 2026-09-22 when offered a specific operator CIDR instead. It is
  # expressed as an empty list rather than as a `0.0.0.0/0` entry because GKE's
  # master-authorized-networks API refuses that value, while the module omits the whole
  # `master_authorized_networks_config` block when this list is empty — which, with
  # `private_endpoint = false`, is the same posture the owner chose and the only one the API accepts.
  #
  # Authentication still applies; what is gone is the network restriction. Narrowing this to a real
  # CIDR is a one-line change here and needs no ADR.
  admin_networks = []
}
