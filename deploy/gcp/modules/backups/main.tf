# Postgres backup storage (ADR-0099 decision 5) — the one place this tree spends ADR-0092 decision 5.
#
# That decision refused "no Cloud SQL, no Memorystore, no Pub/Sub, no GCS bucket FOR BLOBS", and its
# own negative accepted the obligation this discharges: "backups, upgrades, failover drills and
# page-able storage are now ours in production". A backup bucket is not a blob bucket — SeaweedFS
# still serves those — and there is no in-cluster backup target that survives the cluster, which is
# the whole point of a backup.
#
# One bucket per plane, in that plane's own project. A shared target would be a path between the two
# planes, and ADR-0092 decision 2 exists so that there is none.

resource "google_storage_bucket" "postgres_backups" {
  name     = "${var.project_id}-postgres-backups"
  project  = var.project_id
  location = var.region
  labels   = var.labels

  # Backups are the last line; a deletion here should take a deliberate flip, not a typo.
  force_destroy = false

  uniform_bucket_level_access = true

  # No public access, ever. This is the inverse of the Artifact Registry decision (ADR-0098): that
  # repository is public because customers must pull from it, and these objects are a full copy of
  # the product's data.
  public_access_prevention = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = var.retention_days
    }
    action {
      type = "Delete"
    }
  }

  # A non-current version outliving the retention window would make the lifecycle rule above a
  # suggestion rather than a bound.
  lifecycle_rule {
    condition {
      days_since_noncurrent_time = var.retention_days
    }
    action {
      type = "Delete"
    }
  }
}

# Object admin rather than creator: barman-cloud lists and prunes as well as writes, and a
# write-only grant produces a backup chain that grows without bound.
resource "google_storage_bucket_iam_member" "writers" {
  for_each = toset(var.writer_members)

  bucket = google_storage_bucket.postgres_backups.name
  role   = "roles/storage.objectAdmin"
  member = each.value
}
