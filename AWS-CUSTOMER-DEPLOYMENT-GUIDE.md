# Workflows - Customer Deployment Guide

This guide walks you through deploying Workflows to your AWS EKS cluster.

> **Runtime Configuration:** The web app loads all configuration (auth provider, URLs, etc.) at
> runtime via environment variables. This means you use the **same pre-built Docker images** for
> any environment - just configure your settings in the Helm values file. No need to rebuild
> images for different Cognito pools, domains, or auth providers.

## Infrastructure Setup

Before deploying Workflows, you need to provision AWS infrastructure. Use the provided Terraform configuration:

```bash
cd terraform

# Initialize and apply
terraform init
terraform apply -var-file=environments/prod.tfvars
```

This creates:
- S3 buckets for storage
- IAM roles for IRSA (pod permissions)
- Cognito User Pool
- EventBridge Scheduler group
- Secrets Manager secret template

See `terraform/README.md` for full details.

## Prerequisites

- AWS EKS cluster (Kubernetes 1.35+)
- `kubectl` configured for your cluster
- `helm` v3.x installed
- AWS Load Balancer Controller installed
- PostgreSQL database (RDS or Neon recommended)
- Temporal Cloud account (https://cloud.temporal.io)
- Domain name with DNS access
- S3 buckets for storage (see Infrastructure Setup)

## Quick Start

```bash
# 1. Create namespace
kubectl create namespace workflows

# 2. Create your secrets (see Step 2 below)

# 3. Create your values file (see Step 3 below)

# 4. Install
helm install workflows oci://public.ecr.aws/ensembleapp/workflows/chart \
  -f my-values.yaml \
  -n workflows

# 5. Verify
kubectl get pods -n workflows
```

## Step 1: Prepare Your Database

Create a PostgreSQL database (RDS Aurora recommended):

```bash
aws rds create-db-cluster \
  --db-cluster-identifier workflows-db \
  --engine aurora-postgresql \
  --engine-version 15.4 \
  --master-username admin \
  --master-user-password <YOUR_PASSWORD> \
  --vpc-security-group-ids <YOUR_SG>
```

Note your database endpoint for the next steps.

### Run Database Migrations

After creating the database, run the schema migrations:

```bash
# Using the workflows CLI (from a machine with database access)
npx workflows db migrate --connection-string "postgresql://admin:password@your-db:5432/workflows"
```

Or run migrations from within the cluster after deployment:

```bash
kubectl exec deployment/workflows-server -n workflows -- npx workflows db migrate
```

## Step 2: Configure Secrets

### Option A: AWS Secrets Manager (Recommended)

1. **Install External Secrets Operator:**

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets -n external-secrets --create-namespace
```

2. **Create SecretStore:**

```yaml
# secret-store.yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: aws-secret-store
  namespace: workflows
spec:
  provider:
    aws:
      service: SecretsManager
      region: <YOUR_REGION>
      auth:
        jwt:
          serviceAccountRef:
            name: workflows-sa
```

3. **Create secrets in AWS Secrets Manager:**

```bash
aws secretsmanager create-secret \
  --name workflows/app-secrets \
  --secret-string '{
    "PG_BASE_URL": "postgresql://admin:password@your-db.rds.amazonaws.com:5432/workflows",
    "ANTHROPIC_API_KEY": "sk-ant-xxx",
    "OPENAI_API_KEY": "sk-xxx",
    "TEMPORAL_API_KEY": "your-temporal-cloud-api-key",
    "TEMPORAL_ADDRESS": "your-namespace.tmprl.cloud:7233"
  }'
```

> **Note:** If using Firebase instead of Cognito, add `FIREBASE_PRIVATE_KEY` to the JSON.

4. **Create ExternalSecret:**

```yaml
# external-secret.yaml
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app-secrets
  namespace: workflows
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: aws-secret-store
  target:
    name: app-secrets
  dataFrom:
    - extract:
        key: workflows/app-secrets
```

```bash
kubectl apply -f secret-store.yaml
kubectl apply -f external-secret.yaml
```

### Option B: Kubernetes Secrets (Simple)

```bash
kubectl create secret generic app-secrets -n workflows \
  --from-literal=PG_BASE_URL="postgresql://admin:password@your-db.rds.amazonaws.com:5432/workflows" \
  --from-literal=ANTHROPIC_API_KEY="sk-ant-..." \
  --from-literal=OPENAI_API_KEY="sk-..." \
  --from-literal=FIREBASE_PRIVATE_KEY="-----BEGIN PRIVATE KEY-----..."
```

## Step 3: Create Your Values File

Create `my-values.yaml` with your configuration:

```yaml
# my-values.yaml

# Non-secret environment variables
config:
  AWS_REGION: "us-west-2"  # Your AWS region
  CLOUD_PROVIDER: "aws"
  SERVERLESS_ENVIRONMENT: "false"  # k8s uses in-process tasks

  # ===========================================
  # Web App Runtime Configuration
  # ===========================================
  # These are loaded by the web app at runtime (not baked into the Docker image)
  SERVER_URL: "https://workflows.yourcompany.com"  # Backend API URL (same as web for single domain)
  WEB_URL: "https://workflows.yourcompany.com"     # Web app public URL

  # Auth Configuration - choose one:
  # Option 1: AWS Cognito (recommended for AWS)
  AUTH_PROVIDER: "cognito"
  COGNITO_USER_POOL_ID: "us-west-2_xxxxx"  # From Terraform/CDK output
  COGNITO_CLIENT_ID: "xxxxx"                # From Terraform/CDK output
  COGNITO_DOMAIN: "xxxxx.auth.us-west-2.amazoncognito.com"  # From Terraform/CDK output

  # Option 2: Firebase Auth (uncomment and configure if using Firebase)
  # AUTH_PROVIDER: "firebase"
  # FIREBASE_PROJECT_ID: "your-firebase-project"
  # FIREBASE_CLIENT_EMAIL: "firebase-adminsdk@your-project.iam.gserviceaccount.com"
  # FIREBASE_API_KEY: "AIzaSy..."
  # FIREBASE_AUTH_DOMAIN: "your-project.firebaseapp.com"

  # ===========================================
  # Storage Configuration (from Terraform/CDK outputs)
  # ===========================================
  STORAGE_USER_FILES_BUCKET: "example-workflows-user-files"
  STORAGE_DOCUMENTS_BUCKET: "example-workflows-documents"
  STORAGE_TENANT_MIGRATIONS_BUCKET: "example-workflows-tenant-migrations"

  # EventBridge Scheduler (optional)
  # SCHEDULER_ROLE_ARN: "arn:aws:iam::123456789:role/workflows-prod-scheduler-role"
  # SCHEDULER_GROUP_NAME: "workflows-prod-schedules"

# Image registry (provided by AWS Marketplace)
global:
  imageRegistry: "public.ecr.aws/ensembleapp/"

# Ingress configuration
ingress:
  enabled: true
  className: alb
  annotations:
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
    alb.ingress.kubernetes.io/listen-ports: '[{"HTTPS": 443}]'
    alb.ingress.kubernetes.io/ssl-redirect: "443"
    alb.ingress.kubernetes.io/healthcheck-path: /health
  hosts:
    - host: "workflows.yourcompany.com"  # Your domain
      paths:
        - path: /api
          pathType: Prefix
          service: server
        - path: /mcp
          pathType: Prefix
          service: server
        - path: /channel
          pathType: Prefix
          service: server
        - path: /
          pathType: Prefix
          service: web
  tls:
    enabled: true
    certificateArn: "arn:aws:acm:us-west-2:123456789:certificate/xxx"  # Your ACM cert

# Use your secrets
secrets:
  existingSecret: "app-secrets"

# Service Account (for IRSA - grants access to S3, Secrets Manager, etc.)
serviceAccount:
  create: false  # Use the one created by Terraform/eksctl
  name: workflows-sa

# Resource allocation (adjust based on your needs)
server:
  replicaCount: 2
  resources:
    requests:
      memory: "1Gi"
      cpu: "500m"
    limits:
      memory: "2Gi"
      cpu: "1000m"
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 10

web:
  replicaCount: 2
  resources:
    requests:
      memory: "512Mi"
      cpu: "250m"
    limits:
      memory: "1Gi"
      cpu: "500m"
  autoscaling:
    enabled: true
    minReplicas: 2
    maxReplicas: 6

worker:
  replicaCount: 2
  resources:
    requests:
      memory: "512Mi"
      cpu: "100m"
    limits:
      memory: "1Gi"
      cpu: "500m"
  autoscaling:
    enabled: true
    minReplicas: 1
    maxReplicas: 8
```

## Step 4: Install Workflows

```bash
helm install workflows oci://public.ecr.aws/ensembleapp/workflows/chart \
  -f my-values.yaml \
  -n workflows
```

## Step 5: Configure DNS

Get your ALB address:

```bash
kubectl get ingress -n workflows
```

Create a CNAME record pointing your domain to the ALB address:

```
workflows.yourcompany.com → k8s-workflows-xxx.us-west-2.elb.amazonaws.com
```

## Step 6: Verify Deployment

```bash
# Check pods are running
kubectl get pods -n workflows

# Check services
kubectl get svc -n workflows

# Check ingress
kubectl get ingress -n workflows

# View logs
kubectl logs -f -l app.kubernetes.io/component=server -n workflows
```

## Configuration Reference

### Required Configuration

| Parameter | Description | Example |
|-----------|-------------|---------|
| `ingress.hosts[0].host` | Your domain name | `workflows.company.com` |
| `ingress.tls.certificateArn` | ACM certificate ARN | `arn:aws:acm:...` |
| `secrets.existingSecret` | K8s secret name | `app-secrets` |
| `config.SERVER_URL` | Backend API URL | `https://workflows.company.com` |
| `config.WEB_URL` | Web app public URL | `https://workflows.company.com` |
| `config.AUTH_PROVIDER` | Auth provider (`cognito` or `firebase`) | `cognito` |

### Web Runtime Configuration (Cognito)

| Parameter | Description | Example |
|-----------|-------------|---------|
| `config.COGNITO_USER_POOL_ID` | Cognito User Pool ID | `us-west-2_xxxxx` |
| `config.COGNITO_CLIENT_ID` | Cognito App Client ID | `xxxxx` |
| `config.COGNITO_DOMAIN` | Cognito domain | `xxx.auth.us-west-2.amazoncognito.com` |

### Web Runtime Configuration (Firebase)

| Parameter | Description | Example |
|-----------|-------------|---------|
| `config.FIREBASE_API_KEY` | Firebase API key | `AIzaSy...` |
| `config.FIREBASE_AUTH_DOMAIN` | Firebase auth domain | `project.firebaseapp.com` |
| `config.FIREBASE_PROJECT_ID` | Firebase project ID | `my-project` |

### Required Secrets

| Secret Key | Description | Required |
|------------|-------------|----------|
| `PG_BASE_URL` | PostgreSQL connection string | Yes |
| `TEMPORAL_ADDRESS` | Temporal Cloud address (e.g., `your-ns.tmprl.cloud:7233`) | Yes |
| `TEMPORAL_API_KEY` | Temporal Cloud API key | Yes |
| `ANTHROPIC_API_KEY` | Anthropic API key | One AI key required |
| `OPENAI_API_KEY` | OpenAI API key | One AI key required |
| `FIREBASE_PRIVATE_KEY` | Firebase service account key | If using Firebase auth |

> **Note:** If using AWS Cognito for authentication, Firebase secrets are not required.

### Optional Configuration

| Parameter | Description | Default |
|-----------|-------------|---------|
| `config.AWS_REGION` | AWS region | `us-west-2` |
| `config.LOG_LEVEL` | Log verbosity | `info` |
| `server.replicaCount` | Server replicas | `1` |
| `web.replicaCount` | Web replicas | `1` |
| `worker.replicaCount` | Worker replicas | `1` |

## Upgrading

```bash
helm upgrade workflows oci://public.ecr.aws/ensembleapp/workflows/chart \
  -f my-values.yaml \
  -n workflows
```

## Uninstalling

```bash
helm uninstall workflows -n workflows
kubectl delete namespace workflows
```

## Troubleshooting

### Pods not starting

```bash
kubectl describe pod <pod-name> -n workflows
kubectl logs <pod-name> -n workflows
```

### Database connection issues

Verify your security groups allow traffic from EKS to RDS on port 5432.

### Ingress not working

1. Verify AWS Load Balancer Controller is installed
2. Check ALB is created: `kubectl get ingress -n workflows`
3. Verify ACM certificate is valid for your domain

### Authentication errors

**If using Cognito:**
1. Verify `COGNITO_USER_POOL_ID` is correct
2. Check the Cognito User Pool exists in the correct region
3. Verify IRSA role has Cognito permissions

**If using Firebase:**
1. Verify Firebase credentials are correct
2. Check `FIREBASE_PROJECT_ID` and `FIREBASE_CLIENT_EMAIL` in config
3. Verify `FIREBASE_PRIVATE_KEY` in secrets

## Support

- Documentation: https://docs.ensembleapp.ai
- Issues: https://github.com/ensemblenext/workflows/issues
- Email: support@ensembleui.com
