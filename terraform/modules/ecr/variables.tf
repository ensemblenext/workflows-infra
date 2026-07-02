variable "repository_prefix" {
  description = "Prefix for ECR repository names (e.g., 'workflows')"
  type        = string
  default     = "workflows"
}

variable "image_count_to_keep" {
  description = "Number of images to keep per repository"
  type        = number
  default     = 8
}

variable "scan_on_push" {
  description = "Enable image scanning on push"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}
