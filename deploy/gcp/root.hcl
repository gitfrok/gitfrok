# Terragrunt root configuration — ADR-0092.
#
# Every unit under live/ includes this file. It supplies the three things a unit must never
# hand-write: the state backend, the provider block, and the version constraints. A unit is
# therefore only ever `terraform { source = ... }` plus its own inputs.
#
# The boundary this file sits inside (ADR-0092 decision 4): OpenTofu provisions infrastructure and
# never a Kubernetes object. No kubernetes or helm provider is generated here, deliberately — the
# workload layer belongs to ADR-0013's chart and Operator.

locals {
  env = read_terragrunt_config(find_in_parent_folders("env.hcl")).locals
}

# Pinned per ADR-0092 decision 3. These are enforced by terragrunt itself, which means
# check-version-floors.sh does not see them — recorded as an ADR-0092 follow-up.
terraform_version_constraint   = ">= 1.12.6, < 2.0.0"
terragrunt_version_constraint  = ">= 1.1.3, < 2.0.0"

# Terragrunt creates this bucket on first run if it is absent, with versioning enabled, so there is
# no chicken-and-egg bootstrap unit. State is per-environment and never committed.
remote_state {
  backend = "gcs"

  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }

  config = {
    project  = local.env.project_id
    location = local.env.region
    bucket   = "${local.env.project_id}-tfstate"
    # The GCS backend appends /<workspace>.tfstate itself, so the prefix must not carry a suffix.
    prefix   = path_relative_to_include()

    gcs_bucket_labels = local.env.labels
    skip_bucket_versioning = false
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<PROVIDER
provider "google" {
  project = "${local.env.project_id}"
  region  = "${local.env.region}"
}

provider "google-beta" {
  project = "${local.env.project_id}"
  region  = "${local.env.region}"
}
PROVIDER
}

# Inputs every unit gets for free. A unit's own inputs are merged over these.
inputs = {
  project_id = local.env.project_id
  region     = local.env.region
  env_name   = local.env.env_name
  labels     = local.env.labels
}
