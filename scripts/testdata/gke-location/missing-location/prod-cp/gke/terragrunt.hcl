# AC1 fixture: no `location` anywhere. Valid HCL, plans clean, and applies into a REGIONAL
# cluster whose node pools create min_nodes nodes PER ZONE. Nothing fails; the bill arrives later.
terraform {
  source = "${get_repo_root()}/deploy/gcp/modules//gke-cluster"
}
inputs = {
  private_endpoint = true
  system_pool = {
    machine_type = "e2-standard-4"
    min_nodes    = 2
    max_nodes    = 4
    disk_size_gb = 100
    disk_type    = "pd-balanced"
  }
}
