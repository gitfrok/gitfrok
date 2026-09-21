variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "env_name" {
  description = "Prefixes both address names, so `prod-cp` yields `prod-cp-gateway` and `prod-cp-agent-door` — the exact strings the Kustomize overlay references by name."
  type        = string
}

variable "labels" {
  type    = map(string)
  default = {}
}

variable "gateway" {
  description = "Reserve a GLOBAL address for the ADR-0095 decision 2 Gateway. Global because gke-l7-global-external-managed fronts a global forwarding rule."
  type        = bool
  default     = true
}

variable "agent_door" {
  description = "Reserve a REGIONAL address for the ADR-0095 decision 3 L4 agent door. Regional because a passthrough network load balancer is regional."
  type        = bool
  default     = true
}
