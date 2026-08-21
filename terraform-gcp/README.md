# GCP Terraform (`terraform-gcp`)

GCP equivalent of `infrastructure/terraform` (AWS). Provisions the cloud
resources the platform needs and emits the same Terraform → Helm bridge outputs,
so the Helm chart consumes GCP config the same way it consumes AWS config.

## AWS → GCP mapping

| AWS module | This module | GCP resources |
|---|---|---|
| `kms` | `kms` | Cloud KMS key ring + 3 crypto keys (secrets/connections/environment) |
| `s3` | `gcs` | 3 Cloud Storage buckets (user-files/documents/tenant-migrations) |
| `iam` (IRSA) | `iam` | Service account + **Workload Identity** binding + project roles |
| `secrets` | `secrets` | Secret Manager `app-secrets` (JSON blob, synced by External Secrets) |
| `cognito` | `firebase-auth` | **Identity Platform** config + optional Google IdP |
| `ecr` | `artifact-registry` | One Docker repo (server/web/worker/migration images) |
| `scheduler` | `scheduler` | Cloud Scheduler invoker SA + grants (⚠️ needs app support) |

## Usage

```bash
cd infrastructure/terraform-gcp

# Remote state lives in GCS. Create the state bucket once, then:
terraform init -backend-config="bucket=workflows-prod-tf-state" \
               -backend-config="prefix=terraform/state"

# Secrets go through env vars, NOT tfvars:
export TF_VAR_firebase_google_client_secret="GOCSPX-..."

terraform plan  -var-file=environments/prod.tfvars
terraform apply -var-file=environments/prod.tfvars
```

## Wiring the outputs into Helm

```bash
# Non-secret env for the chart's <component>.config:
terraform output -json helm_config_values

# ServiceAccount annotation (Workload Identity, replaces the IRSA role-arn):
terraform output -json service_account_annotation
# => { "iam.gke.io/gcp-service-account": "workflows-prod-workloads@<project>.iam.gserviceaccount.com" }
```

Helm chart changes for GKE (vs the EKS values):
- **Ingress**: class `alb` → `gce` (+ a `ManagedCertificate` instead of ACM).
- **External Secrets**: point the `SecretStore` provider at **GCP Secret Manager**
  (auth via the Workload-Identity SA), reading the `*-app-secrets` secret with
  `dataFrom.extract`.
- **ServiceAccount**: use the `service_account_annotation` above.
- **Images**: set `global.imageRegistry` to the `artifact_registry_repo_url` output.

## Manual / follow-up steps

1. **Enable Identity Platform** once in the console (Console → Identity Platform →
   Enable). The `firebase-auth` module manages config but the product toggle is
   a one-time action.
2. **Firebase web app**: if the frontend needs the Firebase web config
   (`FIREBASE_API_KEY`, `AUTH_DOMAIN`), register a web app (console or
   `google_firebase_web_app`) — not fully covered here.
3. **GKE node SA + image pulls**: image pulls authenticate as the **node pool's**
   service account, not the Workload Identity SA. Grant that SA
   `roles/artifactregistry.reader` (pass it via
   `artifact_registry.additional_reader_members`).
4. **Scheduler**: `enable_scheduler` stays `false` until `@repo/shared/scheduler`
   has a Cloud Scheduler implementation (the current one is EventBridge-only).
5. **Secret values**: the `app-secrets` secret is seeded with empty placeholders;
   write real values out-of-band (console/CI). Terraform ignores changes to them.

## Notes

- **Postgres (Neon)** and **Temporal Cloud** stay external — only their
  credentials live in Secret Manager (`PG_BASE_URL`, `TEMPORAL_API_KEY`).
- The app is already cloud-abstracted (`CLOUD_PROVIDER`, `AUTH_PROVIDER=firebase`,
  and `KMS_*_KEYRING/KEY` which is GCP-shaped), so no app changes are needed
  except the scheduler.
- One project **per environment** is recommended (cleaner IAM + Firebase config).
