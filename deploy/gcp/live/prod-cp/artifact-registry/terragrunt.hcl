include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//artifact-registry"
}

dependency "services" {
  config_path                             = "../project-services"
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    enabled_services = []
  }
}

inputs = {
  repository_id = "gitfrok"

  # ADR-0034 wants pins that resolve to one thing forever.
  immutable_tags = true

  # A data-plane cluster in another project pulls from here, and ADR-0047 already makes first-party
  # release images publicly pullable with trust verified offline. Left empty deliberately: opening
  # this to allUsers is a decision ADR-0047 permits but this unit should not make silently.
  reader_members = []
}
