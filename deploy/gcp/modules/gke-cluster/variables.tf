variable "project_id" { type = string }
variable "region" { type = string }
variable "env_name" { type = string }
variable "labels" {
  type    = map(string)
  default = {}
}

variable "network_name" { type = string }
variable "subnet_name" { type = string }
variable "pods_range_name" { type = string }
variable "services_range_name" { type = string }

variable "release_channel" {
  description = "REGULAR keeps the version moving without pinning us to a version string in HCL."
  type        = string
  default     = "REGULAR"
}

variable "private_nodes" {
  description = "Nodes get no public IP. True everywhere; egress is via Cloud NAT."
  type        = bool
  default     = true
}

variable "private_endpoint" {
  description = <<-DESC
    True hides the Kubernetes API endpoint from the internet entirely — correct for the data plane
    (ADR-0011: no inbound path). The control plane keeps a public endpoint restricted by
    master_authorized_networks, because it is the side agents dial into.
  DESC
  type        = bool
}

variable "master_cidr" {
  description = "The /28 the managed control-plane endpoint occupies."
  type        = string
}

variable "master_authorized_networks" {
  description = "CIDRs allowed to reach the Kubernetes API. Empty list means nothing outside the VPC."
  type = list(object({
    cidr_block   = string
    display_name = string
  }))
  default = []
}

variable "system_pool" {
  description = "The pool everything that is not a CI job runs on."
  type = object({
    machine_type = string
    min_nodes    = number
    max_nodes    = number
    disk_size_gb = number
    disk_type    = string
  })
  default = {
    machine_type = "n2-standard-4"
    min_nodes    = 1
    max_nodes    = 5
    # pd-ssd because the git tier keeps live bare repos on block volumes (ADR-0033) and git's
    # rename contract is latency-sensitive.
    disk_size_gb = 200
    disk_type    = "pd-ssd"
  }
}

variable "runner_pool" {
  description = <<-DESC
    The gVisor-sandboxed pool for CI jobs (ADR-0012). Null on the control-plane cluster, which runs
    no untrusted build code. GKE Sandbox requires COS_CONTAINERD and refuses shared-core machine
    types, so the machine type is not a free choice.
  DESC
  type = object({
    machine_type = string
    min_nodes    = number
    max_nodes    = number
    disk_size_gb = number
    disk_type    = string
  })
  default = null
}
