variable "project" {
  description = "Project prefix used in resource names and tags."
  type        = string
  default     = "8byte"
}

variable "env" {
  description = "Environment tag."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region for the state bucket and lock table."
  type        = string
  default     = "ap-south-1"
}
