include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//zt-connector"
}

# project-services first: the module creates a Secret Manager secret, and that API is enabled there.
dependency "services" {
  config_path                             = "../project-services"
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    enabled_services = []
  }
}

dependency "network" {
  config_path                             = "../network"
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    network_name = "mock-vpc"
    subnet_name  = "mock-subnet"
  }
}

inputs = {
  network_name = dependency.network.outputs.network_name

  # The cluster's OWN node subnet, deliberately. GKE grants the primary range of that subnet access
  # to a private control-plane endpoint by default, so a connector here reaches the API with
  # `admin_networks` empty — which is the list ADR-0097 decision 2 exists so that nobody maintains.
  # Move this connector to any other subnet and the control plane refuses it, silently, with a
  # timeout rather than an error that names the cause.
  subnet_name = dependency.network.outputs.subnet_name
}
