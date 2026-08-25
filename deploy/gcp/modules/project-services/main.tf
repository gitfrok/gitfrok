# The APIs an environment is allowed to use, stated rather than discovered.
#
# disable_on_destroy is false on purpose: tearing down a cluster must not disable the container API
# out from under anything else in the project.

resource "google_project_service" "enabled" {
  for_each = toset(var.services)

  project = var.project_id
  service = each.value

  disable_on_destroy         = false
  disable_dependent_services = false
}
