variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}


variable "force_destroy" {
  description = "Allow destroying buckets with objects"
  type        = bool
  default     = false
}

variable "versioning_enabled" {
  description = "Enable versioning"
  type        = bool
  default     = true
}

variable "noncurrent_version_expiration_days" {
  description = "Days to keep noncurrent versions"
  type        = number
  default     = 90
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

# Existing bucket names (empty = create new)
variable "existing_user_files_bucket" {
  description = "Name of existing user files bucket"
  type        = string
  default     = ""
}

variable "existing_documents_bucket" {
  description = "Name of existing documents bucket"
  type        = string
  default     = ""
}

variable "existing_tenant_migrations_bucket" {
  description = "Name of existing tenant migrations bucket"
  type        = string
  default     = ""
}

locals {
  create_user_files_bucket         = var.existing_user_files_bucket == ""
  create_documents_bucket          = var.existing_documents_bucket == ""
  create_tenant_migrations_bucket  = var.existing_tenant_migrations_bucket == ""
}

# ============================================
# User Files Bucket
# ============================================

# Data source for existing bucket
data "aws_s3_bucket" "existing_user_files" {
  count  = local.create_user_files_bucket ? 0 : 1
  bucket = var.existing_user_files_bucket
}

# Create new bucket
resource "aws_s3_bucket" "user_files" {
  count         = local.create_user_files_bucket ? 1 : 0
  bucket        = "${var.name_prefix}-user-files"
  force_destroy = var.force_destroy

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-user-files"
  })
}

resource "aws_s3_bucket_versioning" "user_files" {
  count  = local.create_user_files_bucket ? 1 : 0
  bucket = aws_s3_bucket.user_files[0].id
  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "user_files" {
  count  = local.create_user_files_bucket ? 1 : 0
  bucket = aws_s3_bucket.user_files[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "user_files" {
  count  = local.create_user_files_bucket ? 1 : 0
  bucket = aws_s3_bucket.user_files[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "user_files" {
  count  = local.create_user_files_bucket ? 1 : 0
  bucket = aws_s3_bucket.user_files[0].id

  rule {
    id     = "delete-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "user_files" {
  count  = local.create_user_files_bucket ? 1 : 0
  bucket = aws_s3_bucket.user_files[0].id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST"]
    allowed_origins = ["*"] # Restrict in production
    max_age_seconds = 3000
  }
}

# ============================================
# Documents Bucket
# ============================================

# Data source for existing bucket
data "aws_s3_bucket" "existing_documents" {
  count  = local.create_documents_bucket ? 0 : 1
  bucket = var.existing_documents_bucket
}

# Create new bucket
resource "aws_s3_bucket" "documents" {
  count         = local.create_documents_bucket ? 1 : 0
  bucket        = "${var.name_prefix}-documents"
  force_destroy = var.force_destroy

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-documents"
  })
}

resource "aws_s3_bucket_versioning" "documents" {
  count  = local.create_documents_bucket ? 1 : 0
  bucket = aws_s3_bucket.documents[0].id
  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "documents" {
  count  = local.create_documents_bucket ? 1 : 0
  bucket = aws_s3_bucket.documents[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "documents" {
  count  = local.create_documents_bucket ? 1 : 0
  bucket = aws_s3_bucket.documents[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "documents" {
  count  = local.create_documents_bucket ? 1 : 0
  bucket = aws_s3_bucket.documents[0].id

  rule {
    id     = "delete-old-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }
  }
}

# ============================================
# Tenant Migrations Bucket
# ============================================

# Data source for existing bucket
data "aws_s3_bucket" "existing_tenant_migrations" {
  count  = local.create_tenant_migrations_bucket ? 0 : 1
  bucket = var.existing_tenant_migrations_bucket
}

# Create new bucket
resource "aws_s3_bucket" "tenant_migrations" {
  count         = local.create_tenant_migrations_bucket ? 1 : 0
  bucket        = "${var.name_prefix}-tenant-migrations"
  force_destroy = var.force_destroy

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-tenant-migrations"
  })
}

resource "aws_s3_bucket_versioning" "tenant_migrations" {
  count  = local.create_tenant_migrations_bucket ? 1 : 0
  bucket = aws_s3_bucket.tenant_migrations[0].id
  versioning_configuration {
    status = var.versioning_enabled ? "Enabled" : "Suspended"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tenant_migrations" {
  count  = local.create_tenant_migrations_bucket ? 1 : 0
  bucket = aws_s3_bucket.tenant_migrations[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tenant_migrations" {
  count  = local.create_tenant_migrations_bucket ? 1 : 0
  bucket = aws_s3_bucket.tenant_migrations[0].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ============================================
# Outputs
# ============================================

output "user_files_bucket_name" {
  value = local.create_user_files_bucket ? aws_s3_bucket.user_files[0].id : data.aws_s3_bucket.existing_user_files[0].id
}

output "user_files_bucket_arn" {
  value = local.create_user_files_bucket ? aws_s3_bucket.user_files[0].arn : data.aws_s3_bucket.existing_user_files[0].arn
}

output "documents_bucket_name" {
  value = local.create_documents_bucket ? aws_s3_bucket.documents[0].id : data.aws_s3_bucket.existing_documents[0].id
}

output "documents_bucket_arn" {
  value = local.create_documents_bucket ? aws_s3_bucket.documents[0].arn : data.aws_s3_bucket.existing_documents[0].arn
}

output "tenant_migrations_bucket_name" {
  value = local.create_tenant_migrations_bucket ? aws_s3_bucket.tenant_migrations[0].id : data.aws_s3_bucket.existing_tenant_migrations[0].id
}

output "tenant_migrations_bucket_arn" {
  value = local.create_tenant_migrations_bucket ? aws_s3_bucket.tenant_migrations[0].arn : data.aws_s3_bucket.existing_tenant_migrations[0].arn
}
