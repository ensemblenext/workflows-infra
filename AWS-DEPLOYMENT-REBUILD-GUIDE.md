# AWS Deployment Rebuild Guide

This guide covers rebuilding AWS infrastructure components when they've been deleted but the EKS cluster still exists.

## Prerequisites

```bash
export AWS_PROFILE=ensemble
export AWS_REGION=us-west-2
export CLUSTER_NAME=workflows-prod
export AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
```

## Rebuild RDS PostgreSQL Database

### Step 1: Get VPC and Subnet Information

```bash
# Get EKS cluster VPC config
aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
  --query "cluster.resourcesVpcConfig"

# List subnets with details
aws ec2 describe-subnets --region $AWS_REGION \
  --filters "Name=vpc-id,Values=<VPC_ID>" \
  --query "Subnets[*].{SubnetId:SubnetId,AZ:AvailabilityZone,Name:Tags[?Key=='Name']|[0].Value,Public:MapPublicIpOnLaunch}" \
  --output table
```

### Step 2: Create Security Group for RDS

```bash
# Create security group
aws ec2 create-security-group \
  --group-name workflows-rds-sg \
  --description "Security group for Workflows RDS PostgreSQL" \
  --vpc-id vpc-045471c06abf47780 \
  --region $AWS_REGION

# Allow PostgreSQL from EKS cluster security group
aws ec2 authorize-security-group-ingress \
  --group-id <RDS_SG_ID> \
  --protocol tcp \
  --port 5432 \
  --source-group <EKS_CLUSTER_SG_ID> \
  --region $AWS_REGION
```

**Current values:**
- VPC: `vpc-045471c06abf47780`
- RDS Security Group: `sg-02aab856a5d2c3b50`
- EKS Cluster Security Group: `sg-00b238b9190f67b83`

### Step 3: Create DB Subnet Group

```bash
# Use private subnets only
aws rds create-db-subnet-group \
  --db-subnet-group-name workflows-prod-db-subnet \
  --db-subnet-group-description "Workflows prod DB subnets" \
  --subnet-ids subnet-00caf6ad99f7869f8 subnet-0b542454116cff447 subnet-071c2c25db12ee54e \
  --region $AWS_REGION
```

**Private subnets:**
| AZ | Subnet ID | CIDR |
|----|-----------|------|
| us-west-2b | subnet-00caf6ad99f7869f8 | 192.168.160.0/19 |
| us-west-2c | subnet-0b542454116cff447 | 192.168.128.0/19 |
| us-west-2d | subnet-071c2c25db12ee54e | 192.168.96.0/19 |

### Step 4: Create RDS Instance

```bash
# Check available PostgreSQL versions
aws rds describe-db-engine-versions --engine postgres \
  --query "DBEngineVersions[*].EngineVersion" --output text | tr '\t' '\n' | grep "^16"

# Create RDS instance (db.t3.micro for dev/small workloads)
aws rds create-db-instance \
  --db-instance-identifier workflows-prod-db \
  --db-instance-class db.t3.micro \
  --engine postgres \
  --engine-version 16.14 \
  --master-username postgres \
  --master-user-password "YOUR_SECURE_PASSWORD" \
  --allocated-storage 20 \
  --storage-type gp2 \
  --vpc-security-group-ids sg-02aab856a5d2c3b50 \
  --db-subnet-group-name workflows-prod-db-subnet \
  --db-name workflows \
  --no-publicly-accessible \
  --no-multi-az \
  --backup-retention-period 7 \
  --region $AWS_REGION
```

**Instance sizes:**
| Instance | vCPU | RAM | Use Case | Est. Cost |
|----------|------|-----|----------|-----------|
| db.t3.micro | 2 | 1 GB | Dev/Test | ~$12/month |
| db.t3.small | 2 | 2 GB | Small prod | ~$25/month |
| db.t3.medium | 2 | 4 GB | Production | ~$50/month |

**Note:** Database name is `workflows` (not `system` - it's a reserved word). The app uses `system` as a schema inside the database.

### Step 5: Wait for RDS and Get Endpoint

```bash
# Wait for instance to be available
aws rds wait db-instance-available \
  --db-instance-identifier workflows-prod-db \
  --region $AWS_REGION

# Get endpoint
aws rds describe-db-instances \
  --db-instance-identifier workflows-prod-db \
  --region $AWS_REGION \
  --query "DBInstances[0].Endpoint.Address" --output text
```

**Current endpoint:** `workflows-prod-db.c1m2omw8wa6t.us-west-2.rds.amazonaws.com`

**Connection string format:**
```
postgresql://postgres:YOUR_PASSWORD@workflows-prod-db.c1m2omw8wa6t.us-west-2.rds.amazonaws.com:5432/workflows?sslmode=require
```

## Update Secrets Manager

### Update PG_BASE_URL

```bash
# Get current secret and update PG_BASE_URL
NEW_PG_URL="postgresql://postgres:YOUR_PASSWORD@<RDS_ENDPOINT>:5432/workflows?sslmode=require"

aws secretsmanager get-secret-value \
  --secret-id workflows-prod/app-secrets \
  --region $AWS_REGION \
  --query "SecretString" --output text | \
  jq --arg pg "$NEW_PG_URL" '.PG_BASE_URL = $pg' | \
  aws secretsmanager put-secret-value \
    --secret-id workflows-prod/app-secrets \
    --secret-string file:///dev/stdin \
    --region $AWS_REGION
```

### Verify Secret Updated

```bash
aws secretsmanager get-secret-value \
  --secret-id workflows-prod/app-secrets \
  --region $AWS_REGION \
  --query "SecretString" --output text | jq '.PG_BASE_URL'
```

## Rebuild EKS Node Group

Use this when the EKS cluster exists but nodes have been deleted.

### Check Cluster Status

```bash
# Verify cluster exists
aws eks describe-cluster --name $CLUSTER_NAME --region $AWS_REGION \
  --query "cluster.{Name:name,Status:status,Endpoint:endpoint}"

# List existing node groups
eksctl get nodegroup --cluster=$CLUSTER_NAME --region=$AWS_REGION
```

### Create Node Group

```bash
eksctl create nodegroup \
  --cluster=$CLUSTER_NAME \
  --region=$AWS_REGION \
  --name=workflows-nodes \
  --node-type=t3.large \
  --nodes=1 \
  --nodes-min=1 \
  --nodes-max=2 \
  --managed \
  --node-private-networking
```

**Node sizes:**
| Instance | vCPU | RAM | Use Case |
|----------|------|-----|----------|
| t3.medium | 2 | 4 GB | Dev/Test |
| t3.large | 2 | 8 GB | Production |
| t3.xlarge | 4 | 16 GB | Heavy workloads |

### Verify Nodes

```bash
# Update kubeconfig
aws eks update-kubeconfig --name $CLUSTER_NAME --region $AWS_REGION

# Check nodes
kubectl get nodes
```

## Deploy Application

### Force Sync Secrets

```bash
kubectl annotate externalsecret app-secrets -n workflows \
  force-sync=$(date +%s) --overwrite

# Verify secrets synced
kubectl get externalsecret -n workflows
```

### Deploy with Helm

```bash
export CERT_ARN=$(aws acm list-certificates --region $AWS_REGION \
  --query "CertificateSummaryList[?contains(DomainName,'ensembleapp')].CertificateArn" \
  --output text)

helm upgrade --install workflows infrastructure/helm/workflows \
  -f infrastructure/helm/workflows/eks-values.yaml \
  -n workflows --create-namespace \
  --set global.imageRegistry="$AWS_ACCOUNT_ID.dkr.ecr.$AWS_REGION.amazonaws.com/" \
  --set ingress.tls.certificateArn="$CERT_ARN"
```

### Verify Deployment

```bash
# Watch pods
kubectl get pods -n workflows -w

# Check logs
kubectl logs -f -l app.kubernetes.io/component=server -n workflows

# Check ingress
kubectl get ingress -n workflows
```

## Cleanup (if needed)

### Delete RDS Instance

```bash
aws rds delete-db-instance \
  --db-instance-identifier workflows-prod-db \
  --skip-final-snapshot \
  --region $AWS_REGION
```

### Delete Node Group

```bash
eksctl delete nodegroup \
  --cluster=$CLUSTER_NAME \
  --name=workflows-nodes \
  --region=$AWS_REGION
```

### Delete RDS Security Group and Subnet Group

```bash
# Delete security group (after RDS is deleted)
aws ec2 delete-security-group --group-id sg-02aab856a5d2c3b50 --region $AWS_REGION

# Delete subnet group
aws rds delete-db-subnet-group \
  --db-subnet-group-name workflows-prod-db-subnet \
  --region $AWS_REGION
```
