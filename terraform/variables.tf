variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-west-2"
}

variable "environment" {
  description = "Environment name (dev, staging, prod)"
  type        = string
  default     = "dev"
}

variable "project_name" {
  description = "Project name prefix for resources"
  type        = string
  default     = "workflows"
}

# EKS Configuration
variable "eks_cluster_name" {
  description = "EKS cluster name for IRSA"
  type        = string
  default     = ""
}

variable "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN for IRSA"
  type        = string
  default     = ""
}

variable "eks_namespace" {
  description = "Kubernetes namespace for workloads"
  type        = string
  default     = "workflows"
}

variable "eks_service_account_name" {
  description = "Kubernetes service account name"
  type        = string
  default     = "workflows-sa"
}

# Feature Flags
variable "enable_cognito" {
  description = "Enable AWS Cognito for authentication"
  type        = bool
  default     = true
}

variable "enable_scheduler" {
  description = "Enable EventBridge Scheduler resources"
  type        = bool
  default     = true
}

# EventBridge Scheduler callback delivery
variable "scheduler_api_destination_endpoint" {
  description = "HTTPS API endpoint invoked when scheduled events fire. Leave empty to create only the schedule group/event bus."
  type        = string
  default     = ""
}

variable "scheduler_api_destination_http_method" {
  description = "HTTP method used for scheduled API callbacks"
  type        = string
  default     = "POST"
}

variable "scheduler_api_destination_invocation_rate_limit_per_second" {
  description = "Maximum invocations per second for scheduled API callbacks"
  type        = number
  default     = 50
}

variable "scheduler_api_destination_auth_type" {
  description = "Authorization type for scheduled API callbacks. Supported values: API_KEY, BASIC, OAUTH_CLIENT_CREDENTIALS."
  type        = string
  default     = "API_KEY"
}

variable "scheduler_api_destination_api_key_name" {
  description = "API key header name for scheduled API callbacks"
  type        = string
  default     = "x-api-key"
}

variable "scheduler_api_destination_api_key_value" {
  description = "API key value for scheduled API callbacks"
  type        = string
  default     = ""
  sensitive   = true
}

variable "scheduler_api_destination_basic_username" {
  description = "Basic auth username for scheduled API callbacks"
  type        = string
  default     = ""
  sensitive   = true
}

variable "scheduler_api_destination_basic_password" {
  description = "Basic auth password for scheduled API callbacks"
  type        = string
  default     = ""
  sensitive   = true
}

variable "scheduler_api_destination_oauth_authorization_endpoint" {
  description = "OAuth token endpoint for scheduled API callbacks"
  type        = string
  default     = ""
}

variable "scheduler_api_destination_oauth_http_method" {
  description = "HTTP method used for the OAuth token request"
  type        = string
  default     = "POST"
}

variable "scheduler_api_destination_oauth_client_id" {
  description = "OAuth client ID for scheduled API callbacks"
  type        = string
  default     = ""
  sensitive   = true
}

variable "scheduler_api_destination_oauth_client_secret" {
  description = "OAuth client secret for scheduled API callbacks"
  type        = string
  default     = ""
  sensitive   = true
}

variable "scheduler_api_destination_oauth_http_parameters" {
  description = "Optional OAuth token request parameters for scheduled API callbacks"
  type = object({
    body = optional(list(object({
      key             = string
      value           = string
      is_value_secret = optional(bool, false)
    })), [])
    header = optional(list(object({
      key             = string
      value           = string
      is_value_secret = optional(bool, false)
    })), [])
    query_string = optional(list(object({
      key             = string
      value           = string
      is_value_secret = optional(bool, false)
    })), [])
  })
  default = {}
}

variable "scheduler_event_source" {
  description = "EventBridge source value for scheduled callback events"
  type        = string
  default     = "workflows.scheduler"
}

variable "scheduler_event_detail_type" {
  description = "EventBridge detail-type value for scheduled callback events"
  type        = string
  default     = "ScheduledEvent"
}

# Cognito Configuration
variable "cognito_callback_urls" {
  description = "Allowed callback URLs for Cognito"
  type        = list(string)
  default     = ["http://localhost:3000/auth/callback"]
}

variable "cognito_logout_urls" {
  description = "Allowed logout URLs for Cognito"
  type        = list(string)
  default     = ["http://localhost:3000"]
}

variable "cognito_enable_scheduler_oauth" {
  description = "Enable OAuth client for EventBridge Scheduler M2M authentication"
  type        = bool
  default     = false
}

variable "cognito_scheduler_api_identifier" {
  description = "Resource server identifier for scheduler API (e.g., https://api.example.com)"
  type        = string
  default     = ""
}

# S3 Configuration
variable "s3_force_destroy" {
  description = "Allow destroying S3 buckets with objects"
  type        = bool
  default     = false
}

variable "s3_versioning_enabled" {
  description = "Enable versioning on S3 buckets"
  type        = bool
  default     = true
}

variable "s3_noncurrent_version_expiration_days" {
  description = "Days to keep noncurrent versions"
  type        = number
  default     = 90
}

# Existing S3 Buckets (leave empty to create new buckets)
variable "existing_user_files_bucket" {
  description = "Name of existing S3 bucket for user files (leave empty to create new)"
  type        = string
  default     = ""
}

variable "existing_documents_bucket" {
  description = "Name of existing S3 bucket for documents (leave empty to create new)"
  type        = string
  default     = ""
}

variable "existing_tenant_migrations_bucket" {
  description = "Name of existing S3 bucket for tenant migrations (leave empty to create new)"
  type        = string
  default     = ""
}

# Existing KMS Key (leave empty to create new key)
variable "existing_kms_key_arn" {
  description = "ARN of existing KMS key for encryption (leave empty to create new)"
  type        = string
  default     = ""
}
