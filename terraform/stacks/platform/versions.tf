# The DOP platform on GCP, one stack per environment.
#
# Read docs/qa-bootstrap-owner-steps.md before running this the first time:
# a few things cannot be codified (accepting terms, linking billing, creating
# an OAuth App on GitHub) and this stack assumes they were done.
#
#   terraform init -backend-config=envs/qa.backend
#   terraform plan  -var-file=envs/qa.tfvars
terraform {
  required_version = ">= 1.5"

  # Partial configuration: the bucket comes from envs/<env>.backend, so the
  # same code serves qa and prod without a branch.
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
  }
}

provider "google" {
  project = var.project
  region  = var.region
}
