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

variable "writer_members" {
  description = <<-DESC
    Principals permitted to write backups — in practice the one Google service account CloudNativePG
    assumes through Workload Identity. Keyless, like every other identity in this tree.
  DESC
  type        = list(string)
  default     = []
}

variable "retention_days" {
  description = <<-DESC
    How long a backup object survives. ADR-0099 decision 5 made backups exist and leave the cluster;
    it deliberately did NOT set retention or the PITR window, which is an open register row. 30 is a
    starting value, not an answer — the answer needs a recovery objective nobody has stated.
  DESC
  type        = number
  default     = 30
}
