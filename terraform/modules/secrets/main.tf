variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "kms_key_arn" {
  description = "KMS key ARN for encryption"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

resource "aws_secretsmanager_secret" "app_secrets" {
  name        = "${var.name_prefix}/app-secrets"
  description = "Application secrets for ${var.name_prefix}"
  kms_key_id  = var.kms_key_arn

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-app-secrets"
  })
}

# Initial secret version with placeholder values
# These should be updated manually or via CI/CD
resource "aws_secretsmanager_secret_version" "app_secrets" {
  secret_id = aws_secretsmanager_secret.app_secrets.id
  secret_string = jsonencode({
    ANTHROPIC_API_KEY          = ""
    OPENAI_API_KEY             = ""
    TEMPORAL_API_KEY           = ""
    TEMPORAL_ADDRESS           = ""
    TEMPORAL_NAMESPACE         = "default"
    SCHEDULER_CALLBACK_API_KEY = ""
    DATABASE_PASSWORD          = ""
    FIREBASE_PROJECT_ID        = ""
    FIREBASE_CLIENT_EMAIL      = ""
    FIREBASE_PRIVATE_KEY       = ""
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# Outputs
output "secret_arn" {
  value = aws_secretsmanager_secret.app_secrets.arn
}

output "secret_name" {
  value = aws_secretsmanager_secret.app_secrets.name
}
