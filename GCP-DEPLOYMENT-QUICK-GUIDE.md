# GCP Deployment Quick Guide

How to deploy the platform to the GKE cluster. Four commands and a health check.

You do **not** need to create any cloud resources, secrets, or service accounts —
those already exist. If something here fails because a resource is missing, that
is a job for whoever owns the infrastructure; see
[GCP-DEPLOYMENT-BUILD.md](./GCP-DEPLOYMENT-BUILD.md) and hand it to them.

## What you need

- `gcloud` and the GKE auth plugin (`gke-gcloud-auth-plugin`)
- `kubectl`
- `helm`
- Access to the `automator-502518` GCP project
- A checkout of this repo (the chart is deployed from it)

## Step 1: Connect to the cluster

```bash
gcloud auth login

gcloud container clusters get-credentials ensemble-workflows \
  --region us-west1 --project automator-502518

kubectl get nodes
```

`kubectl get nodes` should list a few nodes. If it does, you're pointed at the
right cluster.

> **kubectl and helm only talk to one cluster at a time.** They use the
> `current-context` in `~/.kube/config`, which is saved to disk and shared by
> every terminal window until you change it — it is not per-terminal. If you (or
> anything else) previously pointed it at a different cluster, your commands go
> there instead. The `get-credentials` command above switches it to GKE.
>
> To check or re-select it later:
>
> ```bash
> kubectl config current-context   # should print gke_automator-502518_us-west1_ensemble-workflows
> kubectl config use-context gke_automator-502518_us-west1_ensemble-workflows
> ```
>
> If you see `Reauthentication failed`, your Google login expired — run
> `gcloud auth login` again.

## Step 2: Deploy

From the root of the repo:

```bash
helm upgrade --install workflows infrastructure/helm/workflows \
  -f infrastructure/helm/workflows/gke-test-values.yaml \
  -n workflows
```

`upgrade --install` works for both the first deploy and every one after, so this
is the only command you need.

Watch it come up:

```bash
kubectl get pods -n workflows -w   # Ctrl-C to stop watching
```

A database migration Job runs **first** and the app pods wait for it. Expect a
minute or two before everything reads `Running`. Pods cycling through
`Init`/`PodInitializing` during that window is normal.

## Step 3: Verify

```bash
kubectl port-forward deploy/workflows-server 3001:3001 -n workflows &
kubectl port-forward deploy/workflows-web    3000:3000 -n workflows &

curl http://localhost:3001/health     # expect 200
open http://localhost:3000            # web app
```

There is no public ingress — port-forwarding is how you reach it. Stop the
forwards with `kill %1 %2` when you're done.

## If something goes wrong

Start here:

```bash
kubectl get pods -n workflows                        # what state is everything in?
kubectl logs -f deploy/workflows-server -n workflows # server logs
kubectl describe pod <pod-name> -n workflows | grep -A10 Events
```

Common states and what they mean:

| What you see | What it usually means |
|---|---|
| `ImagePullBackOff` | The image isn't published, or the cluster can't pull it. Infra issue — needs the build guide. |
| `CrashLoopBackOff` on the server | Check the logs. Most often a missing or wrong value in the `app-secrets` Secret. |
| Pods stuck `Pending` | The cluster is out of capacity, or a node pool problem. Infra issue. |
| The migration Job fails | `kubectl logs job/<job-name> -n workflows`. Usually the database is unreachable. |
| Pods `Running` but the app errors on file upload, secrets, or connections | Workload Identity / storage / KMS aren't wired up. Infra issue. |
| A 500 from any AI feature | The configured LLM model family may not exist in this environment. Infra issue. |

You can safely re-run the Step 2 command at any time — it is idempotent.

## Rolling back

```bash
helm history workflows -n workflows          # find the revision to go back to
helm rollback workflows <REVISION> -n workflows
```

## Restarting without changing anything

Occasionally you'll be asked to restart the pods — for example after someone
updates a credential, since pods only read those at startup:

```bash
kubectl rollout restart deployment -n workflows
```

## Notes

- Deploying a new build of the app usually means **nothing changes in this
  guide** — the images are rebuilt and published elsewhere, and you re-run Step 2
  to pick them up.
- `helm uninstall workflows -n workflows` removes the app. It leaves the
  namespace, the secrets, and all cloud resources in place, so a later Step 2
  brings it straight back.
