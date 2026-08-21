variable "repository_prefix" {
  description = "Prefix for ECR repository names (e.g., 'workflows')"
  type        = string
  default     = "workflows"
}

variable "image_count_to_keep" {
  description = "Number of 'latest'/'-dev' (non-release) images to keep per repository. Immutable release tags (e.g. 1.1.<build>) are never expired."
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
