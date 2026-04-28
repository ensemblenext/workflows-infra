# Development environment configuration

aws_region   = "us-west-2"
environment  = "dev"
project_name = "workflows"

# EKS Configuration
eks_cluster_name         = "workflows-dev"
eks_namespace            = "workflows"
eks_service_account_name = "workflows-sa"
# eks_oidc_provider_arn  = "" # Set after EKS cluster is created

# Feature Flags
enable_cognito   = true
enable_scheduler = true

# EventBridge Scheduler callback delivery
scheduler_api_destination_endpoint      = "https://workflows-dev.example.com/api/scheduler/callback"
scheduler_api_destination_auth_type     = "API_KEY"
scheduler_api_destination_api_key_name  = "x-api-key"
scheduler_api_destination_api_key_value = "replace-with-a-strong-shared-secret"

# Cognito URLs
cognito_callback_urls = [
  "http://localhost:3000/auth/callback"
]
cognito_logout_urls = [
  "http://localhost:3000"
]

# S3 Configuration - more permissive for dev
s3_force_destroy                      = true
s3_versioning_enabled                 = true
s3_noncurrent_version_expiration_days = 30
