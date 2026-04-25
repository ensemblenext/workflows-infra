variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "existing_key_arn" {
  description = "ARN of existing KMS key (leave empty to create new)"
  type        = string
  default     = ""
}

locals {
  create_key = var.existing_key_arn == ""
}

# Data source for existing key
data "aws_kms_key" "existing" {
  count  = local.create_key ? 0 : 1
  key_id = var.existing_key_arn
}

# Create new key
resource "aws_kms_key" "main" {
  count                   = local.create_key ? 1 : 0
  description             = "KMS key for ${var.name_prefix} encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-encryption-key"
  })
}

resource "aws_kms_alias" "main" {
  count         = local.create_key ? 1 : 0
  name          = "alias/${var.name_prefix}-encryption-key"
  target_key_id = aws_kms_key.main[0].key_id
}

output "key_arn" {
  description = "KMS key ARN"
  value       = local.create_key ? aws_kms_key.main[0].arn : data.aws_kms_key.existing[0].arn
}

output "key_id" {
  description = "KMS key ID"
  value       = local.create_key ? aws_kms_key.main[0].key_id : data.aws_kms_key.existing[0].key_id
}

output "key_alias" {
  description = "KMS key alias"
  value       = local.create_key ? aws_kms_alias.main[0].name : "existing-key"
}
