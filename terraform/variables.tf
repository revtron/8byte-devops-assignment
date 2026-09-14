variable "project" {
  description = "Project prefix used in every resource name and tag."
  type        = string
  default     = "8byte"
}

variable "env" {
  description = "Environment name (tag and state key)."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "ap-south-1"
}

variable "vpc_cidr" {
  description = "CIDR block of the VPC."
  type        = string
  default     = "10.0.0.0/16"
}

variable "azs" {
  description = "Two availability zones; the first one hosts the NAT gateway and all instances."
  type        = list(string)
  default     = ["ap-south-1a", "ap-south-1b"]
}

variable "instance_types" {
  description = "EC2 instance type per host role."
  type        = map(string)
  default = {
    management = "t3.small"
    backend    = "t3.micro"
    mon        = "t3.small"
  }
}

variable "db_instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "db_allocated_storage" {
  description = "RDS allocated storage in GiB."
  type        = number
  default     = 20
}

variable "db_backup_retention_days" {
  description = "RDS automated backup retention in days. AWS free-plan accounts reject values above 1."
  type        = number
  default     = 7
}

variable "admin_cidr" {
  description = "CIDR allowed to SSH to the management host (your public IP, e.g. 203.0.113.4/32)."
  type        = string

  validation {
    condition     = can(cidrnetmask(var.admin_cidr))
    error_message = "admin_cidr must be an IPv4 CIDR with a prefix length, e.g. 203.0.113.4/32."
  }
}

variable "admin_public_key" {
  description = "OpenSSH public key installed for the management/backend/mon users."
  type        = string
}

variable "alert_email" {
  description = "Email address subscribed to the alerts SNS topic."
  type        = string
}

variable "dockerhub_repo" {
  description = "Docker Hub repository for the app image, e.g. user/todo."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository in owner/repo form; cloned by every host at boot."
  type        = string
}

variable "git_ref" {
  description = "Branch or tag of github_repo checked out at boot."
  type        = string
  default     = "main"
}

variable "tags" {
  description = "Extra tags merged into provider default_tags."
  type        = map(string)
  default     = {}
}
