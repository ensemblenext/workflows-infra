# Workflows Infrastructure

Infrastructure assets for deploying the Workflows platform on Kubernetes.

This repository contains:

- A Helm chart for the application workloads
- Terraform modules for AWS supporting resources
- AWS CDK stacks for the same AWS supporting resources
- Deployment guides for EKS and GKE
- Example External Secrets Operator configuration for AWS Secrets Manager, Doppler, and Vault

## Repository Layout

```text
.
├── aws-cdk/                # AWS CDK implementation for supporting AWS resources
├── helm/workflows/         # Helm chart for Workflows workloads
├── resources/aws/          # AWS CloudFormation and IAM policy resources
├── terraform/              # Terraform implementation for supporting AWS resources
├── AWS-DEPLOYMENT-GUIDE.md
├── AWS-CUSTOMER-DEPLOYMENT-GUIDE.md
├── DEPLOY-EKS.md
└── DEPLOY-GKE.md
```

## Deployment Options

Use one infrastructure path for AWS supporting resources:

- **Terraform**: see [terraform/README.md](terraform/README.md)
- **AWS CDK**: see [aws-cdk/README.md](aws-cdk/README.md)

Then deploy the application with the Helm chart in [helm/workflows](helm/workflows).

For end-to-end guides:

- [EKS deployment](DEPLOY-EKS.md)
- [GKE deployment](DEPLOY-GKE.md)
- [AWS deployment guide](AWS-DEPLOYMENT-GUIDE.md)
- [AWS customer deployment guide](AWS-CUSTOMER-DEPLOYMENT-GUIDE.md)

## What Gets Provisioned

The Terraform and CDK implementations are intended to create supporting AWS resources, not the EKS cluster itself.

Typical resources include:

- S3 buckets for user files, documents, and tenant migrations
- KMS key for encryption
- IAM roles for Kubernetes workloads and EventBridge Scheduler
- EventBridge Scheduler group
- Optional Cognito user pool and app client
- AWS Secrets Manager secret template

## Helm Chart

The Helm chart lives in [helm/workflows](helm/workflows).

Common files:

- [values.yaml](helm/workflows/values.yaml): base chart values
- [eks-values.sample.yaml](helm/workflows/eks-values.sample.yaml): sample EKS values
- [gke-values.sample.yaml](helm/workflows/gke-values.sample.yaml): sample GKE values
- [examples](helm/workflows/examples): External Secrets Operator examples

Install example:

```bash
helm install workflows ./helm/workflows -f helm/workflows/eks-values.sample.yaml
```

For real deployments, copy a sample values file to a local file and customize it:

```bash
cp helm/workflows/eks-values.sample.yaml helm/workflows/eks-values.local.yaml
```

Local values files matching `helm/workflows/*.local.yaml` are ignored by Git.

## Secrets

Do not commit real secret values.

The Helm chart supports External Secrets Operator. Provider examples are available in:

- [secret-store-aws.yaml](helm/workflows/examples/secret-store-aws.yaml)
- [secret-store-doppler.yaml](helm/workflows/examples/secret-store-doppler.yaml)
- [secret-store-vault.yaml](helm/workflows/examples/secret-store-vault.yaml)

The expected secret variable names are listed in [helm/workflows/examples/secrets.txt](helm/workflows/examples/secrets.txt).

## Terraform

Initialize and plan from the Terraform directory:

```bash
cd terraform
terraform init
terraform plan -var-file=environments/sample.tfvars
```

Keep real environment values in ignored files such as:

- `terraform/environments/dev.tfvars`
- `terraform/environments/prod.tfvars`
- `terraform/terraform.tfvars`

Commit sanitized examples such as:

- `terraform/terraform.tfvars.example`
- `terraform/environments/sample.tfvars`

## AWS CDK

Install and build from the CDK directory:

```bash
cd aws-cdk
npm install
npm run build
```

Run CDK commands with context values as needed:

```bash
npx cdk synth \
  --context environment=dev \
  --context serviceRootDomain=example.com
```

## Git Ignore Policy

The repository ignores common generated and local files for:

- Helm package artifacts
- Terraform state, plans, local variables, and crash logs
- AWS CDK build output, synthesized output, and generated JavaScript/type declaration files
- Local Helm values files

Before committing, check for ignored local files and staged changes:

```bash
git status --short --ignored
```

## Safety Notes

- Terraform state can contain sensitive data. Keep it out of Git.
- Local Helm values often contain account IDs, domains, ARNs, and secret references. Keep them out of Git.
- Prefer sanitized sample files using `example.com`, placeholder account IDs, and `example-*` resource names.
- Rotate any credential that was ever committed to Git history.
