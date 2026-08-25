variable "project_id" { type = string }
variable "region" { type = string }
variable "env_name" { type = string }
variable "labels" {
  type    = map(string)
  default = {}
}

variable "accounts" {
  description = <<-DESC
    One entry per Google service account a workload needs. `ksa` is the Kubernetes service account
    that may impersonate it, as namespace/name — the binding is what makes the seam keyless, and it
    is the only reason these accounts exist. `roles` are project-level roles; keep them at the
    smallest thing that works, because this is the one place in the tree where a cloud IAM grant is
    made and nothing downstream can narrow it.
  DESC
  type = map(object({
    display_name = string
    ksa          = string
    roles        = list(string)
  }))
  default = {}
}
