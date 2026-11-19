locals {
  name = "${var.project}-${var.environment}"
  labels = {
    project     = var.project
    environment = var.environment
    managed-by  = "terraform"
  }
}

module "network" {
  source = "./modules/network"

  name   = local.name
  region = var.region
}

module "gke" {
  source = "./modules/gke"

  project_id          = var.project_id
  name                = local.name
  zone                = var.zone
  network             = module.network.network_id
  subnetwork          = module.network.subnetwork_id
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
  node_count          = var.node_count
  machine_type        = var.node_machine_type
  spot                = var.spot
}

module "artifact_registry" {
  source = "./modules/artifact-registry"

  project_id = var.project_id
  name       = var.project
  region     = var.region
}
