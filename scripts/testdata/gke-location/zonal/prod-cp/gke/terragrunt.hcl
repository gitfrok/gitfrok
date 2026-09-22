# AC2 fixture: an explicit ZONE. Accepted.
terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//gke-cluster"
}
inputs = {
  private_endpoint = true
  location         = "asia-southeast1-a"
  system_pool = {
    machine_type = "e2-standard-4"
    min_nodes    = 2
  }
}
