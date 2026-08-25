variable "project_id" { type = string }
variable "region" { type = string }
variable "env_name" { type = string }
variable "labels" {
  type    = map(string)
  default = {}
}

variable "subnet_cidr" {
  description = "Primary range for nodes."
  type        = string
}

variable "pods_cidr" {
  description = "Secondary range for pods. VPC-native clusters need this to exist before the cluster."
  type        = string
}

variable "services_cidr" {
  description = "Secondary range for ClusterIP services."
  type        = string
}

variable "master_cidr" {
  description = "The /28 for a private cluster's control-plane endpoint. Empty for a public cluster."
  type        = string
  default     = ""
}

variable "enable_nat" {
  description = <<-DESC
    Cloud NAT for egress. Required for a private cluster: the ADR-0011 agent is outbound-only, and
    with no public node IPs it has no route out without NAT.
  DESC
  type        = bool
  default     = false
}
