#!/bin/bash
# Import existing AWS resources into Terraform state
# Usage: ./import-existing.sh [environment]
# Example: ./import-existing.sh prod

set -e

ENV="${1:-prod}"
VAR_FILE="environments/${ENV}.tfvars"

if [ ! -f "$VAR_FILE" ]; then
  echo "Error: $VAR_FILE not found"
  exit 1
fi

echo "Importing existing resources for environment: $ENV"

# Function to import a resource, ignoring if it doesn't exist or is already imported
import_resource() {
  local resource="$1"
  local id="$2"
  echo "Importing $resource..."
  terraform import -var-file="$VAR_FILE" "$resource" "$id" 2>/dev/null || true
}

# Get dynamic IDs
echo "Fetching resource IDs from AWS..."

USER_POOL_ID=$(aws cognito-idp list-user-pools --max-results 50 \
  --query "UserPools[?Name=='workflows-${ENV}-users'].Id" --output text 2>/dev/null || echo "")

KMS_KEY_ID=$(aws kms list-aliases \
  --query "Aliases[?AliasName=='alias/workflows-${ENV}-encryption-key'].TargetKeyId" --output text 2>/dev/null || echo "")

WEB_CLIENT_ID=$(aws cognito-idp list-user-pool-clients --user-pool-id "$USER_POOL_ID" \
  --query "UserPoolClients[?ClientName=='workflows-${ENV}-web-client'].ClientId" --output text 2>/dev/null || echo "")

# Import Cognito
if [ -n "$USER_POOL_ID" ]; then
  import_resource 'module.cognito[0].aws_cognito_user_pool.main' "$USER_POOL_ID"
  import_resource 'module.cognito[0].aws_cognito_user_pool_domain.main' "workflows-${ENV}-auth"
  if [ -n "$WEB_CLIENT_ID" ]; then
    import_resource 'module.cognito[0].aws_cognito_user_pool_client.web' "$USER_POOL_ID/$WEB_CLIENT_ID"
  fi
fi

# Import KMS
if [ -n "$KMS_KEY_ID" ]; then
  import_resource 'module.kms.aws_kms_key.main[0]' "$KMS_KEY_ID"
  import_resource 'module.kms.aws_kms_alias.main[0]' "alias/workflows-${ENV}-encryption-key"
fi

# Import IAM Roles
import_resource 'module.iam.aws_iam_role.scheduler' "workflows-${ENV}-scheduler-role"
import_resource 'module.iam.aws_iam_role.workloads' "workflows-${ENV}-workloads-role"

# Import S3 Buckets
import_resource 'module.s3.aws_s3_bucket.user_files[0]' "workflows-${ENV}-user-files"
import_resource 'module.s3.aws_s3_bucket.documents[0]' "workflows-${ENV}-documents"
import_resource 'module.s3.aws_s3_bucket.tenant_migrations[0]' "workflows-${ENV}-tenant-migrations"

# Import Scheduler
import_resource 'module.scheduler[0].aws_scheduler_schedule_group.main' "workflows-${ENV}-schedules"
import_resource 'module.scheduler[0].aws_cloudwatch_event_bus.scheduler' "workflows-${ENV}-scheduler-events"

# Import Secrets
import_resource 'module.secrets.aws_secretsmanager_secret.app_secrets' "workflows-${ENV}/app-secrets"

echo ""
echo "Import complete. Run 'terraform plan -var-file=$VAR_FILE' to see changes."
