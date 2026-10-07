# ============================================
# SQS Task Queues
# ============================================
# Queues for the background task queue (TASK_QUEUE_PROVIDER=sqs).
#
# Cloud Tasks performs the HTTP request itself; SQS only holds bytes, so on AWS the
# worker pod polls these queues and makes the call each message describes. That is why
# every queue here needs a dead-letter queue: the consumer decides retry-or-delete per
# message, but what stops a permanently failing task retrying forever is the redrive
# policy, not the application.

variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "queues" {
  description = <<-EOT
    Queues to create, keyed by logical name. Each is created as
    "<name_prefix>-<key>", so one account can hold several environments.

    The application addresses queues by name, so the keys here must match the
    corresponding settings on the services -- see the queue_env_values output.
  EOT

  type = map(object({
    # Must exceed the consumer's SQS_HANDLER_TIMEOUT_SECONDS, or a message becomes
    # visible again while its handler is still working on it, which is how
    # at-least-once delivery turns into "ran twice at the same time". The consumer
    # also sets this per receive (handler timeout + 30); the queue value is the
    # fallback and is kept in step with it.
    visibility_timeout_seconds = optional(number, 630)

    # Attempts before the message is dead-lettered. Without a redrive policy a task
    # that always fails is redelivered indefinitely.
    max_receive_count = optional(number, 3)

    # Four days. Comfortably longer than max_receive_count * visibility_timeout, so
    # retention is never what ends an attempt.
    message_retention_seconds = optional(number, 345600)
  }))

  default = {
    "evaluation-cases"  = {}
    "webhook-processor" = {}
  }
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  # Dead-lettered tasks are evidence to be read, not traffic, so they are kept for the
  # maximum 14 days regardless of what the source queue retains.
  dlq_retention_seconds = 1209600
}

# ============================================
# Dead-letter queues
# ============================================
# Created first: a redrive policy references the DLQ by ARN.
resource "aws_sqs_queue" "dlq" {
  for_each = var.queues

  name = "${var.name_prefix}-${each.key}-dlq"

  message_retention_seconds = local.dlq_retention_seconds

  # SSE-SQS rather than a KMS CMK. A CMK would also require kms:Decrypt and
  # kms:GenerateDataKey on every role that touches the queue, for no benefit here --
  # the message carries ids and a callback URL, not customer content.
  sqs_managed_sse_enabled = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-${each.key}-dlq"
  })
}

# Only the matching source queue may dead-letter here, rather than any queue in the
# account that happens to name this ARN.
resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  for_each = var.queues

  queue_url = aws_sqs_queue.dlq[each.key].id

  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.task[each.key].arn]
  })
}

# ============================================
# Task queues
# ============================================
resource "aws_sqs_queue" "task" {
  for_each = var.queues

  name = "${var.name_prefix}-${each.key}"

  # Deliberately Standard, not FIFO. The provider sends no MessageGroupId or
  # MessageDeduplicationId, which a FIFO queue requires -- it would reject every
  # message. Ordering is not needed either: each task is independent, and duplicate
  # delivery is made harmless by the per-case primary key rather than by the queue.
  fifo_queue = false

  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = each.value.message_retention_seconds

  # Long poll, matching what the consumer asks for, so an idle queue costs one request
  # every 20s instead of a tight loop.
  receive_wait_time_seconds = 20

  sqs_managed_sse_enabled = true

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = each.value.max_receive_count
  })

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-${each.key}"
  })
}

# ============================================
# Outputs
# ============================================

output "queue_arns" {
  description = "ARNs of the task queues, for the IAM policy that grants access"
  value       = [for q in aws_sqs_queue.task : q.arn]
}

output "dlq_arns" {
  description = "ARNs of the dead-letter queues"
  value       = [for q in aws_sqs_queue.dlq : q.arn]
}

output "queue_urls" {
  description = "Queue URLs, keyed by logical name"
  value       = { for k, q in aws_sqs_queue.task : k => q.url }
}

output "queue_names" {
  description = "Actual queue names, keyed by logical name"
  value       = { for k, q in aws_sqs_queue.task : k => q.name }
}

output "queue_url_prefix" {
  description = <<-EOT
    Value for SQS_QUEUE_URL_PREFIX on the server and worker: the account's queue URL
    base, without a queue name. The provider appends "/<queue-name>" itself.
  EOT
  value       = "https://sqs.${data.aws_region.current.name}.amazonaws.com/${data.aws_caller_identity.current.account_id}"
}

output "queue_env_values" {
  description = <<-EOT
    The queue-name settings the services need. Queues are prefixed per environment, so
    the application defaults ("evaluation-cases", "webhook-processor") do not match
    and must be set explicitly.
  EOT
  value = {
    EVALUATION_QUEUE_NAME = try(aws_sqs_queue.task["evaluation-cases"].name, null)
    WEBHOOK_QUEUE_NAME    = try(aws_sqs_queue.task["webhook-processor"].name, null)
    SQS_CONSUMER_QUEUES   = join(",", [for q in aws_sqs_queue.task : q.name])
  }
}
