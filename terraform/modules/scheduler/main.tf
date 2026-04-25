variable "name_prefix" {
  description = "Prefix for resource names"
  type        = string
}

variable "scheduler_role_arn" {
  description = "IAM role ARN for scheduler"
  type        = string
}

variable "tags" {
  description = "Tags to apply to resources"
  type        = map(string)
  default     = {}
}

resource "aws_scheduler_schedule_group" "main" {
  name = "${var.name_prefix}-schedules"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-schedules"
  })
}

# Outputs
output "scheduler_group_name" {
  value = aws_scheduler_schedule_group.main.name
}

output "scheduler_group_arn" {
  value = aws_scheduler_schedule_group.main.arn
}
