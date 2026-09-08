# Adoption, not creation.
#
# The QA environment was built by hand, discovery by discovery, and it works.
# Recreating it from scratch to make Terraform happy would throw away a database
# and a week of findings. These blocks hand the existing resources to the state
# instead, and the test of this whole stack is simple and strict: after a
# successful init, `terraform plan` must report NO changes. Any diff is the code
# disagreeing with reality, and reality wins until somebody decides otherwise.
#
# They can be deleted once every environment has been imported once — an import
# block for a resource already in state is a no-op, so leaving them costs
# nothing but noise.

import {
  to = google_artifact_registry_repository.dop
  id = "projects/${var.project}/locations/${var.region}/repositories/dop"
}

import {
  for_each = toset(local.services)
  to       = google_project_service.this[each.value]
  id       = "${var.project}/${each.value}"
}

import {
  for_each = toset(local.secrets)
  to       = google_secret_manager_secret.this[each.value]
  id       = "projects/${var.project}/secrets/${each.value}"
}

import {
  to = google_service_account.core
  id = "projects/${var.project}/serviceAccounts/dop-core-sa@${var.project}.iam.gserviceaccount.com"
}

import {
  to = google_service_account.api
  id = "projects/${var.project}/serviceAccounts/dop-api-sa@${var.project}.iam.gserviceaccount.com"
}

import {
  to = google_service_account.vm
  id = "projects/${var.project}/serviceAccounts/dop-vm@${var.project}.iam.gserviceaccount.com"
}

import {
  to = google_compute_firewall.iap_ssh
  id = "projects/${var.project}/global/firewalls/allow-iap-ssh"
}

import {
  to = google_compute_instance.data
  id = "projects/${var.project}/zones/${var.zone}/instances/dop-data"
}

import {
  to = google_cloud_run_v2_service.core
  id = "projects/${var.project}/locations/${var.region}/services/dop-core"
}

import {
  to = google_cloud_run_v2_service.api
  id = "projects/${var.project}/locations/${var.region}/services/dop-api"
}

import {
  to = google_cloud_run_v2_service_iam_member.api_invokes_core
  id = "projects/${var.project}/locations/${var.region}/services/dop-core roles/run.invoker serviceAccount:dop-api-sa@${var.project}.iam.gserviceaccount.com"
}

import {
  for_each = toset(local.workload_sa_emails)
  to       = google_project_iam_member.secret_accessor[each.value]
  id       = "${var.project} roles/secretmanager.secretAccessor serviceAccount:${each.value}"
}

import {
  to = google_project_iam_member.vm_reads_registry
  id = "${var.project} roles/artifactregistry.reader serviceAccount:dop-vm@${var.project}.iam.gserviceaccount.com"
}

import {
  to = google_project_iam_member.vm_writes_logs
  id = "${var.project} roles/logging.logWriter serviceAccount:dop-vm@${var.project}.iam.gserviceaccount.com"
}
