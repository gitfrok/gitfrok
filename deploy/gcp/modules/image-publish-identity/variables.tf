variable "project_id" {
  type = string
}

variable "env_name" {
  type = string
}

variable "github_repository" {
  description = <<-DESC
    The `owner/repo` allowed to impersonate the publisher, e.g. `gitfrok/gitfrok`. NO DEFAULT, and
    that is deliberate: an Workload Identity Pool provider without an attribute condition naming a
    repository can be impersonated by a workflow in ANY GitHub repository on earth. This value and
    `github_environment` are the whole security boundary of keyless publishing.
  DESC
  type        = string
}

variable "github_environment" {
  description = <<-DESC
    The GitHub Actions *environment* a run must be executing in. ADR-0047 restricts publishing to
    approved `image-publish` deployments, and the image-publish trust bundle's README records that
    COSIGN_PRIVATE_KEY and COSIGN_PASSWORD are environment secrets of that same environment. Binding
    on the environment therefore matches the control that already exists, and it is stronger than a
    branch condition: a branch can be pushed, while an environment can require reviewers.
  DESC
  type        = string
  default     = "image-publish"
}

variable "allowed_refs" {
  description = <<-DESC
    Git refs permitted to publish, as full ref names. ADR-0047: reviewed `main` or a `v*` release
    tag, and nothing else. Wildcards are not supported by CEL string equality, so `v*` tags are
    matched by prefix below.
  DESC
  type        = list(string)
  default     = ["refs/heads/main"]
}

variable "allowed_tag_prefix" {
  description = "Tag refs beginning with this prefix may publish (ADR-0047's `v*` release tags)."
  type        = string
  default     = "refs/tags/v"
}
