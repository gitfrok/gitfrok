# The Cloudflare Zero Trust connector (ADR-0097 decisions 2-4).
#
# Why this is a VM and not a Deployment, since the Deployment is the idiomatic Cloudflare pattern:
# reaching a PRIVATE Kubernetes API to install the workload that provides access to that API requires
# the access it has not yet provided. An in-cluster connector is unbootstrappable here. It would also
# be a Kubernetes object, which ADR-0092 decision 4 forbids OpenTofu from creating and ADR-0096
# decision 4 keeps out of the installer — so it would have no owner at all.
#
# What this module does NOT do: it opens no inbound path. Every connection is outbound from the
# instance to Cloudflare's edge, which is why the instance has no external IP and no firewall rule
# is created. ADR-0011 is untouched.

locals {
  zone = coalesce(var.zone, "${var.region}-a")
  name = "${var.env_name}-zt-connector"
}

resource "google_service_account" "connector" {
  project      = var.project_id
  account_id   = "${var.env_name}-zt-connector"
  display_name = "Cloudflare Zero Trust connector (${var.env_name})"
}

# The token's container. Its VALUE is added out of band by an operator (ADR-0092 decision 6: no
# secret is ever an OpenTofu input), so there is deliberately no google_secret_manager_secret_version
# resource here and there never should be — adding one would put the token in state.
resource "google_secret_manager_secret" "tunnel_token" {
  project   = var.project_id
  secret_id = "${var.env_name}-cloudflare-tunnel-token"
  labels    = var.labels

  replication {
    auto {}
  }
}

# The connector may read that one secret. Not a project-level role: this is the only Google API the
# instance needs, and scoping it to the single secret is the difference between a compromised
# connector reading its own token and reading everything the project holds.
resource "google_secret_manager_secret_iam_member" "connector_reads_token" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.tunnel_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.connector.email}"
}

resource "google_compute_instance" "connector" {
  project      = var.project_id
  name         = local.name
  machine_type = var.machine_type
  zone         = local.zone
  labels       = var.labels

  boot_disk {
    initialize_params {
      image = var.boot_image
      size  = 10
      type  = "pd-standard"
    }
  }

  network_interface {
    network    = var.network_name
    subnetwork = var.subnet_name
    # No access_config block: no external IP. Egress to Cloudflare goes through the Cloud NAT the
    # network unit already provisions, and Secret Manager is reached over Private Google Access.
  }

  service_account {
    email = google_service_account.connector.email
    # cloud-platform is scoped down by the IAM grant above, which is the single-secret accessor and
    # nothing else. Scopes are the coarse filter; IAM is the real one.
    scopes = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_integrity_monitoring = true
  }

  # Deleting this instance costs an operator path and no data, so it does not carry the cluster's
  # deletion protection. Recreate it and re-run the manual seam.
  allow_stopping_for_update = true

  metadata = {
    # Blocks project-wide SSH keys. Console/IAP SSH still works for an operator with the IAM role,
    # which is the break-glass into the box itself rather than into the cluster.
    block-project-ssh-keys = "TRUE"
  }

  metadata_startup_script = <<-SCRIPT
    #!/bin/bash
    # Installs cloudflared and starts it against the tunnel token held in Secret Manager.
    #
    # Runs on every boot. It is idempotent, and an ABSENT token is an expected state rather than a
    # failure: on a first apply the secret has no version, because ADR-0097 decision 4 keeps the
    # value out of OpenTofu. In that case this logs and exits 0, leaving a healthy instance with no
    # tunnel. Re-run after adding the version.
    set -euo pipefail

    log() { echo "[zt-connector] $$*" | systemd-cat -t zt-connector -p info; echo "[zt-connector] $$*"; }

    if ! command -v cloudflared >/dev/null 2>&1; then
      log "installing cloudflared from pkg.cloudflare.com"
      install -d -m 0755 /usr/share/keyrings
      curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        -o /usr/share/keyrings/cloudflare-main.gpg
      echo "deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared bookworm main" \
        > /etc/apt/sources.list.d/cloudflared.list
      apt-get update -qq
      apt-get install -y -qq cloudflared
    fi

    # Read the token through the metadata server rather than gcloud, which a Debian GCE image does
    # not reliably carry. Private Google Access covers the API call with no external IP.
    ACCESS_TOKEN=$$(curl -s -H "Metadata-Flavor: Google" \
      "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
      | python3 -c 'import sys,json; print(json.load(sys.stdin)["access_token"])')

    SECRET_JSON=$$(curl -s -H "Authorization: Bearer $$ACCESS_TOKEN" \
      "https://secretmanager.googleapis.com/v1/projects/${var.project_id}/secrets/${google_secret_manager_secret.tunnel_token.secret_id}/versions/latest:access" || true)

    TUNNEL_TOKEN=$$(printf '%s' "$$SECRET_JSON" | python3 -c '
    import sys, json, base64
    try:
        d = json.load(sys.stdin)
    except Exception:
        sys.exit(0)
    data = (d.get("payload") or {}).get("data")
    if not data:
        sys.exit(0)
    sys.stdout.write(base64.b64decode(data).decode().strip())
    ' || true)

    if [ -z "$${TUNNEL_TOKEN:-}" ]; then
      log "tunnel token secret has no version yet — ADR-0097 decision 4's manual seam is unfinished."
      log "add the version, then reset this instance. The cluster API stays unreachable until then."
      exit 0
    fi

    log "installing the cloudflared service"
    cloudflared service uninstall >/dev/null 2>&1 || true
    cloudflared service install "$$TUNNEL_TOKEN"
    systemctl enable --now cloudflared
    log "cloudflared running"
  SCRIPT
}
