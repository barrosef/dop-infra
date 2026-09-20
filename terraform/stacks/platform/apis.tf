# The APIs this platform actually uses. The project has more enabled — Firebase
# turned a dozen on by itself — and they are deliberately NOT listed: this stack
# owns what it needs and does not fight the console over the rest.
locals {
  services = [
    "artifactregistry.googleapis.com",
    "cloudtrace.googleapis.com", # the trace backend on GCP (ADR-0024 §4)
    "compute.googleapis.com",
    "iamcredentials.googleapis.com",
    "identitytoolkit.googleapis.com", # Identity Platform and Firebase Auth are the same backend
    "logging.googleapis.com",
    "run.googleapis.com",
    "secretmanager.googleapis.com",
    "securetoken.googleapis.com",
  ]
}

resource "google_project_service" "this" {
  for_each = toset(local.services)

  project = var.project
  service = each.value

  # Disabling an API on `terraform destroy` would take the whole project's
  # unrelated resources down with it. Turning one off is a deliberate act, not
  # a side effect of tearing down a stack.
  disable_on_destroy         = false
  disable_dependent_services = false
}
