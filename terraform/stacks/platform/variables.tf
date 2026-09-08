variable "project" {
  type        = string
  description = "GCP project id — one per environment, never shared."
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type        = string
  default     = "us-central1-a"
  description = "Where the data VM lives. Free-tier e2-micro is us-central1/us-west1/us-east1 only."
}

variable "core_image_tag" {
  type        = string
  description = "Tag of dop-core, NEVER a moving one. See the note in the Makefile: a rebuilt tag is not a new image to a runtime that already cached it."
}

variable "api_image_tag" {
  type = string
}

variable "cors_origins" {
  type        = list(string)
  description = "Origins the BFF answers to. The cockpit's origin, and nothing else."
}

variable "data_vm_internal_ip" {
  type        = string
  description = "Pinned so the Cloud Run services can be configured before the VM exists. A DHCP address here would make the services depend on boot order."
}
