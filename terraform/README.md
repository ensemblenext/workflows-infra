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

### Background Task Queue (Optional)
Created when `enable_task_queue=true`. Backs `TASK_QUEUE_PROVIDER=sqs`, which is how
evaluation test cases and inbound webhooks are processed out of band on AWS.
- **SQS Queues** - One per entry in `task_queues`; by default `evaluation-cases` and `webhook-processor`
- **SQS Dead-Letter Queues** - One per queue. Not optional: the consumer decides retry-or-delete per message, but the redrive policy is what stops a permanently failing task being redelivered forever
- **IAM Policy (Workloads)** - `SendMessage`, `ReceiveMessage` and `DeleteMessage`, scoped to those queue ARNs
- **Cognito Resource Server + M2M Client** - The identity the consumer uses to authenticate its callback into the server, when `cognito_enable_task_callback_oauth=true`

### Authentication (Optional)
- **Cognito User Pool** - For user authentication
- **Cognito User Pool Client** - Web/SPA client
- **Cognito Resource Server** - For scheduler API OAuth scopes (when `cognito_enable_scheduler_oauth=true`)
- **Cognito M2M Client** - For EventBridge Scheduler OAuth authentication (when `cognito_enable_scheduler_oauth=true`)

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
cp environments/sample.tfvars environments/prod.tfvars
# Edit prod.tfvars and set eks_oidc_provider_arn

# Plan deployment
terraform plan -var-file=environments/prod.tfvars

# Apply
terraform apply -var-file=environments/prod.tfvars
```

## Importing Existing Resources

If you already have AWS resources created (manually or from a previous deployment), import them into Terraform state before applying:

```bash
cd infrastructure/terraform
export AWS_PROFILE=ensemble

# Initialize Terraform first
terraform init

# Import all existing resources (safe to run multiple times)
./import-existing.sh prod

# Verify what Terraform will do
terraform plan -var-file=environments/prod.tfvars

# Apply changes
terraform apply -var-file=environments/prod.tfvars
```

The import script:
- Automatically detects and imports existing resources
- Skips resources that don't exist or are already imported
- Safe to run multiple times

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
| `enable_task_queue` | Enable SQS task queues and the matching IAM policy | `false` |
| `task_queues` | Queues to create, keyed by logical name | `evaluation-cases`, `webhook-processor` |
| `cognito_enable_task_callback_oauth` | Create the M2M client the SQS consumer authenticates with | `false` |
| `cognito_task_api_identifier` | Resource server identifier for the task callback API | `""` |
| `cognito_enable_scheduler_oauth` | Enable OAuth M2M client for scheduler | `false` |
| `cognito_scheduler_api_identifier` | Resource server identifier for scheduler API | `""` |
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

## Scheduler Authentication

EventBridge Scheduler needs to authenticate when calling your API. Two options are available:

### Option 1: API Key (Simple)

```hcl
# environments/prod.tfvars
scheduler_api_destination_endpoint      = "https://your-domain.com/api/scheduler/callback"
scheduler_api_destination_auth_type     = "API_KEY"
scheduler_api_destination_api_key_name  = "x-api-key"
scheduler_api_destination_api_key_value = "your-secure-api-key"
```

Set the same value in the server environment as `SCHEDULER_CALLBACK_API_KEY`. If you use a
different API key header name, also set `SCHEDULER_CALLBACK_API_KEY_HEADER`.

### Option 2: Cognito OAuth M2M (Recommended for Production)

Uses Cognito Machine-to-Machine OAuth with client credentials flow:

```hcl
# environments/prod.tfvars
scheduler_api_destination_endpoint   = "https://your-domain.com/api/scheduler/callback"
scheduler_api_destination_auth_type  = "OAUTH_CLIENT_CREDENTIALS"
cognito_enable_scheduler_oauth       = true
cognito_scheduler_api_identifier     = "https://your-domain.com/api"
```

When `cognito_enable_scheduler_oauth=true`, Terraform automatically:
1. Creates a Cognito Resource Server with `scheduler.trigger` scope
2. Creates an M2M App Client with client credentials grant
3. Configures EventBridge to use OAuth tokens for API calls

View the generated OAuth credentials:

```bash
terraform output cognito_scheduler_oauth_client_id
terraform output -raw cognito_scheduler_oauth_client_secret
```

## Background Task Queue

Evaluation runs queue one task per test case, and inbound webhooks are processed out of
band. On AWS that uses SQS, which only holds messages — the worker pod polls the queues
and makes the HTTP call each message describes. (On GCP, Cloud Tasks performs the
request itself and no consumer is needed.)

### Enabling it

```bash
# environments/prod.tfvars
enable_task_queue = true
```

```bash
terraform apply -var-file=environments/prod.tfvars
terraform output task_queue_env
```

**Create the queues before enabling the queue on the services.** With
`TASK_QUEUE_ENABLED=true` and no queue to enqueue into, every evaluation run is marked
failed rather than falling back to in-process execution.

### Wiring the services

`terraform output task_queue_env` prints what both services need:

```
EVALUATION_QUEUE_NAME = "workflows-prod-evaluation-cases"
WEBHOOK_QUEUE_NAME    = "workflows-prod-webhook-processor"
SQS_CONSUMER_QUEUES   = "workflows-prod-evaluation-cases,workflows-prod-webhook-processor"
SQS_QUEUE_URL_PREFIX  = "https://sqs.us-west-2.amazonaws.com/<account-id>"
TASK_QUEUE_ENABLED    = "true"
TASK_QUEUE_PROVIDER   = "sqs"
```

Queues are named `<project>-<environment>-<queue>` so one account can hold several
environments. That means the application's own defaults (`evaluation-cases`,
`webhook-processor`) no longer match and the three name settings **must** be set
explicitly — which is why that output exists.

`SQS_CONSUMER_QUEUES` goes on the **worker** only; it is what starts the consumer.
Without it the worker stays inert and nothing drains the queues. Do not list a queue
that does not exist: the consumer polls each name independently and will log
`SQS receive failed, backing off` every five seconds indefinitely.

### Callback authentication

Cognito secures exactly one hop — the worker calling back into the server:

```
  server ──SendMessage──▶  SQS queue                      (IRSA)
                              │
  worker ──ReceiveMessage──◀──┘                           (IRSA)
     │
     ├─ POST /oauth2/token  grant_type=client_credentials  (Cognito M2M)
     │    scope=<task_api_identifier>/tasks.callback
     │         └──▶ access token
     │
     └─ POST $SERVER_URL/api/evaluations/internal/run-case
            Authorization: Bearer <token>
                   │
                   ▼
            server verifies signature (JWKS), issuer,
            token_use=access and the scope, runs the case, 200
                   │
  worker ──DeleteMessage──▶ SQS                           (IRSA)
```

IRSA covers the pod→SQS calls, but not the HTTP hop: that is an ordinary request to our
own API, with AWS nowhere in the path to vouch for it — and the endpoint can invoke an
agent, so it cannot be open. The token is fetched **per delivery**, because one obtained
when the message was queued would often have expired before a delayed or redelivered
message is consumed.

This is unlike EventBridge Scheduler, where AWS performs the request and therefore does
the OAuth exchange itself from the credentials stored in its Connection — which is why
none of the `TASK_CALLBACK_*` variables apply there.

Enable the client alongside the queues:

```bash
# environments/prod.tfvars
enable_task_queue                 = true
cognito_enable_task_callback_oauth = true
cognito_task_api_identifier        = "https://tasks.example.com"
```

The identifier must differ from `cognito_scheduler_api_identifier` — Cognito requires
resource server identifiers to be unique within a pool, and a precondition checks this
at plan time rather than letting Cognito fail at apply.

Then:

```bash
terraform output task_callback_oauth                  # worker settings + the scope
terraform output -raw task_callback_oauth_client_secret
```

| Variable | On |
|----------|-----|
| `TASK_CALLBACK_OAUTH_TOKEN_URL`, `_CLIENT_ID`, `_CLIENT_SECRET` | worker |
| `TASK_CALLBACK_OAUTH_SCOPE` | **both** — the worker requests it, the server requires it |
| `CLOUD_PROVIDER=aws` | server — defaults to `gcp`, which checks tokens against Google |

The scope being needed on both sides is why it is wired here: one value, one source, so
the two cannot drift. A mismatch refuses every callback, and `TASK_CALLBACK_OAUTH_SCOPE`
missing on the server is worse than wrong — the server answers 500 and refuses the token
rather than accepting an unscoped one.

Leave `TASK_CALLBACK_SECRET` unset. The worker only falls back to the shared secret when
all four OAuth variables are absent, so setting it alongside them just leaves a weaker
second door into that endpoint. The client secret belongs in Secrets Manager, not in
`values.yaml`.

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
| `cognito_scheduler_oauth_client_id` | OAuth Client ID for scheduler (when enabled) |
| `task_queue_url_prefix` | `SQS_QUEUE_URL_PREFIX` for the services (when enabled) |
| `task_queue_names` | Queue names, keyed by logical name |
| `task_queue_arns` | Task queue ARNs |
| `task_queue_dlq_arns` | Dead-letter queue ARNs |
| `task_queue_env` | Every queue-related environment value at once |
| `task_callback_oauth` | `TASK_CALLBACK_OAUTH_*` for the worker, plus the shared scope |
| `task_callback_oauth_client_secret` | Client secret for the above (sensitive) |
| `cognito_scheduler_oauth_client_secret` | OAuth Client Secret for scheduler (sensitive) |
| `cognito_scheduler_oauth_token_endpoint` | OAuth Token Endpoint URL |
| `cognito_scheduler_oauth_scope` | OAuth Scope for scheduler API |
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
  AWS_SCHEDULER_ROLE_ARN: "arn:aws:iam::123456789:role/workflows-prod-scheduler-role"
  AWS_SCHEDULER_GROUP_NAME: "workflows-prod-schedules"

  # Auth (if using Cognito)
  AUTH_PROVIDER: "cognito"
  AWS_COGNITO_USER_POOL_ID: "us-west-2_xxxxx"
  AWS_COGNITO_REGION: "us-west-2"

serviceAccount:
  create: true
  name: workflows-sa
  annotations:
    eks.amazonaws.com/role-arn: "arn:aws:iam::123456789:role/workflows-prod-workloads-role"
```

## Secrets Setup

After deployment, update the Secrets Manager secret with actual values.

See `helm/workflows/references/server-variables.yaml` for the full list of secrets.

```bash
aws secretsmanager put-secret-value \
  --profile ensemble \
  --secret-id workflows-prod/app-secrets \
  --secret-string '{
    "PG_BASE_URL": "postgresql://user:pass@host:5432",
    "TEMPORAL_API_KEY": "xxx",
    "OPENAI_API_KEY": "sk-xxx",
    "ANTHROPIC_API_KEY": "sk-ant-xxx"
  }'
```

**Required secrets:**
- `PG_BASE_URL` - PostgreSQL connection string (without database name)
- `TEMPORAL_API_KEY` - Temporal Cloud API key

**Optional secrets:** `SYSTEM_DB_NAME`, `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`, `GEMINI_API_KEY`, and more (see references).

## Module Structure

```
terraform/
├── main.tf              # Main configuration
├── variables.tf         # Input variables
├── outputs.tf           # Output values
├── versions.tf          # Provider configuration
├── import-existing.sh   # Import existing AWS resources
├── environments/
│   ├── sample.tfvars    # Example configuration
│   └── prod.tfvars      # Production configuration
└── modules/
    ├── cognito/         # Cognito User Pool + OAuth
    ├── iam/             # IAM roles and policies
    ├── kms/             # KMS encryption key
    ├── s3/              # S3 buckets
    ├── scheduler/       # EventBridge Scheduler
    ├── secrets/         # Secrets Manager
    └── sqs/             # Background task queues + DLQs
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
