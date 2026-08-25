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
