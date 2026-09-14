variable "project" {
  description = "Name prefix."
  type        = string
}

variable "private_subnet_ids" {
  type = list(string)
}

variable "rds_sg_id" {
  type = string
}

variable "instance_class" {
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "backup_retention_days" {
  description = "Automated backup retention. Free-plan accounts are capped at 1."
  type        = number
  default     = 7
}

variable "engine_version" {
  description = "PostgreSQL major version; minor upgrades are automatic."
  type        = string
  default     = "16"
}

variable "master_username" {
  type    = string
  default = "todo"
}

variable "db_name" {
  description = "Initial database created by RDS."
  type        = string
  default     = "todo_prod"
}
