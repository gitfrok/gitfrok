# The keyless pod-to-cloud seam. ADR-0010 §3 lists Workload Identity as GKE's side of a
# three-cloud abstraction (IRSA on EKS, Entra Workload ID on AKS); this module is that side and
# nothing more. No service account key is ever created, and there is no code path here that could
# create one.

locals {
  # Flatten accounts x roles so each grant is its own resource and a removed role is a real diff.
  role_grants = merge([
    for key, account in var.accounts : {
      for role in account.roles : "${key}:${role}" => {
        account = key
        role    = role
      }
    }
  ]...)
}

resource "google_service_account" "this" {
  for_each = var.accounts

  project      = var.project_id
  account_id   = "${var.env_name}-${each.key}"
  display_name = each.value.display_name
}

resource "google_project_iam_member" "grants" {
  for_each = local.role_grants

  project = var.project_id
  role    = each.value.role
  member  = "serviceAccount:${google_service_account.this[each.value.account].email}"
}

# The binding itself: this Kubernetes service account, in this cluster's identity pool, may act as
# that Google service account. Annotating the KSA is the other half, and it belongs to the workload
# layer (ADR-0092 decision 4) — see the annotation output below.
resource "google_service_account_iam_member" "workload_identity" {
  for_each = var.accounts

  service_account_id = google_service_account.this[each.key].name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${each.value.ksa}]"
}
