variable "project_id" { type = string }
variable "region" { type = string }
variable "env_name" { type = string }
variable "labels" {
  type    = map(string)
  default = {}
}

variable "dns_name" {
  description = "The zone's apex, trailing dot included, e.g. gitfrok.example."
  type        = string
}

variable "description" {
  type    = string
  default = "gitfrok public zone"
}
