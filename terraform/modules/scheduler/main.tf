variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "scheduler_role_arn" {
  description = "IAM role ARN for scheduler"
  type        = string
}

variable "api_destination_endpoint" {
  description = "HTTPS endpoint invoked when a schedule fires. Leave empty to skip API destination resources."
  type        = string
  default     = ""

  validation {
    condition     = var.api_destination_endpoint == "" || startswith(var.api_destination_endpoint, "https://")
    error_message = "api_destination_endpoint must be empty or an https:// URL."
  }
}

variable "api_destination_http_method" {
  description = "HTTP method used to invoke the scheduler callback API"
  type        = string
  default     = "POST"

  validation {
    condition     = contains(["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"], var.api_destination_http_method)
    error_message = "api_destination_http_method must be a valid API Destination HTTP method."
  }
}

variable "api_destination_invocation_rate_limit_per_second" {
  description = "Maximum invocations per second for the API destination"
  type        = number
  default     = 50
}

variable "api_destination_auth_type" {
  description = "Authorization type for the API destination connection. Supported values: API_KEY, BASIC, OAUTH_CLIENT_CREDENTIALS."
  type        = string
  default     = "API_KEY"

  validation {
    condition     = contains(["API_KEY", "BASIC", "OAUTH_CLIENT_CREDENTIALS"], var.api_destination_auth_type)
    error_message = "api_destination_auth_type must be API_KEY, BASIC, or OAUTH_CLIENT_CREDENTIALS."
  }
}

variable "api_destination_api_key_name" {
  description = "API key header name when api_destination_auth_type is API_KEY"
  type        = string
  default     = "x-api-key"
}

variable "api_destination_api_key_value" {
  description = "API key value when api_destination_auth_type is API_KEY"
  type        = string
  default     = ""
  sensitive   = true
}

variable "api_destination_basic_username" {
  description = "Basic auth username when api_destination_auth_type is BASIC"
  type        = string
  default     = ""
  sensitive   = true
}

variable "api_destination_basic_password" {
  description = "Basic auth password when api_destination_auth_type is BASIC"
  type        = string
  default     = ""
  sensitive   = true
}

variable "api_destination_oauth_authorization_endpoint" {
  description = "OAuth token endpoint when api_destination_auth_type is OAUTH_CLIENT_CREDENTIALS"
  type        = string
  default     = ""

  validation {
    condition     = var.api_destination_oauth_authorization_endpoint == "" || startswith(var.api_destination_oauth_authorization_endpoint, "https://")
    error_message = "api_destination_oauth_authorization_endpoint must be empty or an https:// URL."
  }
}

variable "api_destination_oauth_http_method" {
  description = "HTTP method used for the OAuth token request"
  type        = string
  default     = "POST"

  validation {
    condition     = contains(["GET", "POST", "PUT"], var.api_destination_oauth_http_method)
    error_message = "api_destination_oauth_http_method must be GET, POST, or PUT."
  }
}

variable "api_destination_oauth_client_id" {
  description = "OAuth client ID when api_destination_auth_type is OAUTH_CLIENT_CREDENTIALS"
  type        = string
  default     = ""
  sensitive   = true
}

variable "api_destination_oauth_client_secret" {
  description = "OAuth client secret when api_destination_auth_type is OAUTH_CLIENT_CREDENTIALS"
  type        = string
  default     = ""
  sensitive   = true
}

variable "api_destination_oauth_http_parameters" {
  description = "Optional OAuth token request parameters for EventBridge Connection"
  type = object({
    body = optional(list(object({
      key             = string
      value           = string
      is_value_secret = optional(bool, false)
    })), [])
    header = optional(list(object({
      key             = string
      value           = string
      is_value_secret = optional(bool, false)
    })), [])
    query_string = optional(list(object({
      key             = string
      value           = string
      is_value_secret = optional(bool, false)
    })), [])
  })
  default = {}
}

variable "event_source" {
  description = "EventBridge source value schedules must use when putting scheduled callback events"
  type        = string
  default     = "workflows.scheduler"
}

variable "event_detail_type" {
  description = "EventBridge detail-type value schedules must use when putting scheduled callback events"
  type        = string
  default     = "ScheduledWorkflow"
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

locals {
  api_destination_enabled = var.api_destination_endpoint != ""
}

resource "aws_scheduler_schedule_group" "main" {
  name = "${var.name_prefix}-schedules"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-schedules"
  })
}

resource "aws_cloudwatch_event_bus" "scheduler" {
  name = "${var.name_prefix}-scheduler-events"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-scheduler-events"
  })
}

resource "aws_cloudwatch_event_connection" "scheduler_api" {
  count = local.api_destination_enabled ? 1 : 0

  name               = "${var.name_prefix}-scheduler-api"
  description        = "Credentials for scheduled workflow API callbacks"
  authorization_type = var.api_destination_auth_type

  auth_parameters {
    dynamic "api_key" {
      for_each = var.api_destination_auth_type == "API_KEY" ? [1] : []

      content {
        key   = var.api_destination_api_key_name
        value = var.api_destination_api_key_value
      }
    }

    dynamic "basic" {
      for_each = var.api_destination_auth_type == "BASIC" ? [1] : []

      content {
        username = var.api_destination_basic_username
        password = var.api_destination_basic_password
      }
    }

    dynamic "oauth" {
      for_each = var.api_destination_auth_type == "OAUTH_CLIENT_CREDENTIALS" ? [1] : []

      content {
        authorization_endpoint = var.api_destination_oauth_authorization_endpoint
        http_method            = var.api_destination_oauth_http_method

        client_parameters {
          client_id     = var.api_destination_oauth_client_id
          client_secret = var.api_destination_oauth_client_secret
        }

        oauth_http_parameters {
          dynamic "body" {
            for_each = var.api_destination_oauth_http_parameters.body

            content {
              key             = body.value.key
              value           = body.value.value
              is_value_secret = body.value.is_value_secret
            }
          }

          dynamic "header" {
            for_each = var.api_destination_oauth_http_parameters.header

            content {
              key             = header.value.key
              value           = header.value.value
              is_value_secret = header.value.is_value_secret
            }
          }

          dynamic "query_string" {
            for_each = var.api_destination_oauth_http_parameters.query_string

            content {
              key             = query_string.value.key
              value           = query_string.value.value
              is_value_secret = query_string.value.is_value_secret
            }
          }
        }
      }
    }
  }

  lifecycle {
    precondition {
      condition     = var.api_destination_auth_type != "API_KEY" || (var.api_destination_api_key_name != "" && var.api_destination_api_key_value != "")
      error_message = "API_KEY scheduler API destinations require api_destination_api_key_name and api_destination_api_key_value."
    }

    precondition {
      condition     = var.api_destination_auth_type != "BASIC" || (var.api_destination_basic_username != "" && var.api_destination_basic_password != "")
      error_message = "BASIC scheduler API destinations require api_destination_basic_username and api_destination_basic_password."
    }

    precondition {
      condition     = var.api_destination_auth_type != "OAUTH_CLIENT_CREDENTIALS" || (var.api_destination_oauth_authorization_endpoint != "" && var.api_destination_oauth_client_id != "" && var.api_destination_oauth_client_secret != "")
      error_message = "OAUTH_CLIENT_CREDENTIALS scheduler API destinations require api_destination_oauth_authorization_endpoint, api_destination_oauth_client_id, and api_destination_oauth_client_secret."
    }
  }
}

resource "aws_cloudwatch_event_api_destination" "scheduler_api" {
  count = local.api_destination_enabled ? 1 : 0

  name                             = "${var.name_prefix}-scheduler-api"
  description                      = "Scheduled workflow API callback endpoint"
  invocation_endpoint              = var.api_destination_endpoint
  http_method                      = var.api_destination_http_method
  invocation_rate_limit_per_second = var.api_destination_invocation_rate_limit_per_second
  connection_arn                   = aws_cloudwatch_event_connection.scheduler_api[0].arn
}

resource "aws_iam_role" "eventbridge_api_destination" {
  count = local.api_destination_enabled ? 1 : 0

  name = "${var.name_prefix}-eventbridge-api-destination-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-eventbridge-api-destination-role"
  })
}

resource "aws_iam_role_policy" "eventbridge_api_destination" {
  count = local.api_destination_enabled ? 1 : 0

  name = "${var.name_prefix}-eventbridge-api-destination-policy"
  role = aws_iam_role.eventbridge_api_destination[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "InvokeSchedulerApiDestination"
        Effect   = "Allow"
        Action   = "events:InvokeApiDestination"
        Resource = aws_cloudwatch_event_api_destination.scheduler_api[0].arn
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "scheduler_api" {
  count = local.api_destination_enabled ? 1 : 0

  name           = "${var.name_prefix}-scheduler-api"
  description    = "Routes scheduled workflow events to the API destination"
  event_bus_name = aws_cloudwatch_event_bus.scheduler.name
  event_pattern = jsonencode({
    source        = [var.event_source]
    "detail-type" = [var.event_detail_type]
  })

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-scheduler-api"
  })
}

resource "aws_cloudwatch_event_target" "scheduler_api" {
  count = local.api_destination_enabled ? 1 : 0

  rule           = aws_cloudwatch_event_rule.scheduler_api[0].name
  event_bus_name = aws_cloudwatch_event_bus.scheduler.name
  target_id      = "scheduler-api"
  arn            = aws_cloudwatch_event_api_destination.scheduler_api[0].arn
  role_arn       = aws_iam_role.eventbridge_api_destination[0].arn

  input_transformer {
    input_paths = {
      detail = "$.detail"
    }
    input_template = "<detail>"
  }
}

# Outputs
output "scheduler_group_name" {
  value = aws_scheduler_schedule_group.main.name
}

output "scheduler_group_arn" {
  value = aws_scheduler_schedule_group.main.arn
}

output "scheduler_event_bus_name" {
  value = aws_cloudwatch_event_bus.scheduler.name
}

output "scheduler_event_bus_arn" {
  value = aws_cloudwatch_event_bus.scheduler.arn
}

output "scheduler_api_destination_arn" {
  value = local.api_destination_enabled ? aws_cloudwatch_event_api_destination.scheduler_api[0].arn : ""
}

output "scheduler_event_source" {
  value = var.event_source
}

output "scheduler_event_detail_type" {
  value = var.event_detail_type
}
