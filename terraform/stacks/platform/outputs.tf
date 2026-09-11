output "api_url" {
  description = "The BFF, which is the only address the cockpit needs."
  value       = google_cloud_run_v2_service.api.uri
}

output "core_url" {
  description = "Private: reachable only by the BFF's service account."
  value       = google_cloud_run_v2_service.core.uri
}

output "data_vm_ip" {
  value = google_compute_instance.data.network_interface[0].network_ip
}
