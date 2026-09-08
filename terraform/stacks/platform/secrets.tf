# The secrets. Terraform owns the CONTAINER, never the value: a version written
# from here would live forever in the state file, which is a bucket a reader of
# this repository can be given access to. The values are put in by hand, or by
# the owner steps in docs/qa-bootstrap-owner-steps.md.
locals {
  secrets = [
    "dop-database-url",      # the core's connection string
    "dop-postgres-password", # read at boot by the data VM
    "dop-call-auth-key-bff", # ADR-0029: the key the BFF signs its assertions with
    "dop-call-auth-key-collector",
    "dop-project-repo-key", # ADR-0028: the project-knowledge git server
    "dop-project-repo-admin-key",
  ]
}

resource "google_secret_manager_secret" "this" {
  for_each = toset(local.secrets)

  project   = var.project
  secret_id = each.value

  replication {
    auto {}
  }
}

# ── A known violation, codified as it IS and not as it should be ─────────────
#
# These three grants are PROJECT-WIDE: each account can read EVERY secret in the
# project. For dop-api that breaks invariant 2 — "the BFF has no database and no
# secret" — because dop-database-url is in reach of an account that must never
# hold a credential to the database.
#
# It is written here unchanged on purpose. This file's first job is to describe
# the environment that exists, so that `terraform plan` is a no-op and the code
# can be trusted. Replacing these with per-secret bindings is a CHANGE to a live
# environment, and it belongs in its own commit, applied when the end-to-end
# smoke test can prove nothing lost access. See docs/qa-secret-scoping.md.
resource "google_project_iam_member" "secret_accessor" {
  for_each = toset(local.workload_sa_emails)

  project = var.project
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${each.value}"
}
