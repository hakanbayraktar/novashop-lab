locals {
  apis = [
    "compute.googleapis.com",
    "container.googleapis.com",
    "artifactregistry.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
    "cloudresourcemanager.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each           = toset(local.apis)
  service            = each.value
  disable_on_destroy = false
}

module "network" {
  source = "./modules/network"

  name   = var.name
  region = var.region

  depends_on = [google_project_service.apis]
}

module "artifact_registry" {
  source = "./modules/artifact-registry"

  project_id = var.project_id
  name       = var.name
  region     = var.region

  depends_on = [google_project_service.apis]
}

module "gke" {
  source = "./modules/gke"

  project_id          = var.project_id
  name                = var.name
  zone                = var.zone
  network             = module.network.network_id
  subnetwork          = module.network.subnetwork_id
  pods_range_name     = module.network.pods_range_name
  services_range_name = module.network.services_range_name
  node_count          = var.node_count
  machine_type        = var.machine_type
  spot                = var.spot
}

module "iam_wif" {
  source = "./modules/iam-wif"

  project_id          = var.project_id
  name                = var.name
  github_repo         = var.github_repo
  repository_id       = module.artifact_registry.repository_id
  repository_location = var.region

  depends_on = [google_project_service.apis]
}
