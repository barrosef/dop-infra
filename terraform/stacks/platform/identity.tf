# One service account per workload.
#
# This is the POC's most expensive finding. Deployed the obvious way, both
# services run as the project's DEFAULT compute account, which holds
# roles/run.admin — and run.admin contains run.invoker. The BFF could then call
# the core not because it was allowed to call THAT service, but because it was
# allowed to invoke EVERYTHING. The IAM boundary reads as drawn and is open in
# practice, which is exactly the failure ADR-0029 was written about.
locals {
  workload_sa_ids = ["dop-core-sa", "dop-api-sa", "dop-vm"]
  # Deterministic from the project id, so import blocks can name them without
  # depending on a resource that does not exist yet.
  workload_sa_emails = [for id in local.workload_sa_ids : "${id}@${var.project}.iam.gserviceaccount.com"]
}

resource "google_service_account" "core" {
  project      = var.project
  account_id   = "dop-core-sa"
  display_name = "dop-core (Cloud Run)"
}

resource "google_service_account" "api" {
  project      = var.project
  account_id   = "dop-api-sa"
  display_name = "dop-api / BFF (Cloud Run)"
}

resource "google_service_account" "vm" {
  project      = var.project
  account_id   = "dop-vm"
  display_name = "dop-data (Postgres, NATS, worker)"
}

# The one grant that makes the private core reachable, and only by the BFF.
# Scoped to THIS service: a project-level run.invoker would let anything in the
# project call it and would put us back where the POC started.
resource "google_cloud_run_v2_service_iam_member" "api_invokes_core" {
  project  = var.project
  location = var.region
  name     = google_cloud_run_v2_service.core.name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${google_service_account.api.email}"
}

# The VM pulls its images from our registry with its own identity. Reader, not
# writer: nothing on that machine has any business publishing an image.
resource "google_project_iam_member" "vm_reads_registry" {
  project = var.project
  role    = "roles/artifactregistry.reader"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

resource "google_project_iam_member" "vm_writes_logs" {
  project = var.project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.vm.email}"
}

// Minting the verification link (spec SP-0 D-7).
//
// A CUSTOM role with one permission, not a predefined one with sixteen.
//
// The predefined shapes were all wrong in the same direction. Firebase
// Authentication and Identity Platform are ONE service — same API
// (identitytoolkit.googleapis.com), same permission namespace `firebaseauth.*`;
// only the role names differ. So `identityplatform.admin` is not the "modern"
// alternative to `firebaseauth.admin`, it is the same eleven permissions plus
// seven for managing tenants: BROADER, not narrower. And `firebaseauth.admin`
// carries `users.delete`, `users.create` and `configs.getSecret` to buy the one
// call the BFF actually makes.
//
// What that call needs is `firebaseauth.users.sendEmail` — asking Identity
// Platform to mint an action link. One permission. A compromise of the public
// edge then buys the ability to send verification mail, not the ability to
// delete every account in the project.
//
// This still belongs in the core rather than at the edge, for the reasons in
// docs/qa-verification-link-privilege.md. The custom role makes that migration
// less urgent; it does not make it unnecessary.
resource "google_project_iam_custom_role" "action_link_minter" {
  project     = var.project
  role_id     = "dopActionLinkMinter"
  title       = "DOP — mint identity action links"
  description = "Generate verification and password-reset links without sending them. One permission, on purpose: see identity.tf."

  permissions = ["firebaseauth.users.sendEmail"]
}

resource "google_project_iam_member" "api_mints_action_links" {
  project = var.project
  role    = google_project_iam_custom_role.action_link_minter.name
  member  = "serviceAccount:${google_service_account.api.email}"
}
