# ── The core: private, and private by IAM rather than by network ─────────────
#
# ADR-0029. Nothing anonymous reaches it: Cloud Run refuses the request with 403
# before this process starts, and the only principal allowed to invoke it is the
# BFF's service account (identity.tf).
resource "google_cloud_run_v2_service" "core" {
  project             = var.project
  name                = "dop-core"
  location            = var.region
  ingress             = "INGRESS_TRAFFIC_ALL"
  deletion_protection = false

  template {
    service_account                  = google_service_account.core.email
    timeout                          = "300s"
    max_instance_request_concurrency = 80

    scaling {
      min_instance_count = 0
      max_instance_count = 2
    }

    # Direct VPC egress, no connector: the connector is a billed always-on
    # instance, and this reaches the data VM's private address without one.
    # private-ranges-only keeps public traffic on the internet path, which is
    # what lets the core still fetch Google's token-signing certificates.
    vpc_access {
      egress = "PRIVATE_RANGES_ONLY"
      network_interfaces {
        network    = "default"
        subnetwork = "default"
      }
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project}/dop/dop-core:${var.core_image_tag}"
      args  = ["serve"]

      ports {
        name           = "h2c" # gRPC, cleartext inside the sandbox; TLS is terminated by Cloud Run
        container_port = 9090
      }

      resources {
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
        startup_cpu_boost = true
      }

      env {
        name  = "NATS_URL"
        value = "nats://${var.data_vm_internal_ip}:4222"
      }
      env {
        name  = "SECRET_BACKEND"
        value = "gcp"
      }
      env {
        name  = "SECRET_PROJECT"
        value = var.project
      }
      env {
        name  = "FIREBASE_PROJECT"
        value = var.project
      }
      env {
        name  = "LOG_LEVEL"
        value = "info"
      }
      # ADR-0029's destination, not its transition: no valid signature, no actor.
      env {
        name  = "CALL_AUTH_MODE"
        value = "strict"
      }
      env {
        name  = "PROJECT_REPO_BACKEND"
        value = "local"
      }
      # Cloud Run's filesystem is read-only except /tmp. ADR-0028's git server
      # needs somewhere to write, and on this instance it is scratch: the
      # durable copy lives on the data VM's worker.
      env {
        name  = "PROJECT_REPO_ROOT"
        value = "/tmp/dop-git"
      }

      dynamic "env" {
        for_each = {
          DATABASE_URL            = "dop-database-url"
          CALL_AUTH_KEY_BFF       = "dop-call-auth-key-bff"
          CALL_AUTH_KEY_COLLECTOR = "dop-call-auth-key-collector"
          PROJECT_REPO_KEY        = "dop-project-repo-key"
          PROJECT_REPO_ADMIN_KEY  = "dop-project-repo-admin-key"
        }
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = google_secret_manager_secret.this[env.value].secret_id
              version = "latest"
            }
          }
        }
      }
    }
  }

  depends_on = [google_project_service.this]
}

# ── The BFF: public, and public WITHOUT allUsers ─────────────────────────────
#
# The organization enforces Domain Restricted Sharing
# (constraints/iam.allowedPolicyMemberDomains). `allUsers` belongs to no domain,
# so the usual way to publish a Cloud Run service is refused outright — which
# would have stopped this architecture from deploying at all.
#
# invoker_iam_disabled is the way through: the service becomes publicly
# reachable with NO binding to a principal the policy forbids. Authentication
# does not weaken, it just stops being IAM's job here — every request still
# carries the person's Firebase token, and the core verifies it.
resource "google_cloud_run_v2_service" "api" {
  project              = var.project
  name                 = "dop-api"
  location             = var.region
  ingress              = "INGRESS_TRAFFIC_ALL"
  invoker_iam_disabled = true
  deletion_protection  = false

  template {
    service_account                  = google_service_account.api.email
    timeout                          = "300s"
    max_instance_request_concurrency = 80

    scaling {
      min_instance_count = 0
      max_instance_count = 3
    }

    containers {
      image = "${var.region}-docker.pkg.dev/${var.project}/dop/dop-api:${var.api_image_tag}"

      ports {
        name           = "http1"
        container_port = 8000
      }

      resources {
        limits = {
          cpu    = "1000m"
          memory = "512Mi"
        }
        startup_cpu_boost = true
      }

      # The core's address AND its audience. The audience is what turns the
      # channel from plaintext to TLS-with-identity on the BFF side: with it
      # empty the client speaks cleartext, which the in-cluster core accepts and
      # Cloud Run refuses.
      env {
        name  = "CORE_GRPC"
        value = "${trimprefix(google_cloud_run_v2_service.core.uri, "https://")}:443"
      }
      env {
        name  = "CORE_AUDIENCE"
        value = google_cloud_run_v2_service.core.uri
      }
      env {
        name  = "FIREBASE_PROJECT"
        value = var.project
      }
      env {
        name  = "LOG_LEVEL"
        value = "info"
      }
      env {
        name  = "CORS_ORIGINS"
        value = jsonencode(var.cors_origins)
      }
      env {
        name = "CALL_AUTH_KEY"
        value_source {
          secret_key_ref {
            secret  = google_secret_manager_secret.this["dop-call-auth-key-bff"].secret_id
            version = "latest"
          }
        }
      }
    }
  }

  depends_on = [google_project_service.this]
}
