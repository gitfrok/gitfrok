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

  # Who may reach the Kubernetes API from a public address: NOBODY. The endpoint is private
  # (ADR-0097 decision 1) and this list is empty, which is the same shape prod-dp has always had.
  # Operators reach the API through Cloudflare Zero Trust over a tunnel from a connector inside this
  # VPC — Access authorizes the person, so there is no network location to allow-list.
  #
  # This is NOT the agent path. The agent talks to the application surface over gRPC/mTLS (ADR-0017),
  # never to the Kubernetes API, and ADR-0095's three public hostnames are unaffected by any of this.
  #
  # History, so nobody re-derives it: earlier on 2026-09-22 this list was empty for the OPPOSITE
  # reason — the owner had accepted an unrestricted public endpoint, and empty was how the module
  # expresses that (GKE refuses a literal 0.0.0.0/0 entry, and the module omits the whole block when
  # the list is empty). The owner reversed that within the day. The list looks identical and now
  # means the inverse, because what changed is `private_endpoint` in the gke unit, not this value.
  #
  # ADR-0097 decision 5's break-glass, if Access is ever unavailable: put a real operator CIDR here
  # AND set `private_endpoint = false` in `gke/terragrunt.hcl`. Both, or the CIDR does nothing.
  admin_networks = []
}
