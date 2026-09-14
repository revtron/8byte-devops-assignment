variable "project" {
  description = "Name prefix."
  type        = string
}

variable "vpc_id" {
  type = string
}

variable "public_subnet_ids" {
  description = "Subnets the ALB is placed in (one per AZ)."
  type        = list(string)
}

variable "alb_sg_id" {
  type = string
}

variable "backend_instance_id" {
  description = "Instance registered in both target groups."
  type        = string
}

variable "account_id" {
  description = "Current account id, used in the access-log bucket name."
  type        = string
}

variable "log_retention_days" {
  type    = number
  default = 30
}

variable "mon_instance_id" {
  description = "Instance behind the Grafana (3000) and Prometheus (9090) listeners."
  type        = string
}
