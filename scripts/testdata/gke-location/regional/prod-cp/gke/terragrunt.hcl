# AC2 fixture, and the load-bearing one. An explicit REGION is equally a decision, so it is
# ACCEPTED. A gate that greps for the shipped zone passes every other case in this suite and
# refuses ADR-0106 decision 2's own reversal path — restoring regional when an availability
# requirement is finally stated. This fixture is what makes that implementation impossible.
terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//gke-cluster"
}
inputs = {
  private_endpoint = true
  location         = "asia-southeast1"
  system_pool = {
    machine_type = "e2-standard-4"
    min_nodes    = 2
  }
}
