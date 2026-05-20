variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "eks_oidc_provider_arn" {
  description = "EKS OIDC provider ARN"
  type        = string
  default     = ""
}

variable "eks_oidc_provider_url" {
  description = "EKS OIDC provider URL (without https://)"
  type        = string
  default     = ""
}

variable "eks_namespace" {
  description = "Kubernetes namespace"
  type        = string
  default     = "workflows"
}

variable "eks_service_account_name" {
  description = "Kubernetes service account name"
  type        = string
  default     = "workflows-sa"
}

variable "kms_key_arn" {
  description = "KMS key ARN"
  type        = string
}

variable "user_files_bucket_arn" {
  description = "User files bucket ARN"
  type        = string
}

variable "documents_bucket_arn" {
  description = "Documents bucket ARN"
  type        = string
}

variable "tenant_migrations_bucket_arn" {
  description = "Tenant migrations bucket ARN"
  type        = string
}

variable "cognito_user_pool_arn" {
  description = "Cognito User Pool ARN"
  type        = string
  default     = ""
}

variable "secrets_arn_prefix" {
  description = "Secrets Manager ARN prefix"
  type        = string
}

variable "enable_scheduler" {
  description = "Enable scheduler permissions"
  type        = bool
  default     = true
}

variable "enable_cognito" {
  description = "Enable Cognito permissions"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  scheduler_schedule_group_arn = "arn:aws:scheduler:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:schedule-group/${var.name_prefix}-schedules"
  scheduler_event_bus_arn      = "arn:aws:events:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:event-bus/${var.name_prefix}-scheduler-events"
}

# ============================================
# Scheduler Role
# ============================================
resource "aws_iam_role" "scheduler" {
  name = "${var.name_prefix}-scheduler-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "scheduler.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-scheduler-role"
  })
}

resource "aws_iam_role_policy" "scheduler" {
  name = "${var.name_prefix}-scheduler-policy"
  role = aws_iam_role.scheduler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "InvokeTargets"
        Effect = "Allow"
        Action = [
          "lambda:InvokeFunction",
          "states:StartExecution"
        ]
        Resource = "*"
      },
      {
        Sid      = "PutScheduledEvents"
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = local.scheduler_event_bus_arn
      }
    ]
  })
}

# ============================================
# Workloads Role (IRSA or EC2)
# ============================================
resource "aws_iam_role" "workloads" {
  name = "${var.name_prefix}-workloads-role"

  assume_role_policy = var.eks_oidc_provider_arn != "" ? jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = var.eks_oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${var.eks_oidc_provider_url}:aud" = "sts.amazonaws.com"
            "${var.eks_oidc_provider_url}:sub" = "system:serviceaccount:${var.eks_namespace}:${var.eks_service_account_name}"
          }
        }
      }
    ]
    }) : jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-workloads-role"
  })
}

# S3 Policy
resource "aws_iam_role_policy" "workloads_s3" {
  name = "${var.name_prefix}-workloads-s3-policy"
  role = aws_iam_role.workloads.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3ReadWrite"
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = [
          var.user_files_bucket_arn,
          "${var.user_files_bucket_arn}/*",
          var.documents_bucket_arn,
          "${var.documents_bucket_arn}/*",
          var.tenant_migrations_bucket_arn,
          "${var.tenant_migrations_bucket_arn}/*"
        ]
      }
    ]
  })
}

# KMS Policy
resource "aws_iam_role_policy" "workloads_kms" {
  name = "${var.name_prefix}-workloads-kms-policy"
  role = aws_iam_role.workloads.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "KMSEncryptDecrypt"
        Effect = "Allow"
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:GenerateDataKey",
          "kms:GenerateDataKeyWithoutPlaintext",
          "kms:DescribeKey"
        ]
        Resource = var.kms_key_arn
      }
    ]
  })
}

# Scheduler Policy
resource "aws_iam_role_policy" "workloads_scheduler" {
  count = var.enable_scheduler ? 1 : 0
  name  = "${var.name_prefix}-workloads-scheduler-policy"
  role  = aws_iam_role.workloads.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SchedulerManagement"
        Effect = "Allow"
        Action = [
          "scheduler:CreateSchedule",
          "scheduler:GetSchedule",
          "scheduler:UpdateSchedule",
          "scheduler:DeleteSchedule"
        ]
        Resource = [
          "arn:aws:scheduler:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:schedule/${var.name_prefix}-schedules/*",
          "arn:aws:scheduler:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:schedule/default/*"
        ]
      },
      {
        Sid      = "SchedulerGroupRead"
        Effect   = "Allow"
        Action   = "scheduler:GetScheduleGroup"
        Resource = local.scheduler_schedule_group_arn
      },
      {
        Sid    = "SchedulerList"
        Effect = "Allow"
        Action = [
          "scheduler:ListSchedules",
          "scheduler:ListScheduleGroups"
        ]
        Resource = "*"
      },
      {
        Sid      = "PassSchedulerRole"
        Effect   = "Allow"
        Action   = "iam:PassRole"
        Resource = aws_iam_role.scheduler.arn
        Condition = {
          StringEquals = {
            "iam:PassedToService" = "scheduler.amazonaws.com"
          }
        }
      }
    ]
  })
}

# Cognito Policy
resource "aws_iam_role_policy" "workloads_cognito" {
  count = var.enable_cognito ? 1 : 0
  name  = "${var.name_prefix}-workloads-cognito-policy"
  role  = aws_iam_role.workloads.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CognitoUserManagement"
        Effect = "Allow"
        Action = [
          "cognito-idp:AdminGetUser",
          "cognito-idp:AdminCreateUser",
          "cognito-idp:AdminUpdateUserAttributes",
          "cognito-idp:AdminDisableUser",
          "cognito-idp:AdminEnableUser",
          "cognito-idp:ListUsers"
        ]
        Resource = var.cognito_user_pool_arn
      }
    ]
  })
}

# Secrets Manager Policy
resource "aws_iam_role_policy" "workloads_secrets" {
  name = "${var.name_prefix}-workloads-secrets-policy"
  role = aws_iam_role.workloads.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SecretsManagerAccess"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = var.secrets_arn_prefix
      }
    ]
  })
}

# Bedrock Policy
resource "aws_iam_role_policy" "workloads_bedrock" {
  name = "${var.name_prefix}-workloads-bedrock-policy"
  role = aws_iam_role.workloads.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "BedrockInvokeModel"
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = [
          "arn:aws:bedrock:*::foundation-model/*",
          "arn:aws:bedrock:*:${data.aws_caller_identity.current.account_id}:inference-profile/*"
        ]
      },
      {
        Sid    = "BedrockListModels"
        Effect = "Allow"
        Action = [
          "bedrock:ListFoundationModels",
          "bedrock:GetFoundationModel"
        ]
        Resource = "*"
      }
    ]
  })
}

# Outputs
output "workloads_role_arn" {
  value = aws_iam_role.workloads.arn
}

output "workloads_role_name" {
  value = aws_iam_role.workloads.name
}

output "scheduler_role_arn" {
  value = aws_iam_role.scheduler.arn
}

output "scheduler_role_name" {
  value = aws_iam_role.scheduler.name
}
