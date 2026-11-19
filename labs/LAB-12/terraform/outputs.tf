output "cluster_name" {
  value = module.gke.cluster_name
}

output "cluster_zone" {
  value = var.zone
}

output "artifact_registry_url" {
  value = module.artifact_registry.url
}
