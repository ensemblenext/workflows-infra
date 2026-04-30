# AWS Deployment Guide (Recommended)

This is the recommended step-by-step guide for deploying Workflows to a fresh AWS account.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Deployment Flow                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. AWS Setup          →  CLI, ECR repositories                  │
│           ↓                                                      │
│  2. EKS Cluster        →  eksctl create cluster                  │
│           ↓                                                      │
│  3. ALB Controller     →  Required for ingress                   │
│           ↓                                                      │
│  4. Terraform          →  S3, IAM roles, Cognito, Scheduler      │
│           ↓                                                      │
│  5. Docker Images      →  Build and push to ECR                  │
│           ↓                                                      │
│  6. Secrets            →  Secrets Manager + External Secrets     │
│           ↓                                                      │
│  7. SSL Certificate    →  ACM certificate                        │
│           ↓                                                      │
│  8. Helm Deploy        →  Install the application                │
│           ↓                                                      │
│  9. DNS                →  Route 53 configuration                 │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- AWS account with admin permissions
- Tools installed:
  - `aws` CLI
  - `eksctl`
  - `kubectl`
  - `helm`
  - `docker`
  - `terraform`

## Step 1: AWS CLI Setup

```bash
# Configure AWS credentials
aws configure --profile ensemble

# Set environment variables
export AWS_PROFILE=ensemble
export AWS_REGION=us-west-2
export CLUSTER_NAME=workflows-prod
export K8S_VERSION=1.35
# TODO: Use your own domain name.
export SERVICE_ROOT_DOMAIN=ensembleapp.ai
export SERVICE_DOMAIN=aws-us-west-2.$SERVICE_ROOT_DOMAIN
export SERVICE_ENDPOINT=https://$SERVICE_DOMAIN
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Verify
aws sts get-caller-identity
```

## Step 2: Create ECR Repositories

```bash
aws ecr create-repository --repository-name workflows/server --region $AWS_REGION
aws ecr create-repository --repository-name workflows/web --region $AWS_REGION
aws ecr create-repository --repository-name workflows/worker --region $AWS_REGION
```

## Step 3: Create EKS Cluster

Creates a cluster with nodes in private subnets and a NAT Gateway for static outbound IP.

```bash
eksctl create cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --version $K8S_VERSION \
  --nodegroup-name workflows-nodes \
  --node-type t3.large \
  --nodes 2 \
  --nodes-min 1 \
  --nodes-max 4 \
  --managed \
  --with-oidc \
  --node-private-networking \
  --vpc-nat-mode Single

# Verify
kubectl get nodes
```

**NAT Gateway modes:**
| Mode | Description | Cost |
|------|-------------|------|
| `Single` | One NAT Gateway shared across AZs. If the AZ fails, outbound traffic is disrupted. | Lower |
| `HighlyAvailable` | One NAT Gateway per AZ. Resilient to AZ failures. | Higher |

For production workloads requiring high availability, use `--vpc-nat-mode HighlyAvailable`.

Get the NAT Gateway's static IP (for whitelisting with external services):

```bash
aws ec2 describe-nat-gateways --region $AWS_REGION \
  --query "NatGateways[?State=='available'].NatGatewayAddresses[0].PublicIp" \
  --output text
```

Get the OIDC provider ARN (needed for Terraform):

```bash
OIDC_URL=$(aws eks describe-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --query "cluster.identity.oidc.issuer" \
  --output text)

OIDC_PROVIDER_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/${OIDC_URL#https://}"

echo "OIDC Provider ARN: $OIDC_PROVIDER_ARN"
```

## Step 4: Install AWS Load Balancer Controller

```bash
# Create IAM policy for ALB controller (includes EC2, ELB, WAF permissions)
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://infrastructure/resources/aws/alb-iam-policy.json \
  --region $AWS_REGION

# Create IAM service account with the policy
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --region=$AWS_REGION \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::${AWS_ACCOUNT_ID}:policy/AWSLoadBalancerControllerIAMPolicy \
  --approve

# Install controller
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# Verify
kubectl get deployment -n kube-system aws-load-balancer-controller
```

## Step 5: Run Terraform

This creates S3 buckets, IAM roles, Cognito, and Scheduler resources.

```bash
cd terraform

# Initialize
terraform init

# Update prod.tfvars with your OIDC provider ARN
# eks_oidc_provider_arn = "arn:aws:iam::123456789:oidc-provider/..."

# Plan and apply
terraform plan -var-file=environments/prod.tfvars
terraform apply -var-file=environments/prod.tfvars

# Save the outputs
terraform output
```

**Terraform creates:**
- S3 buckets: `example-workflows-user-files`, `example-workflows-documents`, `example-workflows-tenant-migrations`
- IAM role: `workflows-prod-workloads-role` (for pod permissions via IRSA)
- IAM role: `workflows-prod-scheduler-role` (for EventBridge)
- Cognito User Pool (if enabled)
- EventBridge Scheduler group
- Secrets Manager secret template

## Step 6: Build and Push Docker Images

Create `.env` in project root:

```bash
ECR_REGISTRY=$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
TAG=latest
```

> **Note:** Web app configuration (auth provider, URLs, Cognito/Firebase settings) is loaded at
> **runtime** via environment variables. No build-time configuration needed - the same Docker
> image works for all environments (dev, staging, prod, customer deployments).

Build and push:

```bash
# Login to ECR
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Build and push
docker compose build && docker compose push
```

## Step 7: Set Up Secrets

### Install External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

### Create Namespace and Service Account

```bash
# Create namespace
kubectl create namespace workflows

# Create service account with the Terraform-created IAM role annotation
# Note: We use kubectl instead of eksctl because Terraform already created the IAM role
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workflows-sa
  namespace: workflows
  annotations:
    eks.amazonaws.com/role-arn: arn:aws:iam::${AWS_ACCOUNT_ID}:role/workflows-prod-workloads-role
EOF

# Verify
kubectl get serviceaccount workflows-sa -n workflows -o yaml
```

### Create Secrets in Secrets Manager

```bash
# Database connection
aws secretsmanager put-secret-value \
  --secret-id workflows-prod/app-secrets \
  --secret-string '{
    "PG_BASE_URL": "postgresql://user:pass@your-db:5432/workflows",
    "ANTHROPIC_API_KEY": "sk-ant-xxx",
    "OPENAI_API_KEY": "sk-xxx",
    "TEMPORAL_API_KEY": "xxx",
    "TEMPORAL_ADDRESS": "xxx.tmprl.cloud:7233"
  }'
```

### Create SecretStore and ExternalSecret

```bash
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: aws-secret-store
  namespace: workflows
spec:
  provider:
    aws:
      service: SecretsManager
      region: $AWS_REGION
      auth:
        jwt:
          serviceAccountRef:
            name: workflows-sa
---
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
        key: workflows-prod/app-secrets
EOF
```

## Step 8: Request SSL Certificate

```bash
# Request certificate
aws acm request-certificate \
  --domain-name "*.$SERVICE_ROOT_DOMAIN" \
  --validation-method DNS \
  --region $AWS_REGION

# Get certificate ARN
export CERT_ARN=$(aws acm list-certificates --region $AWS_REGION \
  --query "CertificateSummaryList[?DomainName=='*.$SERVICE_ROOT_DOMAIN'].CertificateArn" \
  --output text)

echo "Certificate ARN: $CERT_ARN"

# Complete DNS validation (add CNAME records shown here to your DNS)
aws acm describe-certificate --certificate-arn $CERT_ARN --region $AWS_REGION \
  --query "Certificate.DomainValidationOptions"
```

## Step 9: Deploy Helm Chart

```bash
helm install workflows infrastructure/helm/workflows \
  -f infrastructure/helm/workflows/eks-values.yaml \
  -n workflows \
  --set global.imageRegistry="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/" \
  --set ingress.tls.certificateArn="$CERT_ARN"

# Watch deployment
kubectl get pods -n workflows -w
```

## Step 10: Configure DNS

```bash
# Get ALB DNS name
ALB_DNS=$(kubectl get ingress -n workflows -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "ALB DNS: $ALB_DNS"
```

Create a Route 53 alias record pointing `$SERVICE_DOMAIN` to the ALB.

## Verify Deployment

```bash
# Check pods
kubectl get pods -n workflows

# Check ingress
kubectl get ingress -n workflows

# View logs
kubectl logs -f -l app.kubernetes.io/component=server -n workflows

# Test endpoint
curl $SERVICE_ENDPOINT/api/health
```

## Quick Reference

After initial setup, use these commands for updates:

```bash
# ECR login (expires every 12 hours)
aws ecr get-login-password --region $AWS_REGION | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com

# Build and push
docker compose build && docker compose push

# Or upgrade with Helm
helm upgrade workflows infrastructure/helm/workflows \
  -f infrastructure/helm/workflows/eks-values.yaml \
  -n workflows \
  --set global.imageRegistry="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/"

# Restart pods to pull new images
kubectl rollout restart deployment -n workflows

# Rollout specific service
kubectl rollout restart deployment workflows-web -n workflows  

# Check pods
kubectl get pods -n workflows

# View logs
kubectl logs workflows-worker-abc -n workflows  

```

## Cognito Identity Providers Setup

To enable Google and Microsoft sign-in, configure identity providers in Cognito.

### Google Sign-In

**1. Create OAuth credentials in Google Cloud Console:**
- Go to [Google Cloud Console](https://console.cloud.google.com/apis/credentials)
- Create OAuth 2.0 Client ID (Web application)
- Add authorized redirect URI:
  ```
  https://<COGNITO_DOMAIN>/oauth2/idpresponse
  ```
  Example: `https://workflows-prod-auth.auth.us-west-2.amazoncognito.com/oauth2/idpresponse`
- Save the **Client ID** and **Client Secret**

**2. Add Google as identity provider:**
```bash
aws cognito-idp create-identity-provider \
  --user-pool-id $COGNITO_USER_POOL_ID \
  --provider-name Google \
  --provider-type Google \
  --provider-details '{
    "client_id": "<GOOGLE_CLIENT_ID>",
    "client_secret": "<GOOGLE_CLIENT_SECRET>",
    "authorize_scopes": "openid email profile"
  }' \
  --attribute-mapping email=email,name=name \
  --region $AWS_REGION
```

**3. Update the app client to allow Google:**
```bash
aws cognito-idp update-user-pool-client \
  --user-pool-id $COGNITO_USER_POOL_ID \
  --client-id $COGNITO_CLIENT_ID \
  --supported-identity-providers COGNITO Google \
  --allowed-o-auth-flows code \
  --allowed-o-auth-scopes openid email profile \
  --allowed-o-auth-flows-user-pool-client \
  --callback-urls "[\"$SERVICE_ENDPOINT/auth/callback\"]" \
  --logout-urls "[\"$SERVICE_ENDPOINT\"]" \
  --region $AWS_REGION
```

### Microsoft Sign-In

**1. Create app in Azure AD:**
- Go to [Azure Portal](https://portal.azure.com) → Azure Active Directory → App registrations
- Create new registration
- Add redirect URI (Web):
  ```
  https://<COGNITO_DOMAIN>/oauth2/idpresponse
  ```
- Go to "Certificates & secrets" → Create a client secret
- Save **Application (client) ID**, **Directory (tenant) ID**, and **Client Secret**

**2. Add Microsoft as OIDC provider:**
```bash
aws cognito-idp create-identity-provider \
  --user-pool-id $COGNITO_USER_POOL_ID \
  --provider-name Microsoft \
  --provider-type OIDC \
  --provider-details '{
    "client_id": "<MICROSOFT_CLIENT_ID>",
    "client_secret": "<MICROSOFT_CLIENT_SECRET>",
    "authorize_scopes": "openid email profile",
    "oidc_issuer": "https://login.microsoftonline.com/<TENANT_ID>/v2.0",
    "attributes_request_method": "GET"
  }' \
  --attribute-mapping email=email,name=name \
  --region $AWS_REGION
```

**3. Update app client to include Microsoft:**
```bash
aws cognito-idp update-user-pool-client \
  --user-pool-id $COGNITO_USER_POOL_ID \
  --client-id $COGNITO_CLIENT_ID \
  --supported-identity-providers COGNITO Google Microsoft \
  --allowed-o-auth-flows code \
  --allowed-o-auth-scopes openid email profile \
  --allowed-o-auth-flows-user-pool-client \
  --callback-urls "[\"$SERVICE_ENDPOINT/auth/callback\"]" \
  --logout-urls "[\"$SERVICE_ENDPOINT\"]" \
  --region $AWS_REGION
```

### Environment Variables

Get Cognito values for the Helm deployment:
```bash
terraform output cognito_user_pool_id
terraform output cognito_user_pool_client_id
terraform output cognito_user_pool_domain
```

These values are configured in the Helm values file (not at Docker build time):
```yaml
# In eks-values.yaml
config:
  AUTH_PROVIDER: "cognito"
  SERVER_URL: "https://${YOUR_SERVER_URL}"
  WEB_URL: "https://${YOUR_WEB_URL}"
  COGNITO_USER_POOL_ID: "us-west-2_xxxxx"
  COGNITO_CLIENT_ID: "xxxxx"
  COGNITO_DOMAIN: "xxxxx.auth.us-west-2.amazoncognito.com"
```

> **Note:** Web app configuration is loaded at runtime. One Docker image works for all environments.

## Troubleshooting

### View Logs

```bash
# Server logs
kubectl logs -f deployment/workflows-server -n workflows

# Web logs
kubectl logs -f deployment/workflows-web -n workflows

# Worker logs
kubectl logs -f deployment/workflows-worker -n workflows

# View previous crashed container logs
kubectl logs deployment/workflows-server -n workflows --previous

# Logs from all pods with a label
kubectl logs -f -l app.kubernetes.io/component=server -n workflows
```

### Check Pod Status

```bash
# List all pods
kubectl get pods -n workflows

# Describe pod for events and errors
kubectl describe pod <pod-name> -n workflows

# Check pod environment variables
kubectl exec deployment/workflows-server -n workflows -- printenv | sort

# Shell into a pod
kubectl exec -it deployment/workflows-server -n workflows -- sh
```

### Check Services and Ingress

```bash
# List services
kubectl get svc -n workflows

# Check ingress status and ALB DNS
kubectl get ingress -n workflows
kubectl describe ingress -n workflows

# Check ALB controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50
```

### Check Secrets

```bash
# List secrets
kubectl get secrets -n workflows

# Check ExternalSecret sync status
kubectl get externalsecret -n workflows
kubectl describe externalsecret app-secrets -n workflows

# Check SecretStore status
kubectl get secretstore -n workflows
kubectl describe secretstore aws-secret-store -n workflows

# View secret contents (base64 decoded)
kubectl get secret app-secrets -n workflows -o jsonpath='{.data}' | jq -r 'to_entries[] | "\(.key): \(.value | @base64d)"'
```

### Common Issues

**Pods stuck in `CreateContainerConfigError`:**
- Usually missing secrets. Check ExternalSecret status.
```bash
kubectl describe pod <pod-name> -n workflows | grep -A5 Events
```

**Pods in `CrashLoopBackOff`:**
- Check logs for startup errors.
```bash
kubectl logs <pod-name> -n workflows --previous
```

**ALB not created (empty ingress address):**
- Check ALB controller logs and IAM permissions.
```bash
kubectl describe ingress -n workflows | grep -A10 Events
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller --tail=100
```

**IRSA not working (AccessDenied errors):**
- Verify OIDC provider ARN in Terraform matches the cluster.
```bash
# Get current cluster OIDC
aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
  --query "cluster.identity.oidc.issuer" --output text

# Check IAM role trust policy
aws iam get-role --role-name workflows-prod-workloads-role \
  --query 'Role.AssumeRolePolicyDocument' | jq .
```

**"Invalid or expired token" auth errors:**
- Server missing Cognito config. Check:
```bash
kubectl exec deployment/workflows-server -n workflows -- printenv | grep -i cognito
```

### Restart Deployments

```bash
# Restart all
kubectl rollout restart deployment -n workflows

# Restart specific
kubectl rollout restart deployment workflows-server -n workflows

# Watch rollout status
kubectl rollout status deployment workflows-server -n workflows
```

### Port Forwarding for Local Testing

```bash
# Access server directly (bypass ALB)
kubectl port-forward deployment/workflows-server 3001:3001 -n workflows

# Access web directly
kubectl port-forward deployment/workflows-web 3000:3000 -n workflows

# Then test locally
curl http://localhost:3001/health
```

## Related Documentation

- [DEPLOY-EKS.md](./DEPLOY-EKS.md) - Detailed EKS deployment guide with troubleshooting
- [Terraform README](terraform/README.md) - Infrastructure as code details
- [CDK README](aws-cdk/README.md) - Alternative to Terraform
- [AWS-CUSTOMER-DEPLOYMENT-GUIDE.md](./AWS-CUSTOMER-DEPLOYMENT-GUIDE.md) - Customer-facing guide
