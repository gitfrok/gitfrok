include "root" {
  path = find_in_parent_folders("root.hcl")
}

terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//project-services"
}

inputs = {
  services = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    # dns.googleapis.com is gone: ADR-0095 decision 4 made Cloudflare authoritative for
    # 7.solutions and decision 10 retired this tree's dns-zone unit, so the API granted nothing.
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "storage.googleapis.com",
    # The Zero Trust connector's tunnel token lives in Secret Manager (ADR-0097 decision 4).
    "secretmanager.googleapis.com",
  ]
}
