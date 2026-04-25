# Workflows AWS Terraform Infrastructure

This Terraform configuration provisions supporting AWS resources for the Workflows platform. **Note:** This does not create the EKS cluster itself - see [EKS Cluster Setup](#eks-cluster-setup) below.

## Resources Created

### Storage (S3)
- **User Files Bucket** - For user-uploaded files
- **Documents Bucket** - For processed documents
- **Tenant Migrations Bucket** - For tenant data migrations

### Security
- **KMS Key** - For encryption at rest (secrets)
- **IAM Role (Workloads)** - For EKS pods via IRSA
- **IAM Role (Scheduler)** - For EventBridge Scheduler

### Scheduler
- **EventBridge Scheduler Group** - For cron jobs

### Authentication (Optional)
- **Cognito User Pool** - For user authentication
- **Cognito User Pool Client** - Web/SPA client

### Secrets
- **Secrets Manager Secret** - Template for app secrets

## Prerequisites

1. AWS CLI configured with the `ensemble` profile
2. Terraform 1.5+ installed
3. [eksctl](https://eksctl.io/) installed (for EKS cluster creation)

### AWS Profile Setup

Ensure you have the `ensemble` profile configured in `~/.aws/credentials`:

```bash
[ensemble]
aws_access_key_id = YOUR_ACCESS_KEY
aws_secret_access_key = YOUR_SECRET_KEY
```

Or configure via AWS CLI:

```bash
aws configure --profile ensemble
```

## Deployment Order

1. **Create EKS cluster** (see [EKS Cluster Setup](#eks-cluster-setup))
2. **Install AWS Load Balancer Controller** (see [AWS Load Balancer Controller](#aws-load-balancer-controller))
3. **Run Terraform** to create supporting resources
4. **Deploy Helm chart** to the EKS cluster

## EKS Cluster Setup

Create an EKS cluster with OIDC provider enabled using eksctl:

```bash
export AWS_PROFILE=ensemble
export CLUSTER_NAME=workflows-prod
export AWS_REGION=us-west-2

# Create cluster with OIDC provider
eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --version 1.35 \
  --nodegroup-name workflows-nodes \
  --node-type t3.medium \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 4 \
  --managed \
  --with-oidc
```

After cluster creation, get the OIDC provider ARN:

```bash
# Get OIDC issuer URL
OIDC_URL=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --profile ensemble \
  --query "cluster.identity.oidc.issuer" \
  --output text)

# Get AWS account ID
ACCOUNT_ID=$(aws sts get-caller-identity --profile ensemble --query "Account" --output text)

# Construct OIDC provider ARN
OIDC_PROVIDER_ARN="arn:aws:iam::${ACCOUNT_ID}:oidc-provider/${OIDC_URL#https://}"

echo "OIDC Provider ARN: $OIDC_PROVIDER_ARN"
```

Save this ARN for the Terraform configuration.

## AWS Load Balancer Controller

The AWS Load Balancer Controller is required to provision ALB for the Ingress. Install it using eksctl and Helm:

```bash
export AWS_PROFILE=ensemble
export CLUSTER_NAME=workflows-prod
export AWS_REGION=us-west-2

# Create IAM service account for the controller
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$AWS_REGION \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess \
  --approve

# Add the EKS Helm repo
helm repo add eks https://aws.github.io/eks-charts
helm repo update

# Install the controller
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# Verify installation
kubectl get deployment -n kube-system aws-load-balancer-controller
```

## Quick Start

After creating the EKS cluster:

```bash
cd infrastructure/terraform

# Set AWS profile for all commands
export AWS_PROFILE=ensemble

# Initialize Terraform
terraform init

# Copy and customize variables
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars and set eks_oidc_provider_arn

# Plan deployment
terraform plan -var-file=environments/prod.tfvars

# Apply
terraform apply -var-file=environments/prod.tfvars
```

## Configuration

### Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `aws_region` | AWS region | `us-west-2` |
| `environment` | Environment name (dev, staging, prod) | `dev` |
| `project_name` | Project name prefix | `workflows` |
| `eks_cluster_name` | EKS cluster name | - |
| `eks_oidc_provider_arn` | EKS OIDC provider ARN for IRSA | - |
| `eks_namespace` | Kubernetes namespace | `workflows` |
| `eks_service_account_name` | K8s service account name | `workflows-sa` |
| `enable_cognito` | Enable Cognito resources | `true` |
| `enable_scheduler` | Enable Scheduler resources | `true` |
| `s3_force_destroy` | Allow destroying non-empty buckets | `false` |
| `s3_versioning_enabled` | Enable S3 versioning | `true` |

### Using Existing Resources

If you already have S3 buckets or a KMS key, you can reference them instead of creating new ones:

| Variable | Description | Default |
|----------|-------------|---------|
| `existing_kms_key_arn` | ARN of existing KMS key | `""` (create new) |
| `existing_user_files_bucket` | Name of existing user files bucket | `""` (create new) |
| `existing_documents_bucket` | Name of existing documents bucket | `""` (create new) |
| `existing_tenant_migrations_bucket` | Name of existing migrations bucket | `""` (create new) |

Example usage with existing resources:

```hcl
# terraform.tfvars

# Use existing KMS key
existing_kms_key_arn = "arn:aws:kms:us-west-2:123456789012:key/12345678-1234-1234-1234-123456789012"

# Use existing S3 buckets
existing_user_files_bucket        = "my-company-user-files"
existing_documents_bucket         = "my-company-documents"
existing_tenant_migrations_bucket = "my-company-migrations"
```

When using existing resources:
- Terraform will **not** manage the lifecycle of these resources
- You are responsible for ensuring proper encryption and access policies
- IAM policies will still be created to grant access to these resources

## Environment-Specific Deployments

```bash
# Set AWS profile
export AWS_PROFILE=ensemble

# Development
terraform plan -var-file=environments/dev.tfvars
terraform apply -var-file=environments/dev.tfvars

# Production
terraform plan -var-file=environments/prod.tfvars
terraform apply -var-file=environments/prod.tfvars
```

## Remote State (Recommended)

For production, configure remote state in `versions.tf`:

```hcl
terraform {
  backend "s3" {
    bucket         = "your-terraform-state-bucket"
    key            = "workflows/terraform.tfstate"
    region         = "us-west-2"
    profile        = "ensemble"
    encrypt        = true
    dynamodb_table = "terraform-locks"
  }
}
```

## Outputs

After deployment, the following outputs are available:

| Output | Description |
|--------|-------------|
| `user_files_bucket_name` | S3 bucket for user files |
| `documents_bucket_name` | S3 bucket for documents |
| `tenant_migrations_bucket_name` | S3 bucket for migrations |
| `kms_key_arn` | KMS key ARN |
| `scheduler_role_arn` | EventBridge Scheduler role ARN |
| `workloads_role_arn` | EKS workloads role ARN |
| `cognito_user_pool_id` | Cognito User Pool ID |
| `cognito_user_pool_client_id` | Cognito Client ID |
| `helm_config_values` | Map of environment variables for Helm |
| `service_account_annotation` | K8s ServiceAccount annotation for IRSA |

View outputs:

```bash
terraform output
terraform output helm_config_values
terraform output -json > outputs.json
```

## Helm Integration

After deployment, update your Helm values:

```yaml
# eks-values.yaml
config:
  CLOUD_PROVIDER: "aws"
  AWS_REGION: "us-west-2"
  SERVERLESS_ENVIRONMENT: "false"

  # Storage
  STORAGE_USER_FILES_BUCKET: "example-workflows-user-files"
  STORAGE_DOCUMENTS_BUCKET: "example-workflows-documents"
  STORAGE_TENANT_MIGRATIONS_BUCKET: "example-workflows-tenant-migrations"

  # Encryption
  KMS_KEY_ARN: "arn:aws:kms:us-west-2:123456789:key/xxx"

  # Scheduler
  SCHEDULER_ROLE_ARN: "arn:aws:iam::123456789:role/workflows-prod-scheduler-role"
  SCHEDULER_GROUP_NAME: "workflows-prod-schedules"

  # Auth (if using Cognito)
  AUTH_PROVIDER: "cognito"
  COGNITO_USER_POOL_ID: "us-west-2_xxxxx"
  COGNITO_REGION: "us-west-2"

serviceAccount:
  create: true
  name: workflows-sa
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::123456789:role/workflows-prod-workloads-role"
```

## Secrets Setup

After deployment, update the Secrets Manager secret with actual values:

```bash
aws secretsmanager put-secret-value \
  --profile ensemble \
  --secret-id workflows-prod/app-secrets \
  --secret-string '{
    "ANTHROPIC_API_KEY": "sk-ant-xxx",
    "OPENAI_API_KEY": "sk-xxx",
    "TEMPORAL_API_KEY": "xxx",
    "TEMPORAL_ADDRESS": "xxx.tmprl.cloud:7233",
    "DATABASE_PASSWORD": "xxx"
  }'
```

## Module Structure

```
terraform/
├── main.tf              # Main configuration
├── variables.tf         # Input variables
├── outputs.tf           # Output values
├── versions.tf          # Provider configuration
├── terraform.tfvars.example
├── environments/
│   ├── dev.tfvars
│   └── prod.tfvars
└── modules/
    ├── cognito/         # Cognito User Pool
    ├── iam/             # IAM roles and policies
    ├── kms/             # KMS encryption key
    ├── s3/              # S3 buckets
    ├── scheduler/       # EventBridge Scheduler
    └── secrets/         # Secrets Manager
```

## Security Notes

1. **S3 Buckets** - All buckets have:
   - Public access blocked
   - S3-managed encryption (SSE-S3)
   - Versioning enabled
   - Old version cleanup (configurable)

2. **KMS Key** - Key rotation enabled

3. **IAM Roles** - Follows least-privilege principle

4. **Cognito** - Password policy enforced

## Troubleshooting

### IRSA Not Working

1. Verify OIDC provider is associated with EKS cluster
2. Check the trust relationship on the IAM role
3. Ensure service account annotation is correct

```bash
# Verify OIDC provider
aws iam list-open-id-connect-providers --profile ensemble

# Check role trust policy
aws iam get-role --profile ensemble \
  --role-name workflows-dev-workloads-role \
  --query 'Role.AssumeRolePolicyDocument'
```

### Scheduler Permissions

If scheduler jobs fail, check:
1. Scheduler role has `iam:PassRole` permission
2. Target service allows scheduler invocation

### KMS Access Denied

Ensure the workloads role has `kms:Encrypt` and `kms:Decrypt` permissions on the key.

### State Lock Issues

If using DynamoDB for state locking:

```bash
# Force unlock (use with caution)
terraform force-unlock LOCK_ID
```

## Destroy

```bash
export AWS_PROFILE=ensemble

# Destroy all resources
terraform destroy -var-file=environments/dev.tfvars

# Note: S3 buckets with s3_force_destroy=false must be emptied first
```
