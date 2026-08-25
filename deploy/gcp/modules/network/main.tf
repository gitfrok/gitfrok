# One VPC per environment, VPC-native (alias IPs), with the pod and service ranges declared here
# rather than auto-allocated — a cluster's ranges are a residency-visible fact (G7), not an accident.

resource "google_compute_network" "vpc" {
  name                    = "${var.env_name}-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
  routing_mode            = "REGIONAL"
}

resource "google_compute_subnetwork" "nodes" {
  name          = "${var.env_name}-nodes"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = var.subnet_cidr

  # Private Google Access lets private nodes reach Artifact Registry without a public IP.
  private_ip_google_access = true

  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = var.pods_cidr
  }

  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = var.services_cidr
  }
}

resource "google_compute_router" "router" {
  count = var.enable_nat ? 1 : 0

  name    = "${var.env_name}-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.vpc.id
}

resource "google_compute_router_nat" "nat" {
  count = var.enable_nat ? 1 : 0

  name    = "${var.env_name}-nat"
  project = var.project_id
  region  = var.region
  router  = google_compute_router.router[0].name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}
