include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//image-publish-identity"
}

dependency "services" {
  config_path                             = "../project-services"
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    enabled_services = []
  }
}

inputs = {
  # The super-repo, because that is the only tree holding every Dockerfile at once through its
  # submodules — bff/ and webfrontend/ own theirs, backend/ owns three, and an image-publish run
  # needs all of them at one set of pins.
  github_repository = "gitfrok/gitfrok"

  # ADR-0047's authority rule, expressed as the two things GitHub actually asserts. The environment
  # is where that ADR's reviewer gate and the Cosign secrets already live, per the image-publish
  # trust bundle README.
  github_environment = "image-publish"
  allowed_refs       = ["refs/heads/main"]
  allowed_tag_prefix = "refs/tags/v"
}
