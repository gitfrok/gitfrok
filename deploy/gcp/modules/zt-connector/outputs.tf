output "instance_name" {
  value = google_compute_instance.connector.name
}

output "service_account_email" {
  value = google_service_account.connector.email
}

output "tunnel_token_secret_id" {
  description = "The Secret Manager secret the connector reads its tunnel token from. OpenTofu creates the container and never the value — ADR-0092 decision 6."
  value       = google_secret_manager_secret.tunnel_token.secret_id
}

output "manual_seam" {
  description = <<-DESC
    ADR-0097 decision 4's manual seam, spelled out because an unwritten one becomes an improvised one.
    Until the token version exists the connector boots, logs that the secret is empty, and exits 0 —
    the cluster's API stays unreachable and nothing looks broken.
  DESC
  value       = <<-DESC
    1. Create the tunnel in Cloudflare Zero Trust (Networks > Tunnels) and copy its token.
    2. echo -n '<token>' | gcloud secrets versions add ${google_secret_manager_secret.tunnel_token.secret_id} --project=${var.project_id} --data-file=-
    3. gcloud compute instances reset ${google_compute_instance.connector.name} --zone=${local.zone} --project=${var.project_id}
    4. In Cloudflare, add a private-network route for the cluster's control-plane CIDR through this
       tunnel, and an Access policy naming who may use it.
    5. Verify from an enrolled WARP client: `kubectl cluster-info` against the private endpoint.
    The token is never an OpenTofu input and never appears in state.
  DESC
}
