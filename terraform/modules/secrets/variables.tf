variable "project" {
  description = "Name prefix (secrets are named <project>/<name>)."
  type        = string
}

variable "db_host" {
  type = string
}

variable "db_port" {
  type = number
}

variable "db_username" {
  type = string
}

variable "db_password" {
  type      = string
  sensitive = true
}

variable "db_name_prod" {
  type    = string
  default = "todo_prod"
}

variable "db_name_staging" {
  type    = string
  default = "todo_staging"
}
