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

dependency "publisher" {
  config_path                             = "../image-publish-identity"
  mock_outputs_allowed_terraform_commands = ["validate", "plan"]
  mock_outputs = {
    service_account_email = "mock-publisher@example.iam.gserviceaccount.com"
  }
}

inputs = {
  repository_id = "gitfrok"

  # ADR-0034 wants pins that resolve to one thing forever.
  immutable_tags = true

  # PUBLIC READ, AND IT IS A DECISION RATHER THAN AN OVERSIGHT (ADR-0098 decision 2).
  #
  # ADR-0047 requires first-party release images to be publicly pullable, because a BYO customer
  # pulls them into a cluster we do not administer and that ADR forbids a pull credential in operator
  # manifests. GHCR packages are public by a visibility flag; Artifact Registry repositories are
  # PRIVATE by default, so preserving the property takes this line.
  #
  # allUsers gets `roles/artifactregistry.reader` and nothing else. ADR-0047's sentence stands:
  # public visibility does not authorize execution, bypass the PDP, or permit a release request to
  # supply its own key or signature. Every consumer still resolves a digest and verifies a Cosign
  # signature against the versioned trust bundle before applying anything.
  #
  # This is also the line that removes the cross-project seam the README documented: prod-dp no
  # longer needs a named reader grant, because it is covered by the same public read a customer uses.
  reader_members = ["allUsers"]

  # Exactly one writer, and no key exists for it (ADR-0098 decision 5).
  writer_members = ["serviceAccount:${dependency.publisher.outputs.service_account_email}"]
}
