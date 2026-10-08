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
| `sqs` | `cloud-tasks` | Cloud Tasks queues (**push**: no consumer, no DLQ) |

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

## Background task queue

Backs `TASK_QUEUE_PROVIDER=cloud-tasks`. Evaluation runs queue one task per test case,
and inbound webhooks are processed out of band.

```hcl
# environments/prod.tfvars
enable_task_queue = true
```

```bash
terraform apply -var-file=environments/prod.tfvars

# The queue settings are included in the chart config output when enabled:
terraform output -json helm_config_values

# Or just the queue-specific subset:
terraform output task_queue_env
```

**Create the queues before enabling the queue on the services.** With
`TASK_QUEUE_ENABLED=true` and no queue to enqueue into, every evaluation run is marked
failed rather than falling back to in-process execution.

### How this differs from the SQS stack

Cloud Tasks is **push**-based: it performs the callback itself, with an OIDC token it
mints per dispatch. SQS only holds messages, so the AWS stack needs the worker to poll
them and make the call. Three consequences:

- **The worker needs no queue configuration at all.** `task_queue_env` is for the
  server only. There is no `SQS_CONSUMER_QUEUES` equivalent, and nothing to size.
- **No dead-letter queues.** A task that exhausts `max_attempts` is dropped. The run's
  staleness sweep, which runs in the worker, is what settles a run whose cases stopped
  arriving.
- **No Cognito equivalent.** Cloud Tasks presents a Google OIDC token, and the server
  verifies that it came from `GCP_SERVICE_ACCOUNT` — so there is no M2M client to
  provision, and no shared scope to keep in step across two services.

Concurrency is a property of the queue here, not of a consumer process:
`max_concurrent_dispatches` defaults to 2. That is the only limit on how many cases
call the model provider at once, and each case makes at least two calls (the agent,
then a judge), so raise it deliberately.

### Permissions

The module grants the workloads SA `roles/cloudtasks.enqueuer` on each queue, and
`roles/iam.serviceAccountUser` on itself. The second one is easy to miss: naming a
service account as an OIDC token's identity is an impersonation, so the principal
creating the task needs `iam.serviceAccounts.actAs` on it. Here the creator and the
identity are the same account, and a service account does not hold `actAs` on itself
implicitly.

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
6. **Cloud Tasks API**: enabled automatically with `enable_task_queue` while
   `enable_apis = true`. If you manage API enablement yourself, turn on
   `cloudtasks.googleapis.com` before applying, or queue creation fails.

## Notes

- **Postgres (Neon)** and **Temporal Cloud** stay external — only their
  credentials live in Secret Manager (`PG_BASE_URL`, `TEMPORAL_API_KEY`).
- The app is already cloud-abstracted (`CLOUD_PROVIDER`, `AUTH_PROVIDER=firebase`,
  and `KMS_*_KEYRING/KEY` which is GCP-shaped), so no app changes are needed
  except the scheduler.
- One project **per environment** is recommended (cleaner IAM + Firebase config).
