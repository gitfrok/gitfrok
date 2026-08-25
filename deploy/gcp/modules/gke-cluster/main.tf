# One regional GKE cluster. Both environments instantiate this same module; what differs is whether
# the API endpoint is private and whether a sandboxed runner pool exists (ADR-0092 decision 2).
#
# Nothing in this module creates a Kubernetes object. The cluster is the boundary: what runs inside
# it is ADR-0013's chart and Operator, not OpenTofu.

locals {
  # Workload Identity's fixed pool name for a project. Pods assume Google service accounts through
  # this rather than through a mounted key — the keyless seam ADR-0010 §3 names.
  workload_pool = "${var.project_id}.svc.id.goog"
}

resource "google_container_cluster" "this" {
  name     = "${var.env_name}-gke"
  project  = var.project_id
  location = var.region

  # A regional cluster spreads the managed control plane across zones. The node count below is
  # per-zone as a result.
  network    = var.network_name
  subnetwork = var.subnet_name

  # Terragrunt destroy of a production cluster should take a deliberate flip of this, not a typo.
  deletion_protection = true

  # The default pool is unmanageable in isolation; both real pools are declared as their own
  # resources so their shape is diffable.
  remove_default_node_pool = true
  initial_node_count       = 1

  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  private_cluster_config {
    enable_private_nodes    = var.private_nodes
    enable_private_endpoint = var.private_endpoint
    master_ipv4_cidr_block  = var.master_cidr
  }

  # On the data plane this list is empty, which — with private_endpoint = true — means the API is
  # reachable only from inside the VPC. That is ADR-0011's "no inbound path" made structural.
  dynamic "master_authorized_networks_config" {
    for_each = length(var.master_authorized_networks) > 0 ? [1] : []

    content {
      dynamic "cidr_blocks" {
        for_each = var.master_authorized_networks

        content {
          cidr_block   = cidr_blocks.value.cidr_block
          display_name = cidr_blocks.value.display_name
        }
      }
    }
  }

  workload_identity_config {
    workload_pool = local.workload_pool
  }

  release_channel {
    channel = var.release_channel
  }

  addons_config {
    # The CSI driver is what makes a pd-ssd PVC possible, which ADR-0033 requires for live repos.
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }

    # No GCP L7 load balancer: ingress is a workload-layer decision and an open ADR-0092 follow-up.
    http_load_balancing {
      disabled = true
    }

    horizontal_pod_autoscaling {
      disabled = false
    }
  }

  # Shielded nodes: secure boot and integrity monitoring, no reason not to.
  enable_shielded_nodes = true

  resource_labels = var.labels

  lifecycle {
    # The cluster's own node_config is the removed default pool's. Ignore it so a provider default
    # change never proposes recreating the cluster.
    ignore_changes = [node_config]
  }
}

resource "google_container_node_pool" "system" {
  name     = "system"
  project  = var.project_id
  location = var.region
  cluster  = google_container_cluster.this.name

  # Per zone. A regional cluster multiplies this by the zones it covers.
  initial_node_count = var.system_pool.min_nodes

  autoscaling {
    min_node_count = var.system_pool.min_nodes
    max_node_count = var.system_pool.max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.system_pool.machine_type
    disk_size_gb = var.system_pool.disk_size_gb
    disk_type    = var.system_pool.disk_type
    image_type   = "COS_CONTAINERD"

    # No key files anywhere: pods reach Google APIs through Workload Identity.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = merge(var.labels, { "gitfrok.io/pool" = "system" })
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

# The CI pool. gVisor is the RuntimeClass boundary ADR-0012 chose, and GKE Sandbox is how GKE
# provides it — the taint is what keeps everything else off these nodes.
resource "google_container_node_pool" "runners" {
  count = var.runner_pool == null ? 0 : 1

  provider = google-beta

  name     = "runners"
  project  = var.project_id
  location = var.region
  cluster  = google_container_cluster.this.name

  initial_node_count = var.runner_pool.min_nodes

  autoscaling {
    min_node_count = var.runner_pool.min_nodes
    max_node_count = var.runner_pool.max_nodes
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  node_config {
    machine_type = var.runner_pool.machine_type
    disk_size_gb = var.runner_pool.disk_size_gb
    disk_type    = var.runner_pool.disk_type

    # GKE Sandbox requires the containerd variant of Container-Optimized OS.
    image_type = "COS_CONTAINERD"

    sandbox_config {
      sandbox_type = "gvisor"
    }

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    labels = merge(var.labels, { "gitfrok.io/pool" = "runners" })

    taint {
      key    = "gitfrok.io/runners"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }

  lifecycle {
    ignore_changes = [initial_node_count]
  }
}
