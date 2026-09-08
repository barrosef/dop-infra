# The state bucket, and nothing else.
#
# Chicken and egg: the platform stack keeps its state in a bucket, and the
# bucket cannot be created by the stack that needs it to exist first. So this
# one runs ONCE, with local state, and its own state is disposable — everything
# here can be recreated from this file with no loss.
#
#   terraform -chdir=terraform/bootstrap init
#   terraform -chdir=terraform/bootstrap apply -var project=dop-qa
terraform {
  required_version = ">= 1.5"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

variable "project" { type = string }
variable "region" {
  type    = string
  default = "us-central1"
}

provider "google" {
  project = var.project
  region  = var.region
}

# Versioning is the whole point: a corrupted or truncated state is recoverable
# from the previous generation. Without it, one bad apply is unrecoverable.
resource "google_storage_bucket" "state" {
  name                        = "${var.project}-tfstate"
  location                    = var.region
  uniform_bucket_level_access = true
  force_destroy               = false

  versioning { enabled = true }

  lifecycle {
    prevent_destroy = true
  }
}

output "bucket" { value = google_storage_bucket.state.name }
