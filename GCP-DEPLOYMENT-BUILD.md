# GCP Deployment — Build & Provision (Helm-only, cross-project)

Everything you do **once** (or whenever the code changes): create the cloud
resources the chart expects, and build and publish the images.

Deploying the chart itself lives in
[GCP-DEPLOYMENT-QUICK-GUIDE.md](./GCP-DEPLOYMENT-QUICK-GUIDE.md). Work through
this document first — the quick guide assumes the cluster exists, the images are
pushed, and (for anything touching files or encryption) the buckets, keys and
service account are in place.

This is the **no-Terraform** path, meant for testing. For production use the full
[GCP-DEPLOYMENT-GUIDE.md](./GCP-DEPLOYMENT-GUIDE.md) + Terraform, which
provisions all of the below reproducibly and emits the exact values the chart
consumes.

Cross-project layout:

- **Images** live in the **`ensemble-workflows`** project (Artifact Registry).
- **The cluster and everything at runtime** live in the **`automator-502518`** project.

```
images: ensemble-workflows (Artifact Registry)
                 │  (cross-project pull grant)
                 ▼
cluster + infra: automator-502518 (GKE, secrets, GCS, KMS, Firebase)
```

## Prerequisites

- `gcloud`, `kubectl` (+ `gke-gcloud-auth-plugin`), `helm`, `docker`
- Owner/Editor on **both** projects (push in `ensemble-workflows`, deploy in `automator-502518`)
- Billing enabled on both

## Step 1: Environment + auth

```bash
gcloud auth login

export DEPLOY_PROJECT=automator-502518
export IMAGE_PROJECT=ensemble-workflows
export REGION=us-west1
export CLUSTER_NAME=ensemble-workflows
export AR_REGISTRY=$REGION-docker.pkg.dev/$IMAGE_PROJECT

gcloud config set project $DEPLOY_PROJECT
gcloud services enable container.googleapis.com --project $DEPLOY_PROJECT
gcloud services enable artifactregistry.googleapis.com --project $IMAGE_PROJECT
```

## Step 2: GKE cluster (in automator-502518)

```bash
# Autopilot. If the default VPC is custom-mode, pass --network/--subnetwork
# (find the subnet with: gcloud compute networks subnets list --network=default
#  --filter="region:( $REGION )" --project $DEPLOY_PROJECT).
gcloud container clusters create-auto $CLUSTER_NAME \
  --region $REGION --project $DEPLOY_PROJECT \
  --network default --subnetwork default

gcloud container clusters get-credentials $CLUSTER_NAME --region $REGION --project $DEPLOY_PROJECT
kubectl get nodes
```

## Step 3: Images in ensemble-workflows + cross-project pull grant

```bash
# 3a. Create the repo and push images (into ensemble-workflows)
gcloud artifacts repositories create workflows \
  --repository-format=docker --location=$REGION --project=$IMAGE_PROJECT \
  --description="Workflows platform images" || true

gcloud auth configure-docker $REGION-docker.pkg.dev
# docker-compose.yml reads IMAGE_REGISTRY for the push destination (the registry
# prefix). Point it at Artifact Registry.
export IMAGE_REGISTRY=$AR_REGISTRY TAG=latest
docker compose build && docker compose push

# 3b. CRITICAL: let the cluster's NODE service account pull cross-project.
# GKE pulls images as the node SA (the default compute SA), NOT the Workload
# Identity SA. Skip this and pods fail with ImagePullBackOff.
PROJECT_NUMBER=$(gcloud projects describe $DEPLOY_PROJECT --format='value(projectNumber)')
NODE_SA="${PROJECT_NUMBER}-compute@developer.gserviceaccount.com"

gcloud artifacts repositories add-iam-policy-binding workflows \
  --location=$REGION --project=$IMAGE_PROJECT \
  --member="serviceAccount:${NODE_SA}" \
  --role="roles/artifactregistry.reader"
```

Re-run **3a** (build + push) whenever the code changes. The grant in 3b is
one-time.

## Step 4: Firebase / Identity Platform

Enable it once in the console (Console → Identity Platform → **Enable**) and
register a web app. That gives you `FIREBASE_API_KEY` / `MESSAGING_SENDER_ID` /
`APP_ID`, which fill the `web.config` fields marked
`REPLACE_FROM_FIREBASE_WEB_APP` in `gke-test-values.yaml`.

Server-side credentials are covered in Step 5 — the short version is that
Workload Identity (Step 6) is preferred over an explicit key.

## Step 5: Namespace + secrets

The deployer running the quick guide does **not** create these. Everything the
chart reads at runtime has to exist before they run `helm install`.

```bash
kubectl create namespace workflows
```

The chart mounts a k8s Secret named `app-secrets` (via `envFrom`), so the Secret
**must be named `app-secrets`** in the `workflows` namespace.

### 5.1 Required secrets

The minimum to boot: `PG_BASE_URL` (the checkpoint-saver init is critical and
needs your Neon DB; the pre-install migration Job also needs it) and
`TEMPORAL_API_KEY`.

```bash
kubectl create secret generic app-secrets -n workflows \
  --from-literal=PG_BASE_URL='postgresql://user:pass@host:5432/db' \
  --from-literal=TEMPORAL_API_KEY='...' \
  --from-literal=OPENAI_API_KEY='...' \
  --from-literal=ANTHROPIC_API_KEY='...'
```

> `OPENAI_API_KEY` is not optional if you use knowledge bases — embeddings are a
> separate credential from the chat models, and ingestion fails without it even
> when every LLM is configured.

### 5.2 Firebase Admin credentials (usually NOT needed)

The server verifies Firebase ID tokens with the Firebase Admin SDK, but it
**falls back to Application Default Credentials (ADC)** when the explicit vars
aren't set (`apps/server/src/firebase.ts`). On GKE that ADC comes from the
workload's service account, so:

- **Recommended:** leave `FIREBASE_CLIENT_EMAIL` / `FIREBASE_PRIVATE_KEY` **out**
  of the Secret and rely on **Workload Identity** (Step 6). The workloads SA needs
  the `roles/firebaseauth.admin` (or `roles/firebase.sdkAdminServiceAgent`) role
  on the Firebase project. This is the "✅ Firebase Admin initialized with
  Application Default Credentials" path.
- **Only if you want explicit creds:** download a service-account key
  (Firebase Console → Project Settings → Service Accounts → **Generate new private
  key** → a JSON), then add the three vars. Because the app does
  `FIREBASE_PRIVATE_KEY.replace(/\\n/g, '\n')`, provide the key with **escaped
  `\n`** (single line) and create it from a file to avoid shell/newline mangling:

  ```bash
  # extract the escaped private key from the downloaded serviceAccount.json
  jq -r '.private_key' serviceAccount.json | awk '{printf "%s\\n", $0}' > fb_key.txt

  kubectl create secret generic app-secrets -n workflows \
    --from-literal=PG_BASE_URL='postgresql://...' \
    --from-literal=TEMPORAL_API_KEY='...' \
    --from-literal=FIREBASE_PROJECT_ID='automator-502518' \
    --from-literal=FIREBASE_CLIENT_EMAIL='firebase-adminsdk-xxx@automator-502518.iam.gserviceaccount.com' \
    --from-file=FIREBASE_PRIVATE_KEY=fb_key.txt
  rm fb_key.txt
  ```

### 5.3 Updating the Secret later

`kubectl create secret` fails if it already exists. To change a value, re-apply:

```bash
kubectl create secret generic app-secrets -n workflows \
  --from-literal=PG_BASE_URL='...' --from-literal=TEMPORAL_API_KEY='...' \
  --dry-run=client -o yaml | kubectl apply -n workflows -f -

kubectl rollout restart deployment -n workflows   # pods pick up changes on restart
```

> **Note:** the `app-secrets` Secret is mounted with `envFrom`, so pods only read
> it at start. After any change, `kubectl rollout restart` is required — a
> `helm upgrade` alone will not pick it up.

## Step 6: Storage + encryption + Workload Identity

The app boots and serves `/health` without these, so you can defer them and come
back. But any feature that touches **file storage** or
**secret/connection/environment encryption** errors until the buckets, keys and
Workload Identity binding exist.

```bash
# --- GCS buckets (deploy project) ---
for b in user-files documents tenant-migrations; do
  gcloud storage buckets create gs://ensemble-workflows-$b \
    --location=$REGION --project=$DEPLOY_PROJECT --uniform-bucket-level-access
done

# --- KMS key ring + keys (deploy project) ---
gcloud services enable cloudkms.googleapis.com --project $DEPLOY_PROJECT
gcloud kms keyrings create workflows-keyring --location=$REGION --project=$DEPLOY_PROJECT
for k in secrets connections environment; do
  gcloud kms keys create workflows-$k --keyring=workflows-keyring \
    --location=$REGION --purpose=encryption --project=$DEPLOY_PROJECT
done

# --- Workloads service account + Workload Identity binding ---
gcloud iam service-accounts create workflows-workloads \
  --display-name="Workflows workloads" --project=$DEPLOY_PROJECT
WORKLOADS_SA="workflows-workloads@$DEPLOY_PROJECT.iam.gserviceaccount.com"

# grant it access to the buckets and KMS keys
for b in user-files documents tenant-migrations; do
  gcloud storage buckets add-iam-policy-binding gs://ensemble-workflows-$b \
    --member="serviceAccount:$WORKLOADS_SA" --role="roles/storage.objectAdmin"
done
for k in secrets connections environment; do
  gcloud kms keys add-iam-policy-binding workflows-$k --keyring=workflows-keyring \
    --location=$REGION --project=$DEPLOY_PROJECT \
    --member="serviceAccount:$WORKLOADS_SA" \
    --role="roles/cloudkms.cryptoKeyEncrypterDecrypter"
done
# Vertex AI (Gemini / vertex-anthropic), if used
gcloud projects add-iam-policy-binding $DEPLOY_PROJECT \
  --member="serviceAccount:$WORKLOADS_SA" --role="roles/aiplatform.user"

# bind the k8s SA (workflows/workflows-sa) to the GCP SA
gcloud iam service-accounts add-iam-policy-binding $WORKLOADS_SA \
  --project=$DEPLOY_PROJECT --role="roles/iam.workloadIdentityUser" \
  --member="serviceAccount:$DEPLOY_PROJECT.svc.id.goog[workflows/workflows-sa]"
```

Creating the binding is only half of it — the chart also has to *claim* it.
**Uncomment the `serviceAccount.annotations` block** in `gke-test-values.yaml`:

```yaml
serviceAccount:
  create: true
  name: workflows-sa
  annotations:
    iam.gke.io/gcp-service-account: workflows-workloads@automator-502518.iam.gserviceaccount.com
```

Commit that change so the deployer picks it up. If the chart is already
installed, roll it out:

```bash
helm upgrade workflows infrastructure/helm/workflows \
  -f infrastructure/helm/workflows/gke-test-values.yaml -n workflows
kubectl rollout restart deployment -n workflows
```

Until this is done, file storage and secret/connection/environment encryption
error at runtime even though the pods are healthy and `/health` returns 200.

## Step 7 (optional): Self-host Temporal (Helm)

Run Temporal in the cluster instead of Temporal Cloud, backed by the same
Cloud SQL Postgres. Uses the official chart (`temporalio/helm-charts`); the
values live in `infrastructure/gke-temporal-values.yaml`.

This is a backing service the app depends on, so it belongs here rather than with
the app deploy — install it before (or alongside) the chart.

```bash
# 7a. Password secret (key POSTGRES_PWD must match the DB user the values use)
kubectl create secret generic temporal-db -n workflows \
  --from-literal=POSTGRES_PWD='<db-user-password>'

# 7b. Get the chart (v1.6.0+ tested) and install. Release name MUST be "temporal"
#     so the frontend Service is "temporal-frontend".
git clone https://github.com/temporalio/helm-charts.git infrastructure/temporalio
helm install temporal infrastructure/temporalio/charts/temporal -n workflows \
  -f infrastructure/gke-temporal-values.yaml --timeout 8m

# 7c. Register the custom search attributes the app uses (the chart makes the
#     namespace but not these). Without them, StartWorkflow is rejected.
kubectl exec -n workflows deploy/temporal-admintools -- sh -c '
  temporal operator search-attribute create --namespace default --name TenantId --type Keyword
  temporal operator search-attribute create --namespace default --name UserId --type Keyword'
```

> The `workflows` namespace must already exist (Step 5).

Point the app at it (already set in `gke-test-values.yaml`):

```yaml
TEMPORAL_HOST: temporal-frontend:7233
TEMPORAL_TLS: "false" # in-cluster plaintext; no API key
```

Gotchas we hit (all reflected in the values / wiring):

- **DB user is `postgres`, not `app`.** The chart authenticates with the user in
  `server.config.persistence.datastores.*.sql.user`; it must match whatever the
  app's `PG_BASE_URL` uses (a wrong user gives "password authentication failed"
  even when the password is right). That user needs `CREATEDB` (Cloud SQL grants
  this to users you create) so the pre-install schema Job can create the
  `temporal` and `temporal_visibility` databases.
- **Chart v1.6.0 restructured persistence.** There are no `cassandra` /
  `elasticsearch` / `prometheus` top-level toggles anymore; the driver is chosen
  by putting a `sql:` block under each datastore. Postgres provides advanced
  visibility, so no Elasticsearch is needed. Older `cassandra.enabled: false`
  style values fail validation.
- **`numHistoryShards` is immutable.** Set once (512) and never change it.
- **Server and worker must share a task queue** (`dynamic-workflow-task-queue-gcp`),
  or started workflows never execute.
- **Cloud SQL over private IP is plaintext** (`tls.enabled: false`), same as the
  app; no cert wiring needed for Temporal.
- The schema Job is a **pre-install hook**, so `helm install` blocks on it; use
  `--timeout 8m`. If it fails, check `kubectl logs job/temporal-schema`.

Temporal Web UI: `kubectl port-forward svc/temporal-web 8233:8080 -n workflows`.

## What this guide does not provision

- **Postgres** and **Temporal** are external by default (Neon + Temporal Cloud);
  only their credentials go into the `app-secrets` Secret at deploy time. To
  self-host instead, use Cloud SQL (private IP) for Postgres and Step 7 for
  Temporal.

## Cleanup

There is no Terraform state, so delete by hand. Remove the app first
(`helm uninstall workflows -n workflows`), then the resources created here:

```bash
gcloud container clusters delete $CLUSTER_NAME --region $REGION --project $DEPLOY_PROJECT

for b in user-files documents tenant-migrations; do
  gcloud storage rm -r gs://ensemble-workflows-$b
done

gcloud iam service-accounts delete \
  workflows-workloads@$DEPLOY_PROJECT.iam.gserviceaccount.com --project=$DEPLOY_PROJECT

gcloud artifacts repositories delete workflows --location=$REGION --project=$IMAGE_PROJECT
```

> KMS keys cannot be deleted, only **destroyed by version** and the key ring
> stays. If you plan to rebuild into the same region, expect the existing
> `workflows-keyring` to still be there.

## Next

→ [GCP-DEPLOYMENT-QUICK-GUIDE.md](./GCP-DEPLOYMENT-QUICK-GUIDE.md) to deploy the
chart.
