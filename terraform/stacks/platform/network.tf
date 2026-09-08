# SSH reaches the data VM through IAP, never from the internet: the machine has
# no external address at all, which is both the security posture and the reason
# it costs nothing. 35.235.240.0/20 is IAP's forwarding range.
resource "google_compute_firewall" "iap_ssh" {
  project       = var.project
  name          = "allow-iap-ssh"
  network       = "default"
  source_ranges = ["35.235.240.0/20"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Postgres (5432) and NATS (4222) are reachable from inside the VPC by the
# default-allow-internal rule the auto-mode network ships with. There is no rule
# for them here, and that is not an omission.
#
# THE TRAP, written down because it cost an afternoon: the VPC rule is necessary
# and NOT sufficient. Container-Optimized OS boots with `INPUT policy DROP`, so
# the packet arrives at the machine and the operating system discards it, with
# nothing in the GCP console to suggest why — Cloud Run reports a dial timeout,
# which reads like a routing problem. The host firewall is opened by the VM's
# startup script (files/data-vm-startup.sh), not from here.

# The default subnet is created by the auto-mode network, not by this stack, so
# it is verified rather than owned. Private Google Access is what lets a machine
# with no external address reach Secret Manager and Artifact Registry; with it
# off, the VM boots, cannot read its own password, and dies quietly.
data "google_compute_subnetwork" "default" {
  project = var.project
  region  = var.region
  name    = "default"
}

check "private_google_access_is_on" {
  assert {
    condition     = data.google_compute_subnetwork.default.private_ip_google_access
    error_message = "Private Google Access is off on the default subnet in ${var.region}: the data VM has no external address, so it cannot reach Secret Manager or Artifact Registry and will fail at boot with no useful error."
  }
}
