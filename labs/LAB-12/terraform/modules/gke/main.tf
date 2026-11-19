# Node'lar için ayrı, en az yetkili service account
resource "google_service_account" "nodes" {
  account_id   = "${var.name}-gke-nodes"
  display_name = "${var.name} GKE node service account"
}

resource "google_project_iam_member" "nodes" {
  for_each = toset([
    "roles/artifactregistry.reader",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodes.email}"
}

resource "google_container_cluster" "this" {
  name     = "${var.name}-gke"
  location = var.zone

  network    = var.network
  subnetwork = var.subnetwork

  # Varsayılan node pool açılmaz, aşağıdaki node pool kullanılır
  initial_node_count  = 0
  deletion_protection = false

  ip_allocation_policy {
    cluster_secondary_range_name  = var.pods_range_name
    services_secondary_range_name = var.services_range_name
  }

  release_channel {
    channel = "REGULAR"
  }
}

resource "google_container_node_pool" "default" {
  name       = "${var.name}-pool"
  cluster    = google_container_cluster.this.id
  location   = var.zone
  node_count = var.node_count

  node_config {
    machine_type    = var.machine_type
    spot            = var.spot
    disk_size_gb    = 30
    disk_type       = "pd-standard"
    service_account = google_service_account.nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  depends_on = [google_project_iam_member.nodes]
}
