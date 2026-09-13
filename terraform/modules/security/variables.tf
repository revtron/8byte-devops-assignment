variable "project" {
  description = "Name prefix."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH to the management host."
  type        = string
}
