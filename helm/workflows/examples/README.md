# External Secrets Examples

This directory contains example SecretStore and ExternalSecret configurations for different secret providers.

## Prerequisites

1. Install External Secrets Operator:
```bash
helm repo add external-secrets https://charts.external-secrets.io
helm install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace
```

## Usage

1. Choose your provider and apply the SecretStore:
```bash
kubectl apply -f secret-store-<provider>.yaml -n workflows
```

2. Configure your Helm values:
```yaml
externalSecrets:
  enabled: true
  secretStoreRef:
    name: <secret-store-name>  # e.g., aws-secrets-manager, doppler-store, vault-backend
    kind: SecretStore
  remoteRef: <your-secret-path>  # e.g., workflows-prod/app-secrets
  refreshInterval: 1h
```

Each provider example includes both the SecretStore and ExternalSecret resources:
```bash
kubectl apply -f secret-store-<provider>.yaml -n workflows
```

3. Install the Helm chart:
```bash
helm install workflows . -f your-values.yaml
```

## Provider Examples

| Provider | SecretStore Name | Example remoteRef |
|----------|------------------|-------------------|
| AWS Secrets Manager | `aws-secrets-manager` | `workflows-prod/app-secrets` |
| Doppler | `doppler-store` | `WORKFLOWS_PROD` (project name) |
| HashiCorp Vault | `vault-backend` | `secret/data/workflows/prod` |

## Required Secret Keys

Your external secret should contain these keys:
- `DATABASE_URL`
- `TEMPORAL_API_KEY`
- `ELEVENLABS_API_KEY`
- `OPENAI_API_KEY`
- `ANTHROPIC_API_KEY`
- `CEREBRAS_API_KEY`
- `MOONSHOTAI_API_KEY`
- `ZHIPU_API_KEY`
- `NEON_API_KEY`
- `NEON_BRANCH`
- `NEON_OWNER_NAME`
- `NEON_PROJECT`
- `RESEND_API_KEY`
