data "google_project" "this" {
  project_id = var.project
}

locals {
  core_host = "dop-core-${data.google_project.this.number}.${var.region}.run.app"
}

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
  deletion_protection = true

  # The SERVICE-level scaling block, distinct from the template's. The API
  # always returns it populated, so omitting it makes Terraform propose nulling
  # it on every single plan — a diff that never converges and trains everyone to
  # skim past plans.
  scaling {
    min_instance_count = 0
  }

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
        # CPU only while a request is in flight. Left unset, the provider asks
        # for CPU ALWAYS ALLOCATED, which bills around the clock and throws away
        # the reason these services are on Cloud Run instead of the VM.
        cpu_idle          = true
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
      env {
        name  = "MAIL_BACKEND"
        value = var.mail_backend
      }
      env {
        name  = "ONESIGNAL_APP_ID"
        value = var.onesignal_app_id
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
          ONESIGNAL_API_KEY       = "dop-onesignal-api-key"
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
  deletion_protection  = true

  # The SERVICE-level scaling block, distinct from the template's. The API
  # always returns it populated, so omitting it makes Terraform propose nulling
  # it on every single plan — a diff that never converges and trains everyone to
  # skim past plans.
  scaling {
    min_instance_count = 0
  }

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
        # CPU only while a request is in flight. Left unset, the provider asks
        # for CPU ALWAYS ALLOCATED, which bills around the clock and throws away
        # the reason these services are on Cloud Run instead of the VM.
        cpu_idle          = true
        startup_cpu_boost = true
      }

      # The core's address AND its audience. The audience is what turns the
      # channel from plaintext to TLS-with-identity on the BFF side: with it
      # empty the client speaks cleartext, which the in-cluster core accepts and
      # Cloud Run refuses.
      # Cloud Run gives a service TWO hostnames: one built from the project
      # NUMBER and one from an opaque hash. `.uri` returns the hash form, and
      # what is deployed and proven working is the number form — the audience of
      # the token the BFF mints has to be the host it actually dials. Deriving
      # it from the project number keeps the working value instead of quietly
      # swapping the identity of the callee.
      env {
        name  = "CORE_GRPC"
        value = "${local.core_host}:443"
      }
      env {
        name  = "CORE_AUDIENCE"
        value = "https://${local.core_host}"
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

// The BFF under our own name.
//
// A mapping and not a Firebase Hosting rewrite, which would have skipped the
// Search Console step by reusing the TXT verification that auth.qa.dop-t.com
// already passed. The reason is the attention stream: the BFF answers
// `/api/v1/stream/attention` with Server-Sent Events, and Firebase Hosting
// buffers responses and cuts them at 60 seconds. The stream would die every
// minute — an intermittent bug nobody would connect back to a DNS decision.
//
// Guarded by the variable so the plan stays clean until the domain is verified:
// Cloud Run refuses the mapping outright otherwise, and refuses it at APPLY
// time, which would turn every unrelated apply into a failure.
resource "google_cloud_run_domain_mapping" "api" {
  count = var.api_custom_domain == "" ? 0 : 1

  project  = var.project
  location = var.region
  name     = var.api_custom_domain

  metadata {
    namespace = var.project
  }

  spec {
    route_name = google_cloud_run_v2_service.api.name
  }
}

output "api_dns_records" {
  description = "What to put in the DNS once the mapping exists. Empty until api_custom_domain is set."
  value = var.api_custom_domain == "" ? [] : [
    for r in google_cloud_run_domain_mapping.api[0].status[0].resource_records :
    "${r.type} ${r.name} -> ${r.rrdata}"
  ]
}
