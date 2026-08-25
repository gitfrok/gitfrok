# A public zone for the control-plane surface only. The data plane opens no inbound path (ADR-0011)
# and therefore has no name to publish, which is why this unit exists in live/prod-cp and not in
# live/prod-dp.
#
# The records themselves are not here: they are created by whatever ends up owning ingress, and that
# is an open ADR-0092 follow-up. This module creates the zone and hands back its name servers.

resource "google_dns_managed_zone" "public" {
  project     = var.project_id
  name        = "${var.env_name}-zone"
  dns_name    = var.dns_name
  description = var.description
  visibility  = "public"

  labels = var.labels

  dnssec_config {
    state = "on"
  }
}
