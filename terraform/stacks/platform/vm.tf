# The data VM: Postgres, NATS and the core's worker on one Always Free e2-micro.
#
# Why these three share a machine: they are the parts that must be LISTENING,
# and Cloud Run bills for an instance that never sleeps. Everything
# request-driven — the core's `serve`, the BFF — is on Cloud Run and scales to
# zero. This VM is the exception that pays for itself by being free.
#
# It is a QA machine: no backup, no failover, no SLA, and three processes inside
# 1 GB. Written down rather than discovered.
resource "google_compute_instance" "data" {
  project      = var.project
  name         = "dop-data"
  zone         = var.zone
  machine_type = "e2-micro" # the Always Free shape; anything larger is billed

  tags = ["dop-data"]

  boot_disk {
    initialize_params {
      # Container-Optimized OS: docker is already there and the machine is
      # small. Its cost is the read-only /root and the INPUT DROP policy, both
      # handled in the startup script.
      # Pinned to the exact image, not the family: `cos-cloud/cos-stable` moves,
      # and boot_disk is ForceNew — a family that rolled forward would make
      # Terraform propose REPLACING the machine that holds the database.
      image = "cos-cloud/cos-stable-121-18867-584-3"
      # 30 GB is the Always Free allowance for standard persistent disk. It is
      # the size the machine actually has; anything smaller here is a ForceNew
      # diff, not a resize.
      size = 30
      type = "pd-standard"
    }
  }

  network_interface {
    subnetwork = data.google_compute_subnetwork.default.id
    # Pinned rather than dynamic: the Cloud Run services carry this address in
    # their environment, so a lease that moved would break them at the next
    # boot, silently and out of hours.
    network_ip = var.data_vm_internal_ip
    # No access_config block, so NO external address. That is the security
    # posture AND the reason this machine is free.
  }

  service_account {
    email  = google_service_account.vm.email
    scopes = ["cloud-platform"] # the grants are IAM's job, not the scope's
  }

  metadata = {
    # OS Login off: the startup script and IAP SSH are the only ways in, and
    # OS Login on a COS box adds a moving part with nothing to gain here.
    startup-script = templatefile("${path.module}/files/data-vm-startup.sh", {
      project        = var.project
      region         = var.region
      core_image_tag = var.core_image_tag
    })
  }

  # The disk is stateful — it holds the database. Terraform must never be one
  # `-replace` away from destroying it.
  lifecycle {
    prevent_destroy = true
    # A new COS release must never read as "replace the database machine".
    # Moving this VM to a newer image is a deliberate act with a data plan
    # behind it, not something a refresh decides.
    ignore_changes = [boot_disk[0].initialize_params[0].image]
  }

  depends_on = [google_project_service.this]
}
