# Local values
locals {
  name_prefix = "${var.project_name}-${var.environment}"

  # Extract OIDC provider URL from ARN
  oidc_provider_url = var.eks_oidc_provider_arn != "" ? replace(var.eks_oidc_provider_arn, "/^arn:aws:iam::[0-9]+:oidc-provider\\//", "") : ""

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
  }
}

# Data sources
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# ============================================
# KMS Key for Encryption
# ============================================
module "kms" {
  source = "./modules/kms"

  name_prefix      = local.name_prefix
  existing_key_arn = var.existing_kms_key_arn
  tags             = local.common_tags
}

# ============================================
# S3 Buckets
# ============================================
module "s3" {
  source = "./modules/s3"

  name_prefix                        = local.name_prefix
  force_destroy                      = var.s3_force_destroy
  versioning_enabled                 = var.s3_versioning_enabled
  noncurrent_version_expiration_days = var.s3_noncurrent_version_expiration_days
  tags                               = local.common_tags

  # Use existing buckets if specified
  existing_user_files_bucket        = var.existing_user_files_bucket
  existing_documents_bucket         = var.existing_documents_bucket
  existing_tenant_migrations_bucket = var.existing_tenant_migrations_bucket
}

# ============================================
# IAM Roles
# ============================================
module "iam" {
  source = "./modules/iam"

  name_prefix              = local.name_prefix
  eks_oidc_provider_arn    = var.eks_oidc_provider_arn
  eks_oidc_provider_url    = local.oidc_provider_url
  eks_namespace            = var.eks_namespace
  eks_service_account_name = var.eks_service_account_name

  # Resource ARNs for permissions
  kms_key_arn                   = module.kms.key_arn
  user_files_bucket_arn         = module.s3.user_files_bucket_arn
  documents_bucket_arn          = module.s3.documents_bucket_arn
  tenant_migrations_bucket_arn  = module.s3.tenant_migrations_bucket_arn
  cognito_user_pool_arn         = var.enable_cognito ? module.cognito[0].user_pool_arn : ""
  secrets_arn_prefix            = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${local.name_prefix}/*"

  enable_scheduler = var.enable_scheduler
  enable_cognito   = var.enable_cognito

  tags = local.common_tags
}

# ============================================
# EventBridge Scheduler
# ============================================
module "scheduler" {
  source = "./modules/scheduler"
  count  = var.enable_scheduler ? 1 : 0

  name_prefix    = local.name_prefix
  scheduler_role_arn = module.iam.scheduler_role_arn
  tags           = local.common_tags
}

# ============================================
# Cognito User Pool
# ============================================
module "cognito" {
  source = "./modules/cognito"
  count  = var.enable_cognito ? 1 : 0

  name_prefix    = local.name_prefix
  callback_urls  = var.cognito_callback_urls
  logout_urls    = var.cognito_logout_urls
  tags           = local.common_tags
}

# ============================================
# Secrets Manager
# ============================================
module "secrets" {
  source = "./modules/secrets"

  name_prefix = local.name_prefix
  kms_key_arn = module.kms.key_arn
  tags        = local.common_tags
}
