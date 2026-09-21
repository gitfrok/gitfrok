# Keyless publish identity for the `image-publish` workflow (ADR-0098 decision 5).
#
# ADR-0047 restricts publishing to "protected `image-publish` workflow runs from reviewed `main` or
# a `v*` release tag", and ADR-0098 keeps that rule while changing its credential: GitHub Actions
# federates into GCP with its OIDC token, so there is NO service-account key anywhere. That is not a
# convenience — a downloadable key is a credential that outlives the job that needed it, and
# ADR-0092 decision 6 refuses secrets as inputs for the same reason.
#
# THE SECURITY BOUNDARY IS THE ATTRIBUTE CONDITION BELOW, and nothing else. A pool provider trusting
# GitHub's issuer without one is impersonable by a workflow in any repository on earth: the issuer
# is shared by all of GitHub. Read that condition before changing anything here.

resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = "${var.env_name}-github"
  display_name              = "GitHub Actions (${var.env_name})"
  description               = "Federates the image-publish workflow into GCP with no service-account key (ADR-0098 decision 5)."
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github-oidc"
  display_name                       = "GitHub OIDC"

  attribute_mapping = {
    "google.subject"        = "assertion.sub"
    "attribute.repository"  = "assertion.repository"
    "attribute.ref"         = "assertion.ref"
    "attribute.environment" = "assertion.environment"
  }

  # The boundary. Three independent conditions, all required:
  #   1. the token came from this one repository;
  #   2. the run was executing in the approved GitHub environment — which is where ADR-0047's
  #      reviewer gate and the Cosign secrets already live;
  #   3. the ref is reviewed main or a v* release tag.
  #
  # Dropping any one of them widens this from "our release workflow" to something broader, and the
  # widening is invisible until it is abused.
  attribute_condition = join(" && ", [
    "attribute.repository == \"${var.github_repository}\"",
    "attribute.environment == \"${var.github_environment}\"",
    "(${join(" || ", concat(
      [for r in var.allowed_refs : "attribute.ref == \"${r}\""],
      ["attribute.ref.startsWith(\"${var.allowed_tag_prefix}\")"],
    ))})",
  ])

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# The identity a federated run assumes. It can write to Artifact Registry and do nothing else —
# no cluster access, no Secret Manager, no compute. A publish job that is compromised can publish a
# bad image, which the Cosign signature and the digest pin are there to catch; it cannot reach the
# clusters, the custody service, or the tunnel tokens.
resource "google_service_account" "publisher" {
  project      = var.project_id
  account_id   = "${var.env_name}-image-publisher"
  display_name = "image-publish workflow (keyless, ADR-0098)"
  description  = "Assumed by GitHub Actions through Workload Identity Federation. No key exists for this account."
}

# Only principals matching the provider's attribute condition AND this repository may assume it.
# principalSet scoping is belt to the condition's braces: the condition decides who gets a token,
# this decides whom that token may act as.
resource "google_service_account_iam_member" "federated" {
  service_account_id = google_service_account.publisher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}
