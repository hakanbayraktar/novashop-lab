terraform {
  required_version = ">= 1.10.0"

  # Bucket bir kerelik hazırlıkta oluşturulur; CI adını -backend-config ile verir.
  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region

  default_labels = local.labels
}
