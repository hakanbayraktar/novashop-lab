terraform {
  required_version = ">= 1.5.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.12"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }

  # Bucket adı init sırasında verilir: terraform init -backend-config="bucket=<BUCKET>"
  backend "gcs" {
    prefix = "lab-12/state"
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}
