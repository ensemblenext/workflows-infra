# Deploying to Amazon Elastic Kubernetes Service (EKS)

This guide walks you through deploying the Workflows application to AWS EKS.

## Quick Reference

```bash
# ECR login (tokens expire after 12 hours)
aws ecr get-login-password --region us-west-2 --profile ensemble | \
  docker login --username AWS --password-stdin \
  $(aws sts get-caller-identity --profile ensemble --query Account --output text).dkr.ecr.us-west-2.amazonaws.com

# Build and push all services (reads .env automatically)
docker compose build && docker compose push

# Deploy/upgrade with Helm (source .env for IMAGE_REGISTRY)
source .env && helm upgrade --install workflows helm/workflows \
  -f helm/workflows/eks-values.yaml \
  -n workflows \
  --set global.imageRegistry="$IMAGE_REGISTRY/"

# Restart deployments to pull new images
kubectl rollout restart deployment -n workflows

# Watch pods
kubectl get pods -n workflows -w

# View logs
kubectl logs -f -l app.kubernetes.io/component=server -n workflows
kubectl logs -f -l app.kubernetes.io/component=web -n workflows
kubectl logs -f -l app.kubernetes.io/component=worker -n workflows
```

## Prerequisites

- AWS account with appropriate permissions
- `aws` CLI installed and configured
- `eksctl` installed
- `kubectl` installed
- `helm` installed
- `docker` installed
- Domain name with DNS management access (Route 53 recommended)

## Deployment Overview

```
1. Configure AWS CLI & Create ECR repos
2. Create EKS cluster (eksctl)
3. Install AWS Load Balancer Controller
4. Run Terraform or CDK (creates S3 buckets, IAM roles, Cognito, Secrets Manager)
   → See: terraform/README.md or aws-cdk/README.md
5. Build & push Docker images
6. Set up secrets (External Secrets Operator)
7. Deploy Helm chart
8. Configure DNS
```

> **Note:** Step 4 (Terraform/CDK) creates supporting AWS resources including:
> - S3 buckets for storage
> - IAM roles with IRSA for pod permissions
> - Cognito User Pool (optional)
> - EventBridge Scheduler group
> - Secrets Manager secret template

## Architecture Overview

```
                    ┌─────────────────────────────────────────────────────┐
                    │                      AWS                             │
                    │                                                       │
   Internet         │  ┌─────────────┐    ┌─────────────────────────────┐ │
       │            │  │   AWS ALB   │    │         EKS Cluster          │ │
       │            │  │  (Ingress   │    │                               │ │
       ▼            │  │ Controller) │    │  ┌─────┐  ┌──────┐  ┌──────┐ │ │
   ┌───────┐        │  └─────────────┘───▶│  │ Web │  │Server│  │Worker│ │ │
   │ Users │───────▶│                      │  └─────┘  └──────┘  └──────┘ │ │
   └───────┘        │                      │      │        │        │     │ │
                    │                      │      ▼        ▼        ▼     │ │
                    │                      │  ┌─────────────────────────┐ │ │
                    │                      │  │    RDS / Neon DB        │ │ │
                    │                      │  └─────────────────────────┘ │ │
                    │                      └─────────────────────────────┘ │
                    │                                                       │
                    │  ┌─────────────┐    ┌─────────────────────────────┐ │
                    │  │     ECR     │    │    Secrets Manager          │ │
                    │  │  Registry   │    │                               │ │
                    │  └─────────────┘    └─────────────────────────────┘ │
                    └─────────────────────────────────────────────────────┘
```

## Step 0: Create AWS Credentials

`aws configure --profile ensemble`


## Step 1: Configure AWS CLI

```bash
# Set your AWS configuration
export AWS_REGION="us-west-2"
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --profile ensemble)
export CLUSTER_NAME="workflows-prod"

# Verify configuration
aws sts get-caller-identity --profile ensemble
```

## Step 2: Create ECR Repositories

```bash
# Create ECR repositories for each service
aws ecr create-repository --repository-name workflows/server --region $AWS_REGION --profile ensemble
aws ecr create-repository --repository-name workflows/web --region $AWS_REGION --profile ensemble
aws ecr create-repository --repository-name workflows/worker --region $AWS_REGION --profile ensemble

# Get ECR login
aws ecr get-login-password --region $AWS_REGION --profile ensemble | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com
```

## Step 3: Create EKS Cluster

Option A: Using eksctl (Recommended)

```bash
# Edit infrastructure/resources/aws/eks-cluster.yaml if you need to customize:
# - metadata.name: cluster name (default: workflows-prod)
# - metadata.region: AWS region (default: us-west-2)
# - managedNodeGroups: instance types, capacity, etc.

# Create the cluster (takes 15-20 minutes)
eksctl create cluster -f resources/aws/eks-cluster.yaml --profile ensemble

# Verify cluster
kubectl get nodes
```

Option B: Using AWS CLI

```bash
# Create VPC and subnets first, then:
aws eks create-cluster \
  --name $CLUSTER_NAME \
  --region $AWS_REGION \
  --kubernetes-version 1.35 \
  --role-arn arn:aws:iam::$AWS_ACCOUNT_ID:role/EKSClusterRole \
  --resources-vpc-config subnetIds=subnet-xxx,subnet-yyy,securityGroupIds=sg-xxx

# Update kubeconfig
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION
```

## Step 4: Install AWS Load Balancer Controller

```bash
# Option A: Use the policy file included in this repo
# (infrastructure/resources/aws/alb-iam-policy.json - kept up to date)

# Option B: Download the latest policy from AWS
curl -o infrastructure/resources/aws/alb-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

# Create IAM policy for ALB controller
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://resources/aws/alb-iam-policy.json \
  --profile ensemble

# Create service account with IAM role
eksctl create iamserviceaccount \
  --cluster=workflows-prod \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --region=us-west-2 \
  --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve \
  --profile ensemble

# Install ALB controller using Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=workflows-prod \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# Verify installation
kubectl get deployment -n kube-system aws-load-balancer-controller
```

### Updating the IAM Policy (if ALB controller fails with permission errors)

If you see errors like `elasticloadbalancing:DescribeListenerAttributes` not authorized:

```bash
# First, update the local policy file to the latest version
curl -o infrastructure/resources/aws/alb-iam-policy.json \
  https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/main/docs/install/iam_policy.json

# Get the policy ARN
POLICY_ARN=$(aws iam list-policies --profile ensemble \
  --query "Policies[?PolicyName=='AWSLoadBalancerControllerIAMPolicy'].Arn" --output text)

# Create a new version of the policy (AWS keeps last 5 versions)
aws iam create-policy-version \
  --policy-arn $POLICY_ARN \
  --policy-document file://infrastructure/resources/aws/alb-iam-policy.json \
  --set-as-default \
  --profile ensemble

# Restart the ALB controller to pick up the new permissions
kubectl rollout restart deployment aws-load-balancer-controller -n kube-system

# Wait and verify
sleep 30
kubectl describe ingress -n workflows | grep -A5 "Events:"
```

## Step 5: Build and Push Docker Images

### Configure .env

Docker Compose auto-loads variables from `.env` in the project root. Create this file:

```bash
# .env
IMAGE_REGISTRY=123456789.dkr.ecr.us-west-2.amazonaws.com
TAG=latest
```

Replace `123456789` with your AWS account ID. This file is gitignored.

### Build and push

```bash
# Login to ECR (tokens expire after 12 hours)
aws ecr get-login-password --region us-west-2 --profile ensemble | \
  docker login --username AWS --password-stdin \
  $(aws sts get-caller-identity --profile ensemble --query Account --output text).dkr.ecr.us-west-2.amazonaws.com

# Build and push all images
docker compose build && docker compose push
```

**Important Notes:**
- Docker Compose reads `.env` automatically - no exports needed
- All web app configuration (auth, URLs) is loaded at **runtime** via environment variables - one image works for all environments
- ECR login tokens expire after 12 hours - re-run the login command if pushes fail with 403

## Step 6: Set Up Secrets in AWS Secrets Manager

```bash
# Create secrets
aws secretsmanager create-secret \
  --name workflows/PG_BASE_URL \
  --profile ensemble \
  --secret-string "postgresql://user:pass@host:5432/db"

# Create other secrets:
# - workflows/NEON_API_KEY
# - workflows/TEMPORAL_API_KEY
# - workflows/ELEVENLABS_API_KEY
# - workflows/CEREBRAS_API_KEY
# - workflows/FIREBASE_PROJECT_ID
# - workflows/FIREBASE_PRIVATE_KEY
# - workflows/FIREBASE_CLIENT_EMAIL
```

## Step 7: Install External Secrets Operator

```bash
# Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

# Create namespace first
kubectl create namespace workflows

# Create IAM policy for secrets access (policy file: infrastructure/resources/aws/secrets-iam-policy.json)
aws iam create-policy \
  --policy-name WorkflowsSecretsPolicy \
  --policy-document file://infrastructure/resources/aws/secrets-iam-policy.json \
  --profile ensemble

# Create service account with IAM role
eksctl create iamserviceaccount \
  --cluster=workflows-prod \
  --namespace=workflows \
  --name=workflows-sa \
  --region=us-west-2 \
  --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/WorkflowsSecretsPolicy \
  --approve \
  --profile ensemble

# Create SecretStore
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
      region: us-west-2
      auth:
        jwt:
          serviceAccountRef:
            name: workflows-sa
EOF

# Create ExternalSecret
cat <<EOF | kubectl apply -f -
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
  data:
    - secretKey: PG_BASE_URL
      remoteRef:
        key: workflows/PG_BASE_URL
    - secretKey: ANTHROPIC_API_KEY
      remoteRef:
        key: workflows/ANTHROPIC_API_KEY
    - secretKey: OPENAI_API_KEY
      remoteRef:
        key: workflows/OPENAI_API_KEY
    # Add other secrets as needed...
EOF
```

## Step 8: Request SSL Certificate in ACM

```bash
# Request certificate (replace with your domain)
aws acm request-certificate \
  --domain-name "*.example.com" \
  --validation-method DNS \
  --region us-west-2 \
  --profile ensemble

# Get the certificate ARN (replace with your domain)
export CERT_ARN=$(aws acm list-certificates --region us-west-2 --profile ensemble \
  --query "CertificateSummaryList[?DomainName=='*.example.com'].CertificateArn" \
  --output text)

echo "Certificate ARN: $CERT_ARN"

# Complete DNS validation (add CNAME records to your DNS)
aws acm describe-certificate --certificate-arn $CERT_ARN --region us-west-2 --profile ensemble \
  --query "Certificate.DomainValidationOptions"
```

## Step 9: Configure Helm Values

The `helm/workflows/eks-values.yaml` is pre-configured for EKS. You just need to set your ECR registry and certificate ARN at deploy time (Step 10).

> **Runtime Configuration:** The web app loads all configuration (auth provider, URLs, etc.) at
> runtime via environment variables set in the Helm values file. This means you use the **same
> pre-built Docker images** for any environment - just configure your settings in `eks-values.yaml`.
> No need to rebuild images for different Cognito pools, domains, or auth providers.

## Step 10: Deploy to EKS

```bash
# Install with Helm
helm install workflows helm/workflows \
  -f helm/workflows/eks-values.yaml \
  -n workflows \
  --set global.imageRegistry="$AWS_ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/" \
  --set ingress.tls.certificateArn="$CERT_ARN"

# Watch the deployment
kubectl get pods -n workflows -w

# Check ingress status
kubectl get ingress -n workflows

# Get ALB DNS name
kubectl get ingress -n workflows -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}'
```

To upgrade an existing installation:

```bash
helm upgrade workflows helm/workflows \
  -f helm/workflows/eks-values.yaml \
  -n workflows \
  --set global.imageRegistry="$AWS_ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/" \
  --set ingress.tls.certificateArn="$CERT_ARN"
```

## Step 11: Deploying Code Changes

After making code changes, follow these steps to deploy:

### Quick Deploy (rebuild and restart)

```bash
# Login to ECR (tokens expire after 12 hours)
aws ecr get-login-password --region us-west-2 --profile ensemble | \
  docker login --username AWS --password-stdin \
  $(aws sts get-caller-identity --profile ensemble --query Account --output text).dkr.ecr.us-west-2.amazonaws.com

# Build and push all services (reads .env automatically)
docker compose build && docker compose push

# Restart deployments to pull new images
kubectl rollout restart deployment -n workflows

# Watch the rollout
kubectl get pods -n workflows -w
```

### Deploy with Helm upgrade (for config changes)

If you've changed Helm values (eks-values.yaml), use Helm upgrade:

```bash
source .env && helm upgrade workflows helm/workflows \
  -f helm/workflows/eks-values.yaml \
  -n workflows \
  --set global.imageRegistry="$IMAGE_REGISTRY/"

# Monitor the rollout
kubectl rollout status deployment/workflows-server -n workflows
kubectl rollout status deployment/workflows-web -n workflows
kubectl rollout status deployment/workflows-worker -n workflows
```

### Deploy individual services

To deploy only specific services:

```bash
# Server only
docker compose build server && docker compose push server
kubectl rollout restart deployment/workflows-server -n workflows

# Web only
docker compose build web && docker compose push web
kubectl rollout restart deployment/workflows-web -n workflows

# Worker only
docker compose build worker && docker compose push worker
kubectl rollout restart deployment/workflows-worker -n workflows
```

### View logs after deployment

```bash
# Server logs
kubectl logs -f -l app.kubernetes.io/component=server -n workflows

# Web logs
kubectl logs -f -l app.kubernetes.io/component=web -n workflows

# Worker logs
kubectl logs -f -l app.kubernetes.io/component=worker -n workflows
```

## Step 12: Configure DNS in Route 53

The ingress routes both web and API traffic through a single domain:
- `https://workflows-us-west-2.example.com/` → web
- `https://workflows-us-west-2.example.com/api/*` → server

```bash
# Get the ALB DNS name
ALB_DNS=$(kubectl get ingress -n workflows -o jsonpath='{.items[0].status.loadBalancer.ingress[0].hostname}')
echo "ALB DNS: $ALB_DNS"

# Get the ALB's hosted zone ID (required for alias records)
# Note: This queries by partial DNS match
ALB_ZONE_ID=$(aws elbv2 describe-load-balancers --region us-west-2 --profile ensemble \
  --query "LoadBalancers[?contains(DNSName, '$(echo $ALB_DNS | cut -d- -f1)')].CanonicalHostedZoneId" --output text)
echo "ALB Zone ID: $ALB_ZONE_ID"

# List your Route 53 hosted zones to find your zone ID
aws route53 list-hosted-zones --profile ensemble --query "HostedZones[*].{Name:Name,Id:Id}"

# Set your hosted zone ID (from the output above, e.g., /hostedzone/Z1234567890ABC -> Z1234567890ABC)
export HOSTED_ZONE_ID="YOUR_ZONE_ID"

# Create alias record
aws route53 change-resource-record-sets \
  --hosted-zone-id $HOSTED_ZONE_ID \
  --profile ensemble \
  --change-batch '{
    "Changes": [{
      "Action": "UPSERT",
      "ResourceRecordSet": {
        "Name": "workflows-us-west-2.example.com",
        "Type": "A",
        "AliasTarget": {
          "HostedZoneId": "'$ALB_ZONE_ID'",
          "DNSName": "'$ALB_DNS'",
          "EvaluateTargetHealth": true
        }
      }
    }]
  }'
```

**Using Route 53 Console (alternative):**

1. Go to [Route 53 Console](https://console.aws.amazon.com/route53)
2. Select your hosted zone
3. Click **Create Record**
4. Configure:
   - **Record name**: `aws-us-west-2` (or your subdomain)
   - **Record type**: A
   - **Alias**: Yes
   - **Route traffic to**: Application Load Balancer → us-west-2 → select your ALB
5. Click **Create records**

## Step 12: Verify Deployment

```bash
# Check all pods are running
kubectl get pods -n workflows

# Check services
kubectl get svc -n workflows

# Check ingress
kubectl get ingress -n workflows

# View logs
kubectl logs -n workflows -l app.kubernetes.io/component=server -f
kubectl logs -n workflows -l app.kubernetes.io/component=web -f
kubectl logs -n workflows -l app.kubernetes.io/component=worker -f

# Test the API health endpoint
curl https://api.your-domain.com/health
```

## CI/CD with GitHub Actions

Create `.github/workflows/deploy-eks.yaml`:

```yaml
name: Deploy to EKS

on:
  push:
    branches: [main]

env:
  AWS_REGION: us-west-2
  CLUSTER_NAME: workflows-prod
  IMAGE_REGISTRY: ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.us-west-2.amazonaws.com

jobs:
  deploy:
    runs-on: ubuntu-latest

    steps:
      - uses: actions/checkout@v4

      - name: Configure AWS credentials
        uses: aws-actions/configure-aws-credentials@v4
        with:
          aws-access-key-id: ${{ secrets.AWS_ACCESS_KEY_ID }}
          aws-secret-access-key: ${{ secrets.AWS_SECRET_ACCESS_KEY }}
          aws-region: ${{ env.AWS_REGION }}

      - name: Login to Amazon ECR
        id: login-ecr
        uses: aws-actions/amazon-ecr-login@v2

      - name: Build and push images
        env:
          IMAGE_REGISTRY: ${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.us-west-2.amazonaws.com/
          TAG: ${{ github.sha }}
        run: |
          docker compose build && docker compose push

      - name: Update kubeconfig
        run: |
          aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

      - name: Deploy to EKS with Helm
        env:
          IMAGE_TAG: ${{ github.sha }}
        run: |
          helm upgrade --install workflows helm/workflows \
            -f helm/workflows/eks-values.yaml \
            -n workflows \
            --set global.imageRegistry="${{ secrets.AWS_ACCOUNT_ID }}.dkr.ecr.us-west-2.amazonaws.com/" \
            --set server.image.tag=$IMAGE_TAG \
            --set web.image.tag=$IMAGE_TAG \
            --set worker.image.tag=$IMAGE_TAG

      - name: Verify deployment
        run: |
          kubectl rollout status deployment/workflows-server -n workflows
          kubectl rollout status deployment/workflows-web -n workflows
          kubectl rollout status deployment/workflows-worker -n workflows
```

## Monitoring with CloudWatch

```bash
# Install CloudWatch Container Insights
curl https://raw.githubusercontent.com/aws-samples/amazon-cloudwatch-container-insights/latest/k8s-deployment-manifest-templates/deployment-mode/daemonset/container-insights-monitoring/quickstart/cwagent-fluentd-quickstart.yaml | \
  sed "s/{{cluster_name}}/$CLUSTER_NAME/;s/{{region_name}}/$AWS_REGION/" | \
  kubectl apply -f -

# View logs in CloudWatch
# Go to: https://console.aws.amazon.com/cloudwatch/home?region=$AWS_REGION#logsV2:log-groups
```

## Scaling

```bash
# Manual scaling
kubectl scale deployment workflows-server -n workflows --replicas=5

# HPA is already configured, view status:
kubectl get hpa -n workflows

# Configure Cluster Autoscaler
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=cluster-autoscaler \
  --attach-policy-arn=arn:aws:iam::$AWS_ACCOUNT_ID:policy/ClusterAutoscalerPolicy \
  --approve

helm repo add autoscaler https://kubernetes.github.io/autoscaler
helm install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName=$CLUSTER_NAME \
  --set awsRegion=$AWS_REGION
```

## Troubleshooting

### Pods not starting
```bash
kubectl describe pod <pod-name> -n workflows
kubectl logs <pod-name> -n workflows --previous
```

### ImagePullBackOff / 403 Forbidden from ECR
ECR login tokens expire after 12 hours. Re-authenticate:
```bash
aws ecr get-login-password --region us-west-2 --profile ensemble | \
  docker login --username AWS --password-stdin $AWS_ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com
```

Also ensure the EKS nodes have ECR pull permissions. Add the `AmazonEC2ContainerRegistryReadOnly` policy to the node IAM role if needed.

### InvalidImageName (double slash in image URL)
If you see `//` in the image URL, check that `global.imageRegistry` in your values ends with exactly one `/`.

### Architecture Mismatch (exec format error)
If building on M1/ARM Mac for EKS (AMD64 nodes), Docker Compose is configured to build for `linux/amd64` automatically. If building manually, use:
```bash
docker compose build
```

### CrashLoopBackOff with "Cannot find module" error
The Dockerfiles are configured to run as the `node` user (uid 1000) which matches the Kubernetes `securityContext`. If you see module resolution errors:

1. Ensure the Dockerfile sets correct ownership: `RUN chown -R node:node /project`
2. Ensure `USER node` is set before the CMD
3. Rebuild and push the image

### Readiness Probe Failing (0/1 READY)
The server requires a `/health` endpoint. Verify it exists:
```bash
kubectl exec <pod-name> -n workflows -- curl -s http://localhost:3001/health
```

If missing, ensure you're using the latest server code with the health endpoint.

### ALB not provisioning
```bash
# Check ALB controller logs
kubectl logs -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check ingress events
kubectl describe ingress workflows-ingress -n workflows
```

### Secrets not syncing
```bash
# Check External Secrets status
kubectl get externalsecret -n workflows
kubectl describe externalsecret app-secrets -n workflows

# Check SecretStore connectivity
kubectl describe secretstore aws-secret-store -n workflows
```

### IAM/IRSA issues
```bash
# Verify service account annotation
kubectl describe serviceaccount workflows-sa -n workflows

# Test IAM role
kubectl run test-pod --rm -i --tty \
  --image=amazon/aws-cli \
  --serviceaccount=workflows-sa \
  -n workflows \
  -- aws sts get-caller-identity
```

### Debug Pod for Investigation
Run a debug pod with the same image to investigate issues:
```bash
# Basic debug pod
kubectl run debug --rm -it \
  --image=$AWS_ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/workflows/server:latest \
  -n workflows \
  --restart=Never \
  -- /bin/bash

# Debug pod with same env vars as deployment
kubectl run debug-env --rm -it \
  --image=$AWS_ACCOUNT_ID.dkr.ecr.us-west-2.amazonaws.com/workflows/server:latest \
  -n workflows \
  --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "debug-env",
        "image": "'$AWS_ACCOUNT_ID'.dkr.ecr.us-west-2.amazonaws.com/workflows/server:latest",
        "stdin": true,
        "tty": true,
        "command": ["/bin/bash"],
        "envFrom": [
          {"configMapRef": {"name": "workflows-config"}},
          {"secretRef": {"name": "app-secrets"}}
        ]
      }]
    }
  }' \
  -- /bin/bash
```

## Cleanup

```bash
# Delete the deployment
helm uninstall workflows -n workflows

# Delete the cluster
eksctl delete cluster --name $CLUSTER_NAME --region $AWS_REGION

# Delete ECR repositories
aws ecr delete-repository --repository-name workflows/server --force
aws ecr delete-repository --repository-name workflows/web --force
aws ecr delete-repository --repository-name workflows/worker --force

# Delete secrets
aws secretsmanager delete-secret --secret-id workflows/PG_BASE_URL --force-delete-without-recovery
# ... delete other secrets

# Delete certificate
aws acm delete-certificate --certificate-arn $CERT_ARN
```

## Static Egress IP

Your EKS cluster uses a NAT Gateway with a static Elastic IP for all outbound traffic. This IP can be whitelisted with external services.

### Check Your Egress IP

```bash
# List NAT Gateways and their Elastic IPs
aws ec2 describe-nat-gateways --region us-west-2 --profile ensemble \
  --query "NatGateways[*].{ID:NatGatewayId,State:State,ElasticIP:NatGatewayAddresses[0].PublicIp}"

# Verify from inside a pod
kubectl run curl-test --rm -it --image=curlimages/curl -n workflows --restart=Never -- curl -s ifconfig.me
```

### Tag Your Elastic IP

Tag the IP for easy identification:

```bash
# Get the allocation ID for your egress IP
EGRESS_IP="52.34.98.224"  # Replace with your IP
ALLOC_ID=$(aws ec2 describe-addresses --region us-west-2 --profile ensemble \
  --query "Addresses[?PublicIp=='$EGRESS_IP'].AllocationId" --output text)

# Tag it
aws ec2 create-tags --resources $ALLOC_ID \
  --tags Key=Name,Value=workflows-egress-ip \
  --region us-west-2 --profile ensemble
```

### Important Notes

- The Elastic IP is static and won't change unless you delete the NAT Gateway or release the IP
- Cost: ~$3.60/month (included in NAT Gateway pricing when attached)
- For multi-AZ high availability, you'd have one NAT Gateway per AZ, each with its own Elastic IP
- Document your egress IP for external service whitelisting

## Cost Optimization Tips

1. **Use Spot Instances**: For worker nodes that can handle interruptions
2. **Right-size instances**: Start with t3.medium and scale up as needed
3. **Use Savings Plans**: For predictable baseline workloads
4. **Enable Cluster Autoscaler**: Scale down during low traffic
5. **Use Fargate for bursty workloads**: Pay per pod, no node management
6. **Review NAT Gateway costs**: Consider NAT instances for dev/staging

## Multi-Region Deployment

For deploying to multiple AWS regions (e.g., us-west-2, eu-west-1, ap-southeast-1):

### Architecture Overview

```
                        ┌─────────────────┐
                        │   Route 53      │
                        │ (Global DNS)    │
                        └────────┬────────┘
                                 │
              ┌──────────────────┼──────────────────┐
              │                  │                  │
              ▼                  ▼                  ▼
    ┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
    │   us-west-2     │ │   eu-west-1     │ │ ap-southeast-1  │
    │                 │ │                 │ │                 │
    │  EKS Cluster    │ │  EKS Cluster    │ │  EKS Cluster    │
    │  ALB            │ │  ALB            │ │  ALB            │
    │  ECR            │ │  ECR            │ │  ECR            │
    │  Secrets Mgr    │ │  Secrets Mgr    │ │  Secrets Mgr    │
    │  ACM Cert       │ │  ACM Cert       │ │  ACM Cert       │
    └─────────────────┘ └─────────────────┘ └─────────────────┘
```

### Option 1: Region-Specific Subdomains (Simplest)

Use different subdomains per region:
- `workflows-us-west-2.example.com` → us-west-2 cluster
- `workflows-eu-west-1.example.com` → eu-west-1 cluster
- `workflows-ap-southeast-1.example.com` → ap-southeast-1 cluster

Your wildcard cert `*.example.com` covers all of these.

### Option 2: Route 53 Latency-Based Routing

Single domain automatically routes to nearest region:
- `workflows-us-west-2.example.com` → Route 53 latency routing → nearest ALB

### Step 1: Set Up ECR Replication

Automatically replicate images to all regions:

```bash
# Enable ECR replication from us-west-2 to other regions
aws ecr put-replication-configuration \
  --replication-configuration '{
    "rules": [
      {
        "destinations": [
          {"region": "eu-west-1", "registryId": "'$AWS_ACCOUNT_ID'"},
          {"region": "ap-southeast-1", "registryId": "'$AWS_ACCOUNT_ID'"}
        ],
        "repositoryFilters": [
          {"filter": "workflows/", "filterType": "PREFIX_MATCH"}
        ]
      }
    ]
  }' \
  --region us-west-2 \
  --profile ensemble
```

### Step 2: Create Regional Resources

For each new region, repeat these steps:

```bash
# Set the target region
export TARGET_REGION="eu-west-1"
export CLUSTER_NAME="workflows-prod-${TARGET_REGION}"

# 1. Create ECR repositories (if not using replication)
aws ecr create-repository --repository-name workflows/server --region $TARGET_REGION --profile ensemble
aws ecr create-repository --repository-name workflows/web --region $TARGET_REGION --profile ensemble
aws ecr create-repository --repository-name workflows/worker --region $TARGET_REGION --profile ensemble

# 2. Create EKS cluster config for the region
sed "s/us-west-2/$TARGET_REGION/g; s/workflows-prod/$CLUSTER_NAME/g" \
  infrastructure/resources/aws/eks-cluster.yaml > infrastructure/resources/aws/eks-cluster-${TARGET_REGION}.yaml

# 3. Create the cluster
eksctl create cluster -f infrastructure/resources/aws/eks-cluster-${TARGET_REGION}.yaml --profile ensemble

# 4. Request ACM certificate (same wildcard cert works, but certs are regional)
aws acm request-certificate \
  --domain-name "*.example.com" \
  --validation-method DNS \
  --region $TARGET_REGION \
  --profile ensemble

# 5. Create secrets in Secrets Manager for this region
aws secretsmanager create-secret --name workflows/PG_BASE_URL --secret-string "..." --region $TARGET_REGION --profile ensemble
aws secretsmanager create-secret --name workflows/ANTHROPIC_API_KEY --secret-string "..." --region $TARGET_REGION --profile ensemble
aws secretsmanager create-secret --name workflows/OPENAI_API_KEY --secret-string "..." --region $TARGET_REGION --profile ensemble

# 6. Install ALB controller, External Secrets, and deploy (same as Steps 4, 7, 10)
```

### Step 3: Create Regional Values File

Create `helm/workflows/eks-values-eu-west-1.yaml`:

```yaml
global:
  imageRegistry: "<AWS_ACCOUNT_ID>.dkr.ecr.eu-west-1.amazonaws.com/"

ingress:
  hosts:
    - host: workflows-eu-west-1.example.com
      paths:
        - path: /api
          pathType: Prefix
          service: server
        - path: /
          pathType: Prefix
          service: web
  tls:
    enabled: true
    certificateArn: "<EU_WEST_1_CERT_ARN>"

# ... rest same as eks-values.yaml
```

### Step 4: Set Up Route 53 Latency Routing (Optional)

For automatic routing to nearest region:

```bash
# Create latency-based records for each region
aws route53 change-resource-record-sets \
  --hosted-zone-id YOUR_HOSTED_ZONE_ID \
  --change-batch '{
    "Changes": [
      {
        "Action": "CREATE",
        "ResourceRecordSet": {
          "Name": "workflows-us-west-2.example.com",
          "Type": "A",
          "SetIdentifier": "us-west-2",
          "Region": "us-west-2",
          "AliasTarget": {
            "HostedZoneId": "Z1H1FL5HABSF5",
            "DNSName": "<US_WEST_2_ALB_DNS>",
            "EvaluateTargetHealth": true
          }
        }
      },
      {
        "Action": "CREATE",
        "ResourceRecordSet": {
          "Name": "workflows-us-west-2.example.com",
          "Type": "A",
          "SetIdentifier": "eu-west-1",
          "Region": "eu-west-1",
          "AliasTarget": {
            "HostedZoneId": "Z32O12XQLNTSW2",
            "DNSName": "<EU_WEST_1_ALB_DNS>",
            "EvaluateTargetHealth": true
          }
        }
      }
    ]
  }' \
  --profile ensemble
```

### Managing Multiple Clusters

Switch between cluster contexts:

```bash
# List all contexts
kubectl config get-contexts

# Switch to specific region
aws eks update-kubeconfig --name workflows-prod --region us-west-2 --profile ensemble --alias eks-us-west-2
aws eks update-kubeconfig --name workflows-prod-eu-west-1 --region eu-west-1 --profile ensemble --alias eks-eu-west-1

# Use specific context
kubectl config use-context eks-us-west-2
kubectl config use-context eks-eu-west-1
```

### Switching between AWS (EKS) and GCP (GKE)

`kubectl` and `helm` have no notion of cloud provider. They act on whatever
`current-context` is set in your kubeconfig (`~/.kube/config`). That selection is
**persisted to disk and shared by every shell**, so it stays put until you change
it again (not just for the current terminal).

If your context is left on a **GKE** cluster, AWS-targeted commands fail while
trying to use gcloud auth, for example:

```
print credential failed ... failure while executing gcloud ...
Reauthentication failed. cannot prompt during non-interactive execution.
```

Point kubectl/helm back at EKS before running anything in this guide:

```bash
# Refresh and select the EKS context (also sets it as current-context):
aws eks update-kubeconfig --name workflows-prod --region us-west-2 --profile ensemble

# Or, if the context already exists, just select it:
kubectl config use-context arn:aws:eks:us-west-2:<ACCOUNT_ID>:cluster/workflows-prod

# Verify (should print the arn:aws:eks... context and reach the cluster):
kubectl config current-context
kubectl get nodes
```

To target EKS for a single command without changing the global context, pass
`--kube-context <eks-context>` to helm or `--context <eks-context>` to kubectl.

### Database Considerations

For multi-region, you have options for the database:

1. **Single Region DB**: All clusters connect to one region's database (simple but adds latency)
2. **Read Replicas**: Primary in one region, read replicas in others
3. **Global Database**: Aurora Global Database or CockroachDB for multi-region writes
4. **Neon**: Supports regional deployments, create separate branches per region
