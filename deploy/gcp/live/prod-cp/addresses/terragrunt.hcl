include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//addresses"
}

# project-services first: reserving an address needs the compute API.
dependency "services" {
  config_path                             = "../project-services"
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    enabled_services = []
  }
}

# Both addresses, because prod-cp serves ADR-0095's whole surface. There is deliberately no
# live/prod-dp/addresses: the data plane publishes nothing and reserving an address it cannot use
# would be the first inbound-shaped thing in that environment (ADR-0011).
inputs = {
  gateway    = true
  agent_door = true
}
