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

  # Retention model (applied uniformly to all repos; each rule is a no-op where
  # it does not apply):
  #   - Immutable release tags "1.1.<build>" are matched by NO rule, so they are
  #     kept forever.
  #   - Helm dev charts "1.1.<build>-dev" stay tagged after "latest" moves off
  #     them, so rule 1 prunes them by the "-dev" suffix (tagPatternList) to the
  #     last N. (Only the chart repo has these; no-op elsewhere.)
  #   - Superseded "latest" IMAGE builds lose their only tag and become
  #     untagged, so rule 2 prunes them to the last N. (Image repos; the chart
  #     repo keeps its "-dev" tag so it has ~no untagged images.)
  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Keep only the last ${var.image_count_to_keep} pre-release '-dev' images (Helm dev charts); tagged releases match no rule and are kept forever"
        selection = {
          tagStatus      = "tagged"
          tagPatternList = ["*-dev"]
          countType      = "imageCountMoreThan"
          countNumber    = var.image_count_to_keep
        }
        action = {
          type = "expire"
        }
      },
      {
        rulePriority = 2
        description  = "Keep only the last ${var.image_count_to_keep} untagged images (superseded 'latest' builds)"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = var.image_count_to_keep
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
