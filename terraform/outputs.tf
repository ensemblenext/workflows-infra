# ============================================
# S3 Outputs
# ============================================
output "user_files_bucket_name" {
  description = "S3 bucket name for user files"
  value       = module.s3.user_files_bucket_name
}

output "user_files_bucket_arn" {
  description = "S3 bucket ARN for user files"
  value       = module.s3.user_files_bucket_arn
}

output "documents_bucket_name" {
  description = "S3 bucket name for documents"
  value       = module.s3.documents_bucket_name
}

output "documents_bucket_arn" {
  description = "S3 bucket ARN for documents"
  value       = module.s3.documents_bucket_arn
}

output "tenant_migrations_bucket_name" {
  description = "S3 bucket name for tenant migrations"
  value       = module.s3.tenant_migrations_bucket_name
}

output "tenant_migrations_bucket_arn" {
  description = "S3 bucket ARN for tenant migrations"
  value       = module.s3.tenant_migrations_bucket_arn
}

# ============================================
# KMS Outputs
# ============================================
output "kms_key_arn" {
  description = "KMS key ARN for encryption"
  value       = module.kms.key_arn
}

output "kms_key_id" {
  description = "KMS key ID"
  value       = module.kms.key_id
}

# ============================================
# IAM Outputs
# ============================================
output "workloads_role_arn" {
  description = "IAM role ARN for EKS workloads"
  value       = module.iam.workloads_role_arn
}

output "workloads_role_name" {
  description = "IAM role name for EKS workloads"
  value       = module.iam.workloads_role_name
}

output "scheduler_role_arn" {
  description = "IAM role ARN for EventBridge Scheduler"
  value       = module.iam.scheduler_role_arn
}

# ============================================
# Scheduler Outputs
# ============================================
output "scheduler_group_name" {
  description = "EventBridge Scheduler group name"
  value       = var.enable_scheduler ? module.scheduler[0].scheduler_group_name : ""
}

output "scheduler_event_bus_name" {
  description = "EventBridge event bus name used as the schedule target"
  value       = var.enable_scheduler ? module.scheduler[0].scheduler_event_bus_name : ""
}

output "scheduler_event_bus_arn" {
  description = "EventBridge event bus ARN used as the schedule target"
  value       = var.enable_scheduler ? module.scheduler[0].scheduler_event_bus_arn : ""
}

output "scheduler_api_destination_arn" {
  description = "EventBridge API Destination ARN for scheduled API callbacks"
  value       = var.enable_scheduler ? module.scheduler[0].scheduler_api_destination_arn : ""
}

# ============================================
# Cognito Outputs
# ============================================
output "cognito_user_pool_id" {
  description = "Cognito User Pool ID"
  value       = var.enable_cognito ? module.cognito[0].user_pool_id : ""
}

output "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = var.enable_cognito ? module.cognito[0].user_pool_arn : ""
}

output "cognito_user_pool_client_id" {
  description = "Cognito User Pool Client ID"
  value       = var.enable_cognito ? module.cognito[0].user_pool_client_id : ""
}

output "cognito_user_pool_domain" {
  description = "Cognito User Pool domain"
  value       = var.enable_cognito ? module.cognito[0].user_pool_domain : ""
}

output "cognito_scheduler_oauth_client_id" {
  description = "Cognito OAuth Client ID for EventBridge Scheduler"
  value       = var.enable_cognito && var.cognito_enable_scheduler_oauth ? module.cognito[0].scheduler_oauth_client_id : ""
}

output "cognito_scheduler_oauth_client_secret" {
  description = "Cognito OAuth Client Secret for EventBridge Scheduler"
  value       = var.enable_cognito && var.cognito_enable_scheduler_oauth ? module.cognito[0].scheduler_oauth_client_secret : ""
  sensitive   = true
}

output "cognito_scheduler_oauth_token_endpoint" {
  description = "Cognito OAuth Token Endpoint for EventBridge Scheduler"
  value       = var.enable_cognito && var.cognito_enable_scheduler_oauth ? module.cognito[0].scheduler_oauth_token_endpoint : ""
}

output "cognito_scheduler_oauth_scope" {
  description = "Cognito OAuth Scope for EventBridge Scheduler"
  value       = var.enable_cognito && var.cognito_enable_scheduler_oauth ? module.cognito[0].scheduler_oauth_scope : ""
}

# ============================================
# Secrets Outputs
# ============================================
output "app_secrets_arn" {
  description = "Secrets Manager secret ARN"
  value       = module.secrets.secret_arn
}

output "app_secrets_name" {
  description = "Secrets Manager secret name"
  value       = module.secrets.secret_name
}

# ============================================
# Helm Configuration Output
# ============================================
output "helm_config_values" {
  description = "Environment variables for Helm chart"
  value = merge({
    CLOUD_PROVIDER                    = "aws"
    AUTH_PROVIDER                     = var.enable_cognito ? "cognito" : "firebase"
    SERVERLESS_ENVIRONMENT            = "false"
    STORAGE_USER_FILES_BUCKET         = module.s3.user_files_bucket_name
    STORAGE_DOCUMENTS_BUCKET          = module.s3.documents_bucket_name
    STORAGE_TENANT_MIGRATIONS_BUCKET  = module.s3.tenant_migrations_bucket_name
    SCHEDULER_SERVICE_URL             = var.scheduler_api_destination_endpoint
    KMS_KEY_ARN                       = module.kms.key_arn
    AWS_REGION                        = data.aws_region.current.name
    AWS_SCHEDULER_ROLE_ARN            = module.iam.scheduler_role_arn
    AWS_SCHEDULER_GROUP_NAME          = var.enable_scheduler ? module.scheduler[0].scheduler_group_name : ""
    AWS_SCHEDULER_TARGET_ARN          = var.enable_scheduler ? module.scheduler[0].scheduler_event_bus_arn : ""
    AWS_SCHEDULER_EVENT_BUS_NAME      = var.enable_scheduler ? module.scheduler[0].scheduler_event_bus_name : ""
    AWS_SCHEDULER_EVENT_SOURCE        = var.enable_scheduler ? module.scheduler[0].scheduler_event_source : ""
    AWS_SCHEDULER_EVENT_DETAIL_TYPE   = var.enable_scheduler ? module.scheduler[0].scheduler_event_detail_type : ""
    AWS_SCHEDULER_API_DESTINATION_ARN = var.enable_scheduler ? module.scheduler[0].scheduler_api_destination_arn : ""
    AWS_COGNITO_USER_POOL_ID          = var.enable_cognito ? module.cognito[0].user_pool_id : ""
    AWS_COGNITO_REGION                = data.aws_region.current.name
    },
    # Merged in rather than left to task_queue_env alone: this output is the documented
    # way to populate the chart's config, so a queue setting that only appeared
    # elsewhere would be missed by anyone following it.
    # queue_env_values rather than indexing queue_names here: the module guards those
    # lookups, so overriding task_queues without one of the default keys does not break
    # the plan with an error about a missing map element.
    var.enable_task_queue ? merge(module.sqs[0].queue_env_values, {
      TASK_QUEUE_ENABLED   = "true"
      TASK_QUEUE_PROVIDER  = "sqs"
      SQS_QUEUE_URL_PREFIX = module.sqs[0].queue_url_prefix
    }) : {},
    var.enable_task_queue && var.cognito_enable_task_callback_oauth && var.enable_cognito ? {
      TASK_CALLBACK_OAUTH_TOKEN_URL = module.cognito[0].task_callback_oauth_token_endpoint
      TASK_CALLBACK_OAUTH_CLIENT_ID = module.cognito[0].task_callback_oauth_client_id
      # Needed by BOTH services: the worker requests this scope, the server requires it.
      TASK_CALLBACK_OAUTH_SCOPE = module.cognito[0].task_callback_oauth_scope
    } : {},
  )
}

output "service_account_annotation" {
  description = "Annotation for Kubernetes ServiceAccount"
  value = {
    "eks.amazonaws.com/role-arn" = module.iam.workloads_role_arn
  }
}

# ============================================
# ECR Outputs
# ============================================
output "ecr_repository_urls" {
  description = "Map of ECR repository names to URLs"
  value       = var.enable_ecr ? module.ecr[0].repository_urls : {}
}

output "ecr_registry_id" {
  description = "ECR registry ID"
  value       = var.enable_ecr ? module.ecr[0].registry_id : null
}

# ============================================
# SQS Task Queue Outputs
# ============================================
output "task_queue_url_prefix" {
  description = "SQS_QUEUE_URL_PREFIX for the server and worker"
  value       = var.enable_task_queue ? module.sqs[0].queue_url_prefix : null
}

output "task_queue_names" {
  description = "Task queue names, keyed by logical name"
  value       = var.enable_task_queue ? module.sqs[0].queue_names : {}
}

output "task_queue_arns" {
  description = "Task queue ARNs"
  value       = var.enable_task_queue ? module.sqs[0].queue_arns : []
}

output "task_queue_dlq_arns" {
  description = "Dead-letter queue ARNs; a task that exhausts its attempts lands here"
  value       = var.enable_task_queue ? module.sqs[0].dlq_arns : []
}

output "task_callback_oauth" {
  description = <<-EOT
    TASK_CALLBACK_OAUTH_* values for the worker, plus the scope the server also needs.
    Empty unless cognito_enable_task_callback_oauth is set.

    The scope appears on both services on purpose: the worker requests it and the
    server requires it, so a mismatch refuses every callback. One source for both is
    the reason this is wired here rather than set by hand.
  EOT
  value = var.enable_task_queue && var.cognito_enable_task_callback_oauth && var.enable_cognito ? {
    TASK_CALLBACK_OAUTH_TOKEN_URL = module.cognito[0].task_callback_oauth_token_endpoint
    TASK_CALLBACK_OAUTH_CLIENT_ID = module.cognito[0].task_callback_oauth_client_id
    TASK_CALLBACK_OAUTH_SCOPE     = module.cognito[0].task_callback_oauth_scope
  } : {}
}

output "task_callback_oauth_client_secret" {
  description = "TASK_CALLBACK_OAUTH_CLIENT_SECRET for the worker; store it as a secret, not in values.yaml"
  value       = var.enable_task_queue && var.cognito_enable_task_callback_oauth && var.enable_cognito ? module.cognito[0].task_callback_oauth_client_secret : ""
  sensitive   = true
}

output "task_queue_env" {
  description = "Queue-related environment values for the services. Queue names are prefixed per environment, so the application defaults do not match and must be set explicitly."
  value = var.enable_task_queue ? merge(
    module.sqs[0].queue_env_values,
    {
      SQS_QUEUE_URL_PREFIX = module.sqs[0].queue_url_prefix
      TASK_QUEUE_ENABLED   = "true"
      TASK_QUEUE_PROVIDER  = "sqs"
    }
  ) : {}
}
