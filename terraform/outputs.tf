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
  value = {
    CLOUD_PROVIDER                   = "aws"
    AWS_REGION                       = data.aws_region.current.name
    SERVERLESS_ENVIRONMENT           = "false"
    STORAGE_USER_FILES_BUCKET        = module.s3.user_files_bucket_name
    STORAGE_DOCUMENTS_BUCKET         = module.s3.documents_bucket_name
    STORAGE_TENANT_MIGRATIONS_BUCKET = module.s3.tenant_migrations_bucket_name
    KMS_KEY_ARN                      = module.kms.key_arn
    SCHEDULER_ROLE_ARN               = module.iam.scheduler_role_arn
    SCHEDULER_GROUP_NAME             = var.enable_scheduler ? module.scheduler[0].scheduler_group_name : ""
    SCHEDULER_TARGET_ARN             = var.enable_scheduler ? module.scheduler[0].scheduler_event_bus_arn : ""
    SCHEDULER_EVENT_BUS_NAME         = var.enable_scheduler ? module.scheduler[0].scheduler_event_bus_name : ""
    SCHEDULER_EVENT_SOURCE           = var.enable_scheduler ? module.scheduler[0].scheduler_event_source : ""
    SCHEDULER_EVENT_DETAIL_TYPE      = var.enable_scheduler ? module.scheduler[0].scheduler_event_detail_type : ""
    SCHEDULER_API_DESTINATION_ARN    = var.enable_scheduler ? module.scheduler[0].scheduler_api_destination_arn : ""
    SCHEDULER_SERVICE_URL            = var.scheduler_api_destination_endpoint
    AUTH_PROVIDER                    = var.enable_cognito ? "cognito" : "firebase"
    COGNITO_USER_POOL_ID             = var.enable_cognito ? module.cognito[0].user_pool_id : ""
    COGNITO_REGION                   = data.aws_region.current.name
  }
}

output "service_account_annotation" {
  description = "Annotation for Kubernetes ServiceAccount"
  value = {
    "eks.amazonaws.com/role-arn" = module.iam.workloads_role_arn
  }
}
