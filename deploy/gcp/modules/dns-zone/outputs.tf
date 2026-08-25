output "zone_name" {
  value = google_dns_managed_zone.public.name
}

output "name_servers" {
  description = "Delegate the domain to these at the registrar. Nothing resolves until you do."
  value       = google_dns_managed_zone.public.name_servers
}
