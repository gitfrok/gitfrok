variable "project_id" {
  description = "GCP project this environment lives in."
  type        = string
}

variable "region" {
  description = "Default region. Unused here, supplied by root.hcl to every unit."
  type        = string
}

variable "env_name" {
  description = "Environment name, e.g. prod-cp."
  type        = string
}

variable "labels" {
  description = "Labels applied to every labellable resource."
  type        = map(string)
  default     = {}
}

variable "services" {
  description = "APIs to enable. Kept explicit per environment: the data plane needs no DNS API."
  type        = list(string)
}
