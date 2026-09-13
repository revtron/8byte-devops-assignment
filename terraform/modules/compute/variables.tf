variable "project" {
  description = "Name prefix."
  type        = string
}

variable "region" {
  type = string
}

variable "public_subnet_id" {
  description = "Subnet for the management host."
  type        = string
}

variable "private_subnet_id" {
  description = "Subnet for backend and mon."
  type        = string
}

variable "management_sg_id" {
  type = string
}

variable "backend_sg_id" {
  type = string
}

variable "mon_sg_id" {
  type = string
}

variable "instance_types" {
  description = "role => instance type; keys management, backend, mon."
  type        = map(string)

  validation {
    condition     = alltrue([for k in ["management", "backend", "mon"] : contains(keys(var.instance_types), k)])
    error_message = "instance_types must have keys management, backend and mon."
  }
}

variable "root_volume_sizes" {
  description = "role => root volume size in GiB."
  type        = map(number)
  default = {
    management = 30
    backend    = 20
    mon        = 20
  }
}

variable "backend_private_ip" {
  type    = string
  default = "10.0.10.10"
}

variable "mon_private_ip" {
  type    = string
  default = "10.0.10.20"
}

variable "admin_public_key" {
  description = "OpenSSH public key for the per-host login user."
  type        = string
}

variable "github_repo" {
  type = string
}

variable "git_ref" {
  type = string
}

variable "dockerhub_repo" {
  type = string
}

variable "secret_names" {
  description = "Secrets Manager names: keys db, dockerhub, github, jenkins."
  type        = map(string)
}

variable "secret_arns" {
  description = "Secrets Manager ARNs: keys db, dockerhub, github, jenkins."
  type        = map(string)
}

variable "sns_topic_arn" {
  type = string
}

variable "alb_dns_name" {
  type = string
}

variable "templates_dir" {
  description = "Directory containing user_data.sh.tftpl."
  type        = string
}

variable "compose_version" {
  description = "docker compose v2 plugin version downloaded at boot (not in AL2023 repos)."
  type        = string
  default     = "2.29.7"
}
