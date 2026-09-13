variable "project" {
  description = "Name prefix."
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR block."
  type        = string
}

variable "azs" {
  description = "Two availability zones."
  type        = list(string)

  validation {
    condition     = length(var.azs) == 2
    error_message = "Exactly two availability zones are expected."
  }
}
