variable "project_id" {
  description = "GCP proje ID'si."
  type        = string
}

variable "region" {
  description = "Subnet ve Artifact Registry bölgesi."
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "Zonal GKE cluster'ın zone'u."
  type        = string
  default     = "europe-west1-b"
}

variable "project" {
  description = "Kaynak adlarında kullanılan kısa proje adı."
  type        = string
  default     = "novashop"
}

variable "environment" {
  description = "Ortam adı."
  type        = string
  default     = "training"
}

variable "node_machine_type" {
  description = "Node makine tipi. ELK ve Prometheus için node başına 8 GB bellek."
  type        = string
  default     = "e2-standard-2"
}

variable "node_count" {
  description = "Node sayısı. Elasticsearch ve Kibana ayrı node'lara yerleştiği için en az 2."
  type        = number
  default     = 2
}

variable "spot" {
  description = "Spot (ucuz, kesintiye uğrayabilir) node kullan."
  type        = bool
  default     = true
}
