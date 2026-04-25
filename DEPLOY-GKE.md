# Work in progress
Do not follow this guide yet

# Deploying to Google Kubernetes Engine (GKE)

This guide walks you through deploying the Workflows application to GKE.

## Prerequisites

- Google Cloud account with billing enabled
- `gcloud` CLI installed and configured
- `kubectl` installed
- `helm` installed
- `docker` installed
- Domain name with DNS management access

## Architecture Overview

```
                    ┌─────────────────────────────────────────────────────┐
                    │                  Google Cloud                        │
                    │                                                       │
   Internet         │  ┌─────────────┐    ┌─────────────────────────────┐ │
       │            │  │   Cloud     │    │         GKE Cluster          │ │
       │            │  │   Load      │    │                               │ │
       ▼            │  │  Balancer   │    │  ┌─────┐  ┌──────┐  ┌──────┐ │ │
   ┌───────┐        │  │  (Ingress)  │───▶│  │ Web │  │Server│  │Worker│ │ │
   │ Users │───────▶│  └─────────────┘    │  └─────┘  └──────┘  └──────┘ │ │
   └───────┘        │                      │      │        │        │     │ │
                    │                      │      ▼        ▼        ▼     │ │
                    │                      │  ┌─────────────────────────┐ │ │
                    │                      │  │    Cloud SQL / Neon     │ │ │
                    │                      │  └─────────────────────────┘ │ │
                    │                      └─────────────────────────────┘ │
                    │                                                       │
                    │  ┌─────────────┐    ┌─────────────────────────────┐ │
                    │  │  Container  │    │      Secret Manager          │ │
                    │  │  Registry   │    │                               │ │
                    │  └─────────────┘    └─────────────────────────────┘ │
                    └─────────────────────────────────────────────────────┘
```

## Step 1: Set Up Google Cloud Project

```bash
# Set your project ID
export PROJECT_ID="your-project-id"
export REGION="us-central1"
export ZONE="us-central1-a"

# Configure gcloud
gcloud config set project $PROJECT_ID
gcloud config set compute/region $REGION
gcloud config set compute/zone $ZONE

# Enable required APIs
gcloud services enable \
  container.googleapis.com \
  containerregistry.googleapis.com \
  secretmanager.googleapis.com \
  compute.googleapis.com \
  servicenetworking.googleapis.com
```

## Step 2: Create GKE Cluster

```bash
# Create a GKE Autopilot cluster (recommended for production)
gcloud container clusters create-auto workflows-cluster \
  --region=$REGION \
  --release-channel=regular

# Or create a Standard cluster for more control
gcloud container clusters create workflows-cluster \
  --region=$REGION \
  --num-nodes=3 \
  --machine-type=e2-standard-4 \
  --enable-autoscaling \
  --min-nodes=2 \
  --max-nodes=10 \
  --enable-autorepair \
  --enable-autoupgrade \
  --workload-pool=$PROJECT_ID.svc.id.goog

# Get cluster credentials
gcloud container clusters get-credentials workflows-cluster --region=$REGION
```

## Step 3: Set Up Container Registry

```bash
# Configure Docker to use gcloud as credential helper
gcloud auth configure-docker

# Or use Artifact Registry (recommended)
gcloud artifacts repositories create workflows \
  --repository-format=docker \
  --location=$REGION \
  --description="Workflows application images"

gcloud auth configure-docker $REGION-docker.pkg.dev
```

## Step 4: Build and Push Docker Images

```bash
# Set image tags
export TAG=$(git rev-parse --short HEAD)
export REGISTRY="gcr.io/$PROJECT_ID"
# Or for Artifact Registry:
# export REGISTRY="$REGION-docker.pkg.dev/$PROJECT_ID/workflows"

# Build and push server
docker build -t $REGISTRY/server:$TAG -f apps/server/Dockerfile .
docker push $REGISTRY/server:$TAG

# Build and push web
docker build -t $REGISTRY/web:$TAG -f apps/web/Dockerfile .
docker push $REGISTRY/web:$TAG

# Build and push worker
docker build -t $REGISTRY/worker:$TAG -f apps/worker/Dockerfile .
docker push $REGISTRY/worker:$TAG

# Tag as latest
docker tag $REGISTRY/server:$TAG $REGISTRY/server:latest
docker tag $REGISTRY/web:$TAG $REGISTRY/web:latest
docker tag $REGISTRY/worker:$TAG $REGISTRY/worker:latest
docker push $REGISTRY/server:latest
docker push $REGISTRY/web:latest
docker push $REGISTRY/worker:latest
```

## Step 5: Set Up Secrets in Secret Manager

```bash
# Create secrets in Secret Manager
gcloud secrets create PG_BASE_URL --replication-policy="automatic"
echo -n "postgresql://user:pass@host:5432/db" | \
  gcloud secrets versions add PG_BASE_URL --data-file=-

gcloud secrets create ANTHROPIC_API_KEY --replication-policy="automatic"
echo -n "your-anthropic-key" | \
  gcloud secrets versions add ANTHROPIC_API_KEY --data-file=-

gcloud secrets create OPENAI_API_KEY --replication-policy="automatic"
echo -n "your-openai-key" | \
  gcloud secrets versions add OPENAI_API_KEY --data-file=-

# Repeat for other secrets:
# - NEON_API_KEY
# - TEMPORAL_API_KEY
# - ELEVENLABS_API_KEY
# - CEREBRAS_API_KEY
# - FIREBASE_PROJECT_ID
# - FIREBASE_PRIVATE_KEY
# - FIREBASE_CLIENT_EMAIL
```

## Step 6: Configure Workload Identity (Recommended)

```bash
# Create Kubernetes service account
kubectl create namespace workflows
kubectl create serviceaccount workflows-sa -n workflows

# Create GCP service account
gcloud iam service-accounts create workflows-gsa \
  --display-name="Workflows Service Account"

# Grant Secret Manager access
gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:workflows-gsa@$PROJECT_ID.iam.gserviceaccount.com" \
  --role="roles/secretmanager.secretAccessor"

# Link Kubernetes SA to GCP SA
gcloud iam service-accounts add-iam-policy-binding \
  workflows-gsa@$PROJECT_ID.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:$PROJECT_ID.svc.id.goog[workflows/workflows-sa]"

# Annotate Kubernetes SA
kubectl annotate serviceaccount workflows-sa \
  -n workflows \
  iam.gke.io/gcp-service-account=workflows-gsa@$PROJECT_ID.iam.gserviceaccount.com
```

## Step 7: Create Kubernetes Secrets

Option A: Use External Secrets Operator (Recommended)

```bash
# Install External Secrets Operator
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace

# Create SecretStore
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: SecretStore
metadata:
  name: gcp-secret-store
  namespace: workflows
spec:
  provider:
    gcpsm:
      projectID: $PROJECT_ID
EOF

# Create ExternalSecret
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata:
  name: app-secrets
  namespace: workflows
spec:
  refreshInterval: 1h
  secretStoreRef:
    kind: SecretStore
    name: gcp-secret-store
  target:
    name: app-secrets
  data:
    - secretKey: PG_BASE_URL
      remoteRef:
        key: PG_BASE_URL
    - secretKey: ANTHROPIC_API_KEY
      remoteRef:
        key: ANTHROPIC_API_KEY
    - secretKey: OPENAI_API_KEY
      remoteRef:
        key: OPENAI_API_KEY
    # Add other secrets...
EOF
```

Option B: Create secrets directly (for testing)

```bash
kubectl create secret generic app-secrets -n workflows \
  --from-literal=PG_BASE_URL="postgresql://..." \
  --from-literal=ANTHROPIC_API_KEY="..." \
  --from-literal=OPENAI_API_KEY="..."
```

## Step 8: Reserve Static IP and Configure DNS

```bash
# Reserve a global static IP
gcloud compute addresses create workflows-ip --global

# Get the IP address
gcloud compute addresses describe workflows-ip --global --format="get(address)"

# Configure your DNS:
# A record: app.workflows.example.com -> <IP_ADDRESS>
# A record: api.workflows.example.com -> <IP_ADDRESS>
```

## Step 9: Configure Helm Values

```bash
# Copy and customize the GKE values file
cp helm/workflows/gke-values.yaml my-gke-values.yaml

# Edit my-gke-values.yaml with your values:
# - global.imageRegistry: Your GCR/Artifact Registry (e.g., gcr.io/my-project)
# - ingress.hosts[0].host: Your domain
# - ingress.annotations: Static IP name, managed certificate name
# - database.external.host: Your Cloud SQL endpoint
# - serviceAccount.annotations: Your GCP service account for Workload Identity
# - secrets.existingSecret: workflows-app-secrets (from External Secrets)
```

## Step 10: Deploy to GKE

```bash
# Install with Helm
helm install workflows helm/workflows \
  -f my-gke-values.yaml \
  -n workflows \
  --create-namespace

# Watch the deployment
kubectl get pods -n workflows -w

# Check ingress status (may take 5-10 minutes for GCE ingress)
kubectl get ingress -n workflows

# Check managed certificate status (if using Google-managed certs)
kubectl get managedcertificate -n workflows
```

To upgrade an existing installation:

```bash
helm upgrade workflows helm/workflows \
  -f my-gke-values.yaml \
  -n workflows
```

## Step 11: Verify Deployment

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
curl https://api.workflows.example.com/health
```

## CI/CD with Cloud Build

Create `cloudbuild.yaml` for automated deployments:

```yaml
steps:
  # Build images
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', 'gcr.io/$PROJECT_ID/server:$SHORT_SHA', '-f', 'apps/server/Dockerfile', '.']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', 'gcr.io/$PROJECT_ID/web:$SHORT_SHA', '-f', 'apps/web/Dockerfile', '.']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['build', '-t', 'gcr.io/$PROJECT_ID/worker:$SHORT_SHA', '-f', 'apps/worker/Dockerfile', '.']

  # Push images
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'gcr.io/$PROJECT_ID/server:$SHORT_SHA']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'gcr.io/$PROJECT_ID/web:$SHORT_SHA']
  - name: 'gcr.io/cloud-builders/docker'
    args: ['push', 'gcr.io/$PROJECT_ID/worker:$SHORT_SHA']

  # Get GKE credentials
  - name: 'gcr.io/cloud-builders/gke-deploy'
    args:
      - prepare
      - --location=$_REGION
      - --cluster=workflows-cluster

  # Deploy with Helm
  - name: 'gcr.io/cloud-builders/gcloud'
    entrypoint: 'bash'
    args:
      - '-c'
      - |
        curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
        gcloud container clusters get-credentials workflows-cluster --region $_REGION
        helm upgrade --install workflows helm/workflows \
          -f my-gke-values.yaml \
          -n workflows \
          --set server.image.tag=$SHORT_SHA \
          --set web.image.tag=$SHORT_SHA \
          --set worker.image.tag=$SHORT_SHA

substitutions:
  _REGION: us-central1

images:
  - 'gcr.io/$PROJECT_ID/server:$SHORT_SHA'
  - 'gcr.io/$PROJECT_ID/web:$SHORT_SHA'
  - 'gcr.io/$PROJECT_ID/worker:$SHORT_SHA'
```

## Monitoring and Logging

```bash
# Enable Cloud Monitoring
gcloud container clusters update workflows-cluster \
  --region=$REGION \
  --enable-managed-prometheus

# View logs in Cloud Logging
# Go to: https://console.cloud.google.com/logs/query

# Set up alerts in Cloud Monitoring
# Go to: https://console.cloud.google.com/monitoring/alerting
```

## Scaling

```bash
# Manual scaling
kubectl scale deployment workflows-server -n workflows --replicas=5

# HPA is already configured, but you can adjust:
kubectl edit hpa workflows-server-hpa -n workflows

# View current scaling
kubectl get hpa -n workflows
```

## Troubleshooting

### Pods not starting
```bash
kubectl describe pod <pod-name> -n workflows
kubectl logs <pod-name> -n workflows --previous
```

### Ingress not working
```bash
kubectl describe ingress workflows-ingress -n workflows
# Check GCE backend health
gcloud compute backend-services list
gcloud compute backend-services get-health <backend-name> --global
```

### Certificate issues
```bash
kubectl describe managedcertificate workflows-cert -n workflows
# Certificate provisioning can take up to 60 minutes
```

## Cleanup

```bash
# Delete the deployment
helm uninstall workflows -n workflows

# Delete the cluster
gcloud container clusters delete workflows-cluster --region=$REGION

# Delete static IP
gcloud compute addresses delete workflows-ip --global

# Delete secrets
gcloud secrets delete PG_BASE_URL
# ... delete other secrets
```

## Cost Optimization Tips

1. **Use Autopilot**: Pay only for resources pods actually use
2. **Use Preemptible/Spot VMs**: For non-critical workloads like workers
3. **Right-size resources**: Monitor and adjust CPU/memory requests
4. **Use committed use discounts**: For predictable baseline workloads
5. **Enable cluster autoscaler**: Scale down during low traffic periods
