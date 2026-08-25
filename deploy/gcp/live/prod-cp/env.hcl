# The control-plane environment (ADR-0092 decision 2).
#
# This is the side that holds multi-tenant metadata, billing, the release service and OpenBao
# custody (ADR-0066), and it is the side the ADR-0011 agent dials INTO — so unlike the data plane it
# has a public address and a name.
#
# project_id and dns_name are placeholders. Set them before the first run; nothing here invents a
# project, and terragrunt will create this environment's state bucket as PROJECT-tfstate.

locals {
  env_name   = "prod-cp"
  project_id = "gitfrok-prod-cp"      # TODO: set to the real project before first apply
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
  admin_networks = [
    {
      cidr_block   = "0.0.0.0/0"
      display_name = "TODO: set the real operator CIDR — GKE may reject 0.0.0.0/0 outright"
    },
  ]

  dns_name = "gitfrok.example."       # TODO: the real apex, trailing dot included
}
