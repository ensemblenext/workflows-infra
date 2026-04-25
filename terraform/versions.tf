terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Uncomment and configure for remote state
  # backend "s3" {
  #   bucket         = "your-terraform-state-bucket"
  #   key            = "workflows/terraform.tfstate"
  #   region         = "us-west-2"
  #   profile        = "ensemble"
  #   encrypt        = true
  #   dynamodb_table = "terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  # Use the ensemble profile for credentials
  # Set via: export AWS_PROFILE=ensemble
  # Or uncomment below:
  # profile = "ensemble"

  default_tags {
    tags = {
      Project     = "workflows"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
