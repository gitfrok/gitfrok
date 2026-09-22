# AC1 fixture: `location` appears, but nested inside system_pool rather than as an input to the
# module. A depth-blind text match would accept this and the cluster would still be regional.
terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//gke-cluster"
}
inputs = {
  private_endpoint = true
  system_pool = {
    location     = "asia-southeast1-a"
    machine_type = "e2-standard-4"
    min_nodes    = 2
  }
}
