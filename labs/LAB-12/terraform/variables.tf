variable "project_id" {
  description = "GCP proje ID'si"
  type        = string
}

variable "region" {
  description = "Artifact Registry ve subnet bölgesi"
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "Zonal GKE cluster'ın zone'u"
  type        = string
  default     = "europe-west1-b"
}

variable "name" {
  description = "Tüm kaynakların ön eki"
  type        = string
  default     = "novashop"
}

variable "github_repo" {
  description = "Pipeline'ın çalışacağı GitHub reposu (sahip/repo)"
  type        = string
}

variable "node_count" {
  description = "Node sayısı"
  type        = number
  default     = 2
}

variable "machine_type" {
  description = "Node makine tipi"
  type        = string
  default     = "e2-medium"
}

variable "spot" {
  description = "Spot (ucuz, kesintiye uğrayabilir) node kullan"
  type        = bool
  default     = true
}
