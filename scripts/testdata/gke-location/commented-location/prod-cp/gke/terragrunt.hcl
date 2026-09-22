# AC3 fixture: the line is VISIBLY THERE, so a human reading a diff sees no removal — while the
# parsed input is absent. This is the exact shape ADR-0106's consequence describes.
terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//gke-cluster"
}
inputs = {
  private_endpoint = true
  # location = "asia-southeast1-a"
  system_pool = {
    machine_type = "e2-standard-4"
    min_nodes    = 2
  }
}
