variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "env_name" {
  type = string
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "network_name" {
  description = "The VPC the connector sits in. Must be the cluster's own VPC."
  type        = string
}

variable "subnet_name" {
  description = <<-DESC
    The cluster's NODE subnet, and it must be exactly that one. GKE grants the primary range of the
    cluster's subnet access to a private control-plane endpoint by default; a connector in any other
    subnet is refused by the control plane unless its range is added to master authorized networks,
    which ADR-0097 decision 2 exists to avoid maintaining. Putting the connector here is what keeps
    `admin_networks` empty and still working.
  DESC
  type        = string
}

variable "zone" {
  description = "Zone for the connector. Defaults to the region's -a zone; the tunnel is a single-instance path, not an HA one (see outputs)."
  type        = string
  default     = null
}

variable "machine_type" {
  description = "The connector forwards operator traffic and nothing else; it is not a jump host and runs no workload."
  type        = string
  default     = "e2-micro"
}

variable "boot_image" {
  description = "Debian rather than COS because the connector installs a package. Pinned to a family, not a digest — this is a VM, not one of ADR-0035's first-party images."
  type        = string
  default     = "debian-cloud/debian-12"
}

variable "allow_iap_ssh" {
  description = <<-DESC
    Open :22 to IAP's fixed range so an operator with `roles/iap.tunnelResourceAccessor` can reach
    this VM. Without it, ADR-0097 decision 3's break-glass does not exist and
    `gcloud compute ssh --tunnel-through-iap` hangs. Set false only if a different operator path is
    in place, because otherwise a connector whose tunnel is misconfigured cannot be fixed.
  DESC
  type        = bool
  default     = true
}
