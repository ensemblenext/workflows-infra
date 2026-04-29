# Workflows AWS CDK Infrastructure

This CDK stack provisions supporting AWS resources for the Workflows platform. **Note:** This does not create the EKS cluster itself - see [EKS Cluster Setup](#eks-cluster-setup) below.

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
2. Node.js 18+ and npm/pnpm
3. AWS CDK CLI: `npm install -g aws-cdk`
4. [eksctl](https://eksctl.io/) installed (for EKS cluster creation)

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
3. **Run CDK deploy** to create supporting resources
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

Save this ARN for the CDK deployment.

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

## Installation

```bash
cd infrastructure/aws-cdk
npm install
```

## Configuration

### Required Context Variables

| Variable | Description | Required |
|----------|-------------|----------|
| `environment` | Environment name (dev, staging, prod) | No (default: dev) |
| `eksClusterName` | EKS cluster name | No |
| `eksOidcProviderArn` | EKS OIDC provider ARN for IRSA | Yes (for EKS) |
| `namespace` | Kubernetes namespace | No (default: workflows) |

### Using Existing Resources

If you already have S3 buckets or a KMS key, you can reference them instead of creating new ones:

| Variable | Description | Default |
|----------|-------------|---------|
| `existingKmsKeyArn` | ARN of existing KMS key | (create new) |
| `existingUserFilesBucket` | Name of existing user files bucket | (create new) |
| `existingDocumentsBucket` | Name of existing documents bucket | (create new) |
| `existingTenantMigrationsBucket` | Name of existing migrations bucket | (create new) |

Example deployment with existing resources:

```bash
cdk deploy --profile ensemble \
  --context environment=prod \
  --context existingKmsKeyArn=arn:aws:kms:us-west-2:123456789012:key/12345678-1234-1234-1234-123456789012 \
  --context existingUserFilesBucket=my-company-user-files \
  --context existingDocumentsBucket=my-company-documents \
  --context existingTenantMigrationsBucket=my-company-migrations
```

When using existing resources:
- CDK will **not** manage the lifecycle of these resources
- You are responsible for ensuring proper encryption and access policies
- IAM policies will still be created to grant access to these resources

## Deployment

### Set AWS Profile

Before running any CDK commands, set the AWS profile:

```bash
export AWS_PROFILE=ensemble
```

### Synthesize (preview CloudFormation)

```bash
npm run synth

# Or with profile flag
cdk synth --profile ensemble
```

### Deploy

```bash
# Deploy with defaults (dev environment)
npm run deploy

# Or with profile flag
cdk deploy --profile ensemble

# Deploy with custom context
cdk deploy --profile ensemble \
  --context environment=prod \
  --context eksOidcProviderArn=arn:aws:iam::123456789:oidc-provider/oidc.eks.us-west-2.amazonaws.com/id/EXAMPLE

# Deploy without Cognito
cdk deploy --profile ensemble --context enableCognito=false
```

### Destroy

```bash
npm run destroy

# Or with profile flag
cdk destroy --profile ensemble
```

## Outputs

After deployment, the stack outputs:

| Output | Description |
|--------|-------------|
| `UserFilesBucketName` | S3 bucket for user files |
| `DocumentsBucketName` | S3 bucket for documents |
| `TenantMigrationsBucketName` | S3 bucket for migrations |
| `EncryptionKeyArn` | KMS key ARN |
| `SchedulerRoleArn` | EventBridge Scheduler role ARN |
| `WorkloadsRoleArn` | EKS workloads role ARN |
| `CognitoUserPoolId` | Cognito User Pool ID |
| `CognitoUserPoolClientId` | Cognito Client ID |
| `HelmConfigValues` | JSON config for Helm values |

## Helm Integration

After deployment, update your Helm values with the outputs:

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
    "PG_BASE_URL": "postgresql://user:pass@host:5432"
  }'
```

## IRSA Setup

The stack creates an IAM role for EKS workloads. Ensure your EKS service account uses this role:

```yaml
# In your Kubernetes ServiceAccount
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workflows-sa
  namespace: workflows
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::123456789:role/workflows-prod-workloads-role
```

## Security Notes

1. **S3 Buckets** - All buckets have:
   - Public access blocked
   - S3-managed encryption (SSE-S3)
   - Versioning enabled
   - Old version cleanup (90 days)

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
2. Target service (Lambda/API Gateway) allows scheduler invocation

### KMS Access Denied

Ensure the workloads role has `kms:Encrypt` and `kms:Decrypt` permissions on the key.

### CDK Bootstrap

If you see "This stack uses assets" error, bootstrap CDK first:

```bash
cdk bootstrap --profile ensemble
```
