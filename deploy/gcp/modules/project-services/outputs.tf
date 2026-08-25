output "enabled_services" {
  description = "The APIs this unit enabled, so a downstream unit can depend on them."
  value       = [for s in google_project_service.enabled : s.service]
}
