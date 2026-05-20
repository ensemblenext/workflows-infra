variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "callback_urls" {
  description = "Allowed callback URLs"
  type        = list(string)
  default     = ["http://localhost:3000/auth/callback"]
}

variable "logout_urls" {
  description = "Allowed logout URLs"
  type        = list(string)
  default     = ["http://localhost:3000"]
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

variable "enable_scheduler_oauth" {
  description = "Enable OAuth client for EventBridge Scheduler M2M authentication"
  type        = bool
  default     = false
}

variable "google_client_id" {
  description = "Google OAuth Client ID"
  type        = string
  default     = ""
}

variable "google_client_secret" {
  description = "Google OAuth Client Secret"
  type        = string
  default     = ""
  sensitive   = true
}

variable "scheduler_api_identifier" {
  description = "Resource server identifier for scheduler API (e.g., https://api.example.com)"
  type        = string
  default     = ""
}

# Data sources
data "aws_region" "current" {}

resource "aws_cognito_user_pool" "main" {
  name = "${var.name_prefix}-users"

  # Sign-in configuration
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  # Password policy
  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = true
    require_numbers                  = true
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # Account recovery
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # User attributes
  schema {
    name                     = "email"
    attribute_data_type      = "String"
    mutable                  = true
    required                 = true
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 1
      max_length = 256
    }
  }

  schema {
    name                     = "name"
    attribute_data_type      = "String"
    mutable                  = true
    required                 = false
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 0
      max_length = 256
    }
  }

  # Email configuration (use Cognito default)
  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  # Verification message
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Your verification code"
    email_message        = "Your verification code is {####}"
  }

  # MFA (optional - enable for production)
  mfa_configuration = "OFF"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-user-pool"
  })
}

# User Pool Client (for web/SPA)
resource "aws_cognito_user_pool_client" "web" {
  name         = "${var.name_prefix}-web-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # No client secret for SPA
  generate_secret = false

  # Auth flows
  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH"
  ]

  # OAuth configuration
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["email", "openid", "profile"]
  supported_identity_providers         = var.google_client_id != "" ? ["COGNITO", "Google"] : ["COGNITO"]

  callback_urls = var.callback_urls
  logout_urls   = var.logout_urls

  depends_on = [aws_cognito_identity_provider.google]

  # Token validity
  access_token_validity  = 1  # hours
  id_token_validity      = 1  # hours
  refresh_token_validity = 30 # days

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Security
  prevent_user_existence_errors = "ENABLED"

  # Read/write attributes
  read_attributes  = ["email", "name", "email_verified"]
  write_attributes = ["email", "name"]
}

# User Pool Domain (for hosted UI)
resource "aws_cognito_user_pool_domain" "main" {
  domain       = "${var.name_prefix}-auth"
  user_pool_id = aws_cognito_user_pool.main.id
}

# Google Identity Provider
resource "aws_cognito_identity_provider" "google" {
  count = var.google_client_id != "" ? 1 : 0

  user_pool_id  = aws_cognito_user_pool.main.id
  provider_name = "Google"
  provider_type = "Google"

  provider_details = {
    client_id                     = var.google_client_id
    client_secret                 = var.google_client_secret
    authorize_scopes              = "email profile openid"
    attributes_url                = "https://people.googleapis.com/v1/people/me?personFields="
    attributes_url_add_attributes = "true"
    authorize_url                 = "https://accounts.google.com/o/oauth2/v2/auth"
    oidc_issuer                   = "https://accounts.google.com"
    token_request_method          = "POST"
    token_url                     = "https://www.googleapis.com/oauth2/v4/token"
  }

  attribute_mapping = {
    email    = "email"
    name     = "name"
    username = "sub"
  }
}

# ============================================
# Scheduler OAuth (M2M) Resources
# ============================================

# Resource Server for Scheduler API
resource "aws_cognito_resource_server" "scheduler_api" {
  count = var.enable_scheduler_oauth ? 1 : 0

  identifier   = var.scheduler_api_identifier
  name         = "${var.name_prefix}-scheduler-api"
  user_pool_id = aws_cognito_user_pool.main.id

  scope {
    scope_name        = "scheduler.trigger"
    scope_description = "Trigger scheduled evaluations"
  }
}

# M2M App Client for EventBridge Scheduler
resource "aws_cognito_user_pool_client" "eventbridge_scheduler" {
  count = var.enable_scheduler_oauth ? 1 : 0

  name         = "${var.name_prefix}-eventbridge-scheduler"
  user_pool_id = aws_cognito_user_pool.main.id

  # M2M requires client secret
  generate_secret = true

  # Client credentials flow for M2M
  explicit_auth_flows                  = []
  allowed_oauth_flows                  = ["client_credentials"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes = [
    "${aws_cognito_resource_server.scheduler_api[0].identifier}/scheduler.trigger"
  ]
  supported_identity_providers = ["COGNITO"]

  # Token validity for M2M
  access_token_validity = 1 # hours

  token_validity_units {
    access_token = "hours"
  }
}

# Outputs
output "user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "user_pool_arn" {
  value = aws_cognito_user_pool.main.arn
}

output "user_pool_client_id" {
  value = aws_cognito_user_pool_client.web.id
}

output "user_pool_domain" {
  value = aws_cognito_user_pool_domain.main.domain
}

output "user_pool_endpoint" {
  value = aws_cognito_user_pool.main.endpoint
}

# Scheduler OAuth outputs
output "scheduler_oauth_client_id" {
  description = "Client ID for EventBridge Scheduler OAuth"
  value       = var.enable_scheduler_oauth ? aws_cognito_user_pool_client.eventbridge_scheduler[0].id : ""
}

output "scheduler_oauth_client_secret" {
  description = "Client secret for EventBridge Scheduler OAuth"
  value       = var.enable_scheduler_oauth ? aws_cognito_user_pool_client.eventbridge_scheduler[0].client_secret : ""
  sensitive   = true
}

output "scheduler_oauth_token_endpoint" {
  description = "OAuth token endpoint for EventBridge Scheduler"
  value       = var.enable_scheduler_oauth ? "https://${aws_cognito_user_pool_domain.main.domain}.auth.${data.aws_region.current.name}.amazoncognito.com/oauth2/token" : ""
}

output "scheduler_oauth_scope" {
  description = "OAuth scope for EventBridge Scheduler"
  value       = var.enable_scheduler_oauth ? "${var.scheduler_api_identifier}/scheduler.trigger" : ""
}
