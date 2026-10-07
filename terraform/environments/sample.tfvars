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

# Background task queue (TASK_QUEUE_PROVIDER=sqs).
# Creates evaluation-cases and webhook-processor, each with a dead-letter queue, and
# grants the workloads role send/receive on them. Create the queues before setting
# TASK_QUEUE_ENABLED=true on the services: with the queue enabled and nothing to
# enqueue into, every evaluation run is marked failed rather than falling back.
# After apply, `terraform output task_queue_env` prints the values the services need.
enable_task_queue = false

# EventBridge Scheduler callback delivery
scheduler_api_destination_endpoint = "https://workflows-dev.example.com/api/scheduler/callback"

# Option 1: API Key authentication (simpler)
scheduler_api_destination_auth_type     = "API_KEY"
scheduler_api_destination_api_key_name  = "x-api-key"
scheduler_api_destination_api_key_value = "replace-with-a-strong-shared-secret"

# Option 2: Cognito OAuth M2M authentication (more secure)
# Uncomment the following and comment out Option 1:
# scheduler_api_destination_auth_type  = "OAUTH_CLIENT_CREDENTIALS"
# cognito_enable_scheduler_oauth       = true
# cognito_scheduler_api_identifier     = "https://workflows-dev.example.com/api"

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
