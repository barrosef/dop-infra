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

variable "mail_backend" {
  type        = string
  default     = "smtp"
  description = "Which Mailer adapter the core wires: onesignal | sendgrid | smtp. An empty credential turns any of them into a dry run rather than a failure."
}

variable "onesignal_app_id" {
  type        = string
  default     = ""
  description = "The OneSignal application id. Public by design (it ships in the client SDKs); an empty value leaves the mailer in dry run, which renders and logs instead of sending."
}

variable "api_custom_domain" {
  type        = string
  default     = ""
  description = "The BFF's own hostname (api.qa.dop-t.com). Empty leaves the service on its run.app URL. Setting it requires the domain to be verified in Search Console FOR THE ACCOUNT RUNNING TERRAFORM — Cloud Run refuses the mapping otherwise, and the error names the verified domains it does know."
}

variable "firebase_auth_domain" {
  type        = string
  default     = ""
  description = "The host the BFF rewrites e-mail action links to. Must serve /__/auth/action — a Firebase Hosting custom domain of the same project does. Empty leaves links on <project>.firebaseapp.com."
}

variable "mail_from" {
  type        = string
  default     = ""
  description = "The From address of every message the core sends. Must be on the domain authenticated at the mail provider; empty falls back to the core's noreply@dop.local, which is a domain that does not exist."
}

variable "mail_from_name" {
  type    = string
  default = "DOP"
}

variable "mail_reply_to" {
  type        = string
  default     = ""
  description = "Reply-To of every message the core sends. A real, read inbox — the sender is a noreply."
}

variable "trace_sample_ratio" {
  description = "Fraction of new traces sampled (ADR-0024 §4); parent-based, so a sampled request stays sampled downstream."
  type        = string
  default     = "1"
}
