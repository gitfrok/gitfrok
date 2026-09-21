include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//project-services"
}

inputs = {
  # No dns.googleapis.com and no artifactregistry repository of its own: this plane publishes no
  # name and hosts no registry. It reads the control plane's.
  services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "storage.googleapis.com",
    # The Zero Trust connector's tunnel token lives in Secret Manager (ADR-0097 decision 4). The
    # data plane gets a connector too (decision 6): its endpoint was always private, so without one
    # the reference deployment could not be administered at all.
    "secretmanager.googleapis.com",
  ]
}
