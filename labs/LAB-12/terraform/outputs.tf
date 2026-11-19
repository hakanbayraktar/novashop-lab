output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "zone" {
  value = var.zone
}

output "cluster_name" {
  value = module.gke.cluster_name
}

output "artifact_repository" {
  value = module.artifact_registry.repository_id
}

output "artifact_registry_url" {
  value = module.artifact_registry.url
}

output "workload_identity_provider" {
  value = module.iam_wif.workload_identity_provider
}

output "service_account_email" {
  value = module.iam_wif.service_account_email
}
