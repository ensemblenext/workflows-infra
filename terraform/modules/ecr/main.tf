# ECR Repositories with lifecycle policies

locals {
  repositories = ["server", "web", "worker", "migration", "chart"]
}

resource "aws_ecr_repository" "repos" {
  for_each = toset(local.repositories)

  name                 = "${var.repository_prefix}/${each.key}"
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = var.scan_on_push
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "repos" {
  for_each = aws_ecr_repository.repos

  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last ${var.image_count_to_keep} 'latest' tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["latest"]
          countType     = "imageCountMoreThan"
          countNumber   = var.image_count_to_keep
        }
        action = {
          type = "expire"
        }
      }
    ]
  })
}

# Outputs
output "repository_urls" {
  description = "Map of repository names to URLs"
  value = {
    for name, repo in aws_ecr_repository.repos : name => repo.repository_url
  }
}

output "registry_id" {
  description = "The registry ID"
  value       = values(aws_ecr_repository.repos)[0].registry_id
}
