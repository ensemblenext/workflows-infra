# GCP Deployment Guide (Recommended)

This is the step-by-step guide for deploying Workflows to a fresh GCP project on
GKE, using the `terraform-gcp` stack and the `gcp-values.yaml` Helm overlay.

It mirrors the AWS guide: Terraform provisions the cloud resources, and Helm
deploys the app. One GCP **project per environment** is recommended.

## Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                     Deployment Flow                              │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  1. gcloud Setup       →  project, APIs                          │
│           ↓                                                      │
│  2. Artifact Registry  →  Docker repository                      │
│           ↓                                                      │
│  3. GKE Cluster        →  Workload Identity enabled              │
│           ↓                                                      │
│  4. Ingress Prereqs    →  static IP + Managed Certificate        │
│           ↓                                                      │
│  5. Terraform          →  KMS, GCS, IAM, Secrets, Identity Plat. │
│           ↓                                                      │
│  6. Docker Images      →  Build and push to Artifact Registry    │
│           ↓                                                      │
│  7. Secrets            →  Secret Manager + External Secrets      │
│           ↓                                                      │
│  8. Firebase / Auth    →  Identity Platform + web app config     │
│           ↓                                                      │
│  9. Helm Deploy        →  Install the application                │
│           ↓                                                      │
│  10. DNS               →  point domain at the static IP          │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## Prerequisites

- GCP project (with billing enabled) and Owner/Editor permissions
- Tools installed:
  - `gcloud` CLI
  - `kubectl` (+ `gke-gcloud-auth-plugin`)
  - `helm`
  - `docker`
  - `terraform`
  - `firebase` CLI (only for the Firebase web-app config in Step 8)

## Step 1: gcloud Setup

```bash
# Authenticate
gcloud auth login

# Environment variables
# PROJECT_ID is your GCP project id. This is DISTINCT from the Terraform
# resource-name prefix `workflows-prod` (project_name + environment) used for
# resource names like workflows-prod-keyring — do not confuse the two.
export PROJECT_ID=ensemble-workflows
export REGION=us-west1
export CLUSTER_NAME=workflows-prod
export SERVICE_ROOT_DOMAIN=ensembleapp.ai
export SERVICE_DOMAIN=gcp-us-west1.$SERVICE_ROOT_DOMAIN
export SERVICE_ENDPOINT=https://$SERVICE_DOMAIN
export AR_REGISTRY=$REGION-docker.pkg.dev/$PROJECT_ID   # matches Helm global.imageRegistry

gcloud config set project $PROJECT_ID

# Enable the API needed to create the cluster now. Terraform enables the rest
# (KMS, GCS, Secret Manager, Artifact Registry, Identity Platform) in Step 5.
gcloud services enable container.googleapis.com

# Verify
gcloud config list
```

## Step 2: Create Artifact Registry

**Option A: Via Terraform (recommended)**

Enabled by default in the tfvars (`enable_artifact_registry = true`); created in
Step 5. It creates one Docker repo `workflows` holding the server/web/worker/migration
images, with a cleanup policy keeping the last N versions.

**Option B: Via CLI (if you want it before Terraform)**

```bash
gcloud artifacts repositories create workflows \
  --repository-format=docker \
  --location=$REGION \
  --description="Workflows platform images"
```

## Step 3: Create GKE Cluster

Workload Identity is required (it replaces AWS IRSA).

```bash
# Autopilot (Workload Identity on by default, least ops) — recommended
gcloud container clusters create-auto $CLUSTER_NAME \
  --region $REGION --project $PROJECT_ID \
  --network default \
  --subnetwork default
  

# --- OR --- Standard cluster (more control)
gcloud container clusters create $CLUSTER_NAME \
  --region $REGION \
  --workload-pool=$PROJECT_ID.svc.id.goog \
  --release-channel=regular \
  --machine-type=e2-standard-4 \
  --num-nodes=1 --enable-autoscaling --min-nodes=1 --max-nodes=4

# Get credentials
gcloud container clusters get-credentials $CLUSTER_NAME --region $REGION

# Verify
kubectl get nodes
```

> **Targeting GKE with kubectl/helm.** These tools act on the `current-context` in
> your kubeconfig (`~/.kube/config`), which is **persisted to disk and shared across
> all shells** until you change it (not per-terminal). If it is left on an **EKS**
> cluster, GCP commands hit the wrong cluster; if it is on GKE but your gcloud token
> expired you will see `Reauthentication failed` (run `gcloud auth login`). The
> `get-credentials` command above refreshes auth and sets GKE as current-context;
> re-select it later with `kubectl config use-context gke_${PROJECT_ID}_${REGION}_${CLUSTER_NAME}`
> and verify with `kubectl config current-context`. Use `--kube-context` (helm) or
> `--context` (kubectl) to target it for a single command without switching globally.

> **Static outbound IP** (for whitelisting with external services like Neon/Temporal):
> configure **Cloud NAT** on the cluster's VPC and reserve a static IP for it —
> the GCP analog of the AWS NAT Gateway.

## Step 4: Ingress Prerequisites (Static IP + Managed Certificate)

GKE has a **built-in** GCE ingress controller — no controller to install (unlike
the AWS ALB controller). Instead reserve a global static IP and create a
Google-managed TLS certificate. The names must match the annotations in
`gcp-values.yaml` (`workflows-prod-ip`, `workflows-prod-cert`).

```bash
# Namespace (used by the cert, secrets, and the app)
kubectl create namespace workflows

# Reserve a global static IP for the ingress
gcloud compute addresses create workflows-prod-ip --global
gcloud compute addresses describe workflows-prod-ip --global --format='value(address)'

# Google-managed certificate for your domain
cat <<EOF | kubectl apply -n workflows -f -
apiVersion: networking.gke.io/v1
kind: ManagedCertificate
metadata:
  name: workflows-prod-cert
spec:
  domains:
    - $SERVICE_DOMAIN
EOF
```

> The certificate stays `Provisioning` until DNS points at the static IP (Step 10);
> it can take 15–60 minutes to become `Active`.

## Step 5: Run Terraform

Creates KMS keys, GCS buckets, the workloads service account (+ Workload Identity
binding), Secret Manager, Identity Platform config, and Artifact Registry.

```bash
cd infrastructure/terraform-gcp

# Create the remote-state bucket once
gsutil mb -l $REGION gs://$PROJECT_ID-tf-state

# Initialize with the GCS backend
terraform init \
  -backend-config="bucket=$PROJECT_ID-tf-state" \
  -backend-config="prefix=terraform/state"

# Edit environments/prod.tfvars: set project_id, region, firebase_authorized_domains.
# Pass secrets via env vars, NEVER in tfvars:
export TF_VAR_firebase_google_client_secret="GOCSPX-..."   # only if using Google IdP

# Plan and apply
terraform plan  -var-file=environments/prod.tfvars
terraform apply -var-file=environments/prod.tfvars

# Save the outputs — you'll wire these into gcp-values.yaml
terraform output
terraform output -json helm_config_values
terraform output -json service_account_annotation
```

**Terraform creates:**
- KMS key ring `workflows-prod-keyring` + keys `workflows-prod-{secrets,connections,environment}`
- GCS buckets: `<project>-user-files`, `<project>-documents`, `<project>-tenant-migrations`
- Service account `workflows-prod-workloads@<project>.iam.gserviceaccount.com` (+ WI binding for `workflows/workflows-sa`)
- Secret Manager secret `workflows-prod-app-secrets` (empty placeholders)
- Identity Platform config (+ optional Google IdP)
- Artifact Registry repo `workflows`

## Step 6: Build and Push Docker Images

> **Note:** Web app configuration (auth provider, URLs, Firebase settings) is loaded
> at **runtime** via environment variables — the same image works for every
> environment. No build-time config needed.

```bash
# Configure Docker auth for Artifact Registry
gcloud auth configure-docker $REGION-docker.pkg.dev

# Point docker-compose at Artifact Registry, then build + push.
# docker-compose.yml reads IMAGE_REGISTRY as the host+project; the image name
# `workflows/<comp>` is appended, which is exactly Helm's global.imageRegistry.
export IMAGE_REGISTRY=$AR_REGISTRY
export TAG=latest

docker compose build && docker compose push
```

### Reusing images from Cloud Build / Cloud Run

The container images are **runtime-configured** (no build-time config), so the
exact images you already run on Cloud Run (or that Cloud Build produces) work
unchanged on GKE. GKE vs Cloud Run is only a difference in **env vars**, not the
image (`SERVERLESS_ENVIRONMENT=false` + the KMS/storage config in `gcp-values.yaml`).

So you can **skip the build in this step** and point Helm at the existing images
instead of pushing new ones:

1. Make sure the images live in an Artifact Registry repo the GKE nodes can pull
   (the terraform-gcp `artifact-registry` module, or an existing repo). If your
   Cloud Run images are in a different project/repo, either grant the GKE node
   service account `roles/artifactregistry.reader` on that repo, or copy the
   images over:

   ```bash
   # Copy an existing image into this deployment's Artifact Registry repo
   gcloud artifacts docker tags add \
     <existing-image>:<tag> \
     $AR_REGISTRY/workflows/server:latest
   # (repeat for web / worker / migration)
   ```

2. In `gcp-values.yaml`, set `global.imageRegistry` and each component's
   `image.repository` / `image.tag` to the existing images, e.g.:

   ```yaml
   global:
     imageRegistry: "us-west1-docker.pkg.dev/ensemble-workflows"
   server:   { image: { repository: workflows/server,   tag: <your-tag> } }
   web:      { image: { repository: workflows/web,       tag: <your-tag> } }
   worker:   { image: { repository: workflows/worker,    tag: <your-tag> } }
   ```

   Then jump to Step 7 — no rebuild needed.

> **Note on the worker:** on GKE the `worker` runs as a persistent Temporal
> poller (`SERVERLESS_ENVIRONMENT=false`, already set in `gcp-values.yaml`). This
> is the same worker image as Cloud Run — only the runtime mode differs. If you
> don't run a standalone worker on Cloud Run, you still deploy it here.

## Step 7: Set Up Secrets

### Install External Secrets Operator

```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

### Create the Service Account (with the Workload Identity annotation)

```bash
# Annotation value = terraform output service_account_annotation
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  name: workflows-sa
  namespace: workflows
  annotations:
    iam.gke.io/gcp-service-account: workflows-prod-workloads@$PROJECT_ID.iam.gserviceaccount.com
EOF

# Verify
kubectl get serviceaccount workflows-sa -n workflows -o yaml
```

### Write the real secret values to Secret Manager

Terraform created `workflows-prod-app-secrets` with empty placeholders. Add a new
version with the real values (a JSON blob):

```bash
gcloud secrets versions add workflows-prod-app-secrets --data-file=- <<'EOF'
{
  "PG_BASE_URL": "postgresql://user:pass@host:5432/workflows",
  "TEMPORAL_API_KEY": "xxx",
  "FIREBASE_PROJECT_ID": "ensemble-workflows",
  "FIREBASE_CLIENT_EMAIL": "firebase-adminsdk-xxx@ensemble-workflows.iam.gserviceaccount.com",
  "FIREBASE_PRIVATE_KEY": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----\n",
  "OPENAI_API_KEY": "sk-xxx",
  "ANTHROPIC_API_KEY": "sk-ant-xxx",
  "GEMINI_API_KEY": "xxx"
}
EOF
```

### Create the SecretStore and ExternalSecret

Fill the `REPLACE_*` placeholders in
`infrastructure/helm/workflows/examples/secret-store-gcp.yaml` (project id +
cluster name), then apply it. It creates the k8s `app-secrets` secret from the
Secret Manager JSON blob via `dataFrom.extract`.

```bash
kubectl apply -f infrastructure/helm/workflows/examples/secret-store-gcp.yaml

# Verify it synced
kubectl get externalsecret -n workflows
kubectl get secret app-secrets -n workflows
```

## Step 8: Firebase / Identity Platform

Terraform manages the Identity Platform **config**, but two things are done here:

**1. Enable Identity Platform** (one-time — via Console → Identity Platform →
   Enable, or):
```bash
gcloud services enable identitytoolkit.googleapis.com
```

**2. Register a Firebase Web app** to obtain the public web config the app needs
   (`FIREBASE_API_KEY`, `MESSAGING_SENDER_ID`, `APP_ID`, `MEASUREMENT_ID`):
```bash
firebase login
firebase apps:create WEB "workflows-web" --project $PROJECT_ID
# List the app id, then print its SDK config:
firebase apps:list --project $PROJECT_ID
firebase apps:sdkconfig WEB <APP_ID> --project $PROJECT_ID
```

Put those values into the `server.config` and `web.config` `FIREBASE_*` fields in
`gcp-values.yaml`. `FIREBASE_PROJECT_ID`, `FIREBASE_AUTH_DOMAIN`
(`<project>.firebaseapp.com`), and `FIREBASE_STORAGE_BUCKET`
(`<project>.appspot.com`) are derivable and already templated.

## Step 9: Deploy Helm Chart

First replace every `REPLACE_*` placeholder in
`infrastructure/helm/workflows/gcp-values.yaml` (project id, domain, KMS/bucket
names from `terraform output helm_config_values`, and the Firebase web config).

```bash
helm install workflows infrastructure/helm/workflows \
  -f infrastructure/helm/workflows/gcp-values.yaml \
  -n workflows

# Watch deployment (a pre-install migration Job runs first)
kubectl get pods -n workflows -w
```

## Step 10: Configure DNS

```bash
# The ingress should surface the reserved static IP
kubectl get ingress -n workflows
gcloud compute addresses describe workflows-prod-ip --global --format='value(address)'
```

Create a DNS **A record** pointing `$SERVICE_DOMAIN` at that static IP. Then wait
for the managed certificate to go `Active`:

```bash
kubectl describe managedcertificate workflows-prod-cert -n workflows | grep -i status
```

## Verify Deployment

```bash
# Check pods
kubectl get pods -n workflows

# Check ingress
kubectl get ingress -n workflows

# View logs
kubectl logs -f -l app.kubernetes.io/component=server -n workflows

# Test endpoint (once DNS + cert are ready)
curl $SERVICE_ENDPOINT/api/health
```

## Quick Reference

```bash
# Docker auth for Artifact Registry
gcloud auth configure-docker $REGION-docker.pkg.dev

# Build and push
export IMAGE_REGISTRY=$AR_REGISTRY TAG=latest
docker compose build && docker compose push

# Upgrade with Helm
helm upgrade workflows infrastructure/helm/workflows \
  -f infrastructure/helm/workflows/gcp-values.yaml \
  -n workflows

# Restart pods to pull new images
kubectl rollout restart deployment -n workflows

# Rollout a specific service
kubectl rollout restart deployment workflows-web -n workflows

# Logs
kubectl logs -f deployment/workflows-server -n workflows

# Terraform (specify the env var-file)
cd infrastructure/terraform-gcp
terraform plan  -var-file=environments/prod.tfvars
terraform apply -var-file=environments/prod.tfvars
```

## Updating Secrets

The `app-secrets` k8s secret is synced from Secret Manager via `dataFrom.extract`,
so **all keys sync automatically**.

### Add / change a secret

```bash
# Add a new version by merging into the current JSON blob
gcloud secrets versions access latest --secret=workflows-prod-app-secrets \
  | jq '. + {"NEW_KEY": "new-value"}' \
  | gcloud secrets versions add workflows-prod-app-secrets --data-file=-

# Force an immediate ESO sync (else up to refreshInterval)
kubectl annotate externalsecret workflows-app-secrets -n workflows \
  force-sync=$(date +%s) --overwrite

# Restart pods to pick up the new env var
kubectl rollout restart deployment -n workflows
```

### Verify

```bash
kubectl get externalsecret -n workflows
kubectl get secret app-secrets -n workflows -o jsonpath='{.data.NEW_KEY}' | base64 -d
```

## Identity Providers Setup (Google Sign-In)

To enable "Sign in with Google" through Identity Platform:

**1. Create OAuth credentials** in the Google Cloud Console
   ([APIs & Services → Credentials](https://console.cloud.google.com/apis/credentials)):
- OAuth 2.0 Client ID (Web application)
- Authorized redirect URI:
  ```
  https://<PROJECT_ID>.firebaseapp.com/__/auth/handler
  ```
- Save the **Client ID** and **Client Secret**.

**2. Enable the provider via Terraform** (managed in the `firebase-auth` module):
```hcl
# environments/prod.tfvars
firebase_google_client_id = "xxx.apps.googleusercontent.com"
# secret passed via env:
# export TF_VAR_firebase_google_client_secret="GOCSPX-..."
```
```bash
terraform apply -var-file=environments/prod.tfvars
```

**3. Enable it in the web app** — set in `gcp-values.yaml`:
```yaml
web:
  config:
    LOGIN_GOOGLE_ENABLED: "true"
```

## Troubleshooting

### View Logs

```bash
kubectl logs -f deployment/workflows-server -n workflows
kubectl logs -f deployment/workflows-web -n workflows
kubectl logs -f deployment/workflows-worker -n workflows
kubectl logs deployment/workflows-server -n workflows --previous  # crashed container
```

### Check Pod Status

```bash
kubectl get pods -n workflows
kubectl describe pod <pod-name> -n workflows
kubectl exec deployment/workflows-server -n workflows -- printenv | sort
```

### Check Ingress / Managed Certificate

```bash
kubectl get ingress -n workflows
kubectl describe ingress -n workflows | grep -A10 Events
kubectl describe managedcertificate workflows-prod-cert -n workflows
```

### Check Secrets

```bash
kubectl get externalsecret -n workflows
kubectl describe externalsecret workflows-app-secrets -n workflows
kubectl get secretstore -n workflows
kubectl describe secretstore gcp-secret-manager -n workflows
kubectl get secret app-secrets -n workflows -o jsonpath='{.data}' \
  | jq -r 'to_entries[] | "\(.key): \(.value | @base64d)"'
```

### Common Issues

**Pods stuck in `CreateContainerConfigError`:** usually the `app-secrets` secret
isn't populated. Check the ExternalSecret/SecretStore status above.

**Pods in `CrashLoopBackOff`:** check `kubectl logs <pod> -n workflows --previous`.

**Ingress has no IP / cert stuck `Provisioning`:** confirm DNS points at the
reserved static IP; the managed cert only provisions once DNS resolves.
```bash
kubectl describe managedcertificate workflows-prod-cert -n workflows
```

**Workload Identity `PermissionDenied` (KMS/GCS/Secret Manager):**
```bash
# The KSA annotation must match the GCP SA, and the GCP SA must have the WI binding
kubectl get sa workflows-sa -n workflows -o jsonpath='{.metadata.annotations}'
gcloud iam service-accounts get-iam-policy \
  workflows-prod-workloads@$PROJECT_ID.iam.gserviceaccount.com
# Should list role roles/iam.workloadIdentityUser for
#   serviceAccount:$PROJECT_ID.svc.id.goog[workflows/workflows-sa]
```

**"Invalid or expired token" auth errors:** server missing Firebase config.
```bash
kubectl exec deployment/workflows-server -n workflows -- printenv | grep -i firebase
```

### Port Forwarding for Local Testing

```bash
kubectl port-forward deployment/workflows-server 3001:3001 -n workflows
kubectl port-forward deployment/workflows-web 3000:3000 -n workflows
curl http://localhost:3001/health
```

## Related Documentation

- [terraform-gcp/README.md](terraform-gcp/README.md) — GCP infrastructure details
- [helm/workflows/gcp-values.yaml](helm/workflows/gcp-values.yaml) — GKE Helm overlay
- [helm/workflows/examples/secret-store-gcp.yaml](helm/workflows/examples/secret-store-gcp.yaml) — External Secrets store
- [AWS-DEPLOYMENT-GUIDE.md](./AWS-DEPLOYMENT-GUIDE.md) — the AWS counterpart
