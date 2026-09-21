variable "project_id" { type = string }
variable "region" { type = string }
variable "env_name" { type = string }
variable "labels" {
  type    = map(string)
  default = {}
}

variable "repository_id" {
  description = "Repository name. Images are pulled as REGION-docker.pkg.dev/PROJECT/REPO/NAME:TAG."
  type        = string
  default     = "gitfrok"
}

variable "immutable_tags" {
  description = <<-DESC
    Refuse to overwrite an existing tag. ADR-0034 requires pins to be resolvable patch-level tags,
    which is only a guarantee if a tag cannot be moved after the fact.
  DESC
  type        = bool
  default     = true
}

variable "reader_members" {
  description = "IAM members granted read. A public repository (ADR-0047) uses allUsers."
  type        = list(string)
  default     = []
}

variable "writer_members" {
  description = <<-DESC
    Principals permitted to PUSH. ADR-0098 decision 5 expects exactly one: the keyless
    image-publisher service account, assumed by the protected `image-publish` workflow through
    Workload Identity Federation. Anything else here is a second publish path that ADR-0047's
    authority rule does not cover.
  DESC
  type        = list(string)
  default     = []
}
