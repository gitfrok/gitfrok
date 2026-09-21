output "gateway_address" {
  description = "The reserved global IP. The Cloudflare A record for app-gitfrok and auth-gitfrok points here — those two may be proxied (ADR-0095)."
  value       = try(google_compute_global_address.gateway[0].address, null)
}

output "gateway_address_name" {
  description = "The name the overlay's `networking.gke.io/addresses` annotation must carry."
  value       = try(google_compute_global_address.gateway[0].name, null)
}

output "agent_door_address" {
  description = "The reserved regional IP. The Cloudflare A record for agents-gitfrok points here and must stay DNS-ONLY — proxying it terminates TLS and breaks every enrolment (ADR-0095 decision 5)."
  value       = try(google_compute_address.agent_door[0].address, null)
}

output "agent_door_address_name" {
  description = "The name the overlay's `networking.gke.io/load-balancer-ip-addresses` annotation must carry."
  value       = try(google_compute_address.agent_door[0].name, null)
}

output "dns_records" {
  description = <<-DESC
    The three records to create in the Cloudflare `7.solutions` zone, operator-side (ADR-0095
    decision 4 — this tree provisions no DNS). The proxy column is not advice: agents-gitfrok
    proxied is an outage, not a degradation.
  DESC
  value = {
    "app-gitfrok"    = { value = try(google_compute_global_address.gateway[0].address, null), proxy = "optional" }
    "auth-gitfrok"   = { value = try(google_compute_global_address.gateway[0].address, null), proxy = "optional" }
    "agents-gitfrok" = { value = try(google_compute_address.agent_door[0].address, null), proxy = "NEVER — DNS-only" }
  }
}
