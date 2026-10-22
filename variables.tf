variable "aws_region" {
  type        = string
  description = "AWS region to deploy into"
  default     = "ap-southeast-2"
}

variable "environment" {
  type        = string
  description = "Environment name"
  default     = "dev"
}