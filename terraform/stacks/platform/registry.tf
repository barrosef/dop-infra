# Our own registry, and it is not a convenience.
#
# The data VM has NO route to the internet — only Private Google Access, which
# reaches Google APIs and nothing else. Docker Hub is unreachable from it. Every
# third-party image it runs (postgres/pgvector, nats) is mirrored here, which is
# the only way they arrive at all.
resource "google_artifact_registry_repository" "dop" {
  project       = var.project
  location      = var.region
  repository_id = "dop"
  format        = "DOCKER"
  description   = "Images of the platform, and the mirrored third-party ones the data VM cannot reach"
}
