# The two reserved external addresses ADR-0095 decision 6 requires, and the reason it requires them.
#
# GKE hands a Gateway an ephemeral global address and a `type=LoadBalancer` Service an ephemeral
# regional one. ADR-0095 decision 4 put three DNS records in a Cloudflare zone by hand, so an
# address that moves silently invalidates a record nobody will re-check — and for
# `agents-gitfrok.7.solutions` that breaks every enrolment, since the agent resolves a name to reach
# a door whose TLS it pins (ADR-0017). An ephemeral address is therefore not a smaller version of
# this unit; it is the defect this unit exists to prevent.
#
# These are addresses, not workloads, so ADR-0092 decision 4 puts them here rather than in the
# installer. Nothing in this file creates a Kubernetes object; the overlay REFERENCES these by name
# (`networking.gke.io/addresses`, `networking.gke.io/load-balancer-ip-addresses`) and GKE resolves
# the name at programming time.
#
# Instantiated for the control plane only, the way `artifact-registry` is.
#
# THIS USED TO SAY `prod-dp` "reserves nothing, publishes nothing, and has no inbound path at all
# (ADR-0011)". Since 2026-09-23 that is false of the environment: ADR-0107 publishes the data plane's
# Git door and ADR-0108 names it `gitfrok.7.solutions`. Its address, `prod-dp-git-gateway`, was
# created BY HAND with gcloud and is not managed by this module or any other unit — a gap against
# ADR-0092 that governance T-0092 records. ADR-0011 governs the management channel, which stays
# inbound-closed; it never said anything about the tenant Git protocol.

resource "google_compute_global_address" "gateway" {
  count = var.gateway ? 1 : 0

  name         = "${var.env_name}-gateway"
  project      = var.project_id
  description  = "ADR-0095 decision 2: the Gateway serving app-gitfrok and auth-gitfrok. Referenced by name from deploy/k8s/controlplane/overlays/${var.env_name}."
  address_type = "EXTERNAL"
  labels       = var.labels
}

resource "google_compute_address" "agent_door" {
  count = var.agent_door ? 1 : 0

  name    = "${var.env_name}-agent-door"
  project = var.project_id
  region  = var.region
  # ADR-0095 decisions 3-5: the L4 passthrough door. Its DNS record must stay DNS-only in
  # Cloudflare, because a proxy that terminates TLS is untrusted by every agent — so this address is
  # the one a public record points at directly, and it must not move.
  description  = "ADR-0095 decision 3: the agent door (agents-gitfrok). L4 passthrough, CA-pinned, never proxied."
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  labels       = var.labels
}
