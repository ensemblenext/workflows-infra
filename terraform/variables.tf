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
