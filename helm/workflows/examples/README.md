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

## Secret Keys

See `references/server-variables.yaml` for the full list of secrets.

**Required:**
- `PG_BASE_URL` - PostgreSQL connection string (without database name)
- `TEMPORAL_API_KEY` - Temporal Cloud API key

**Optional:**
- `SYSTEM_DB_NAME` - Database name (defaults to "system")
- `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`, `GEMINI_API_KEY` - LLM providers
- `ELEVENLABS_API_KEY` - Text-to-speech
- `SLACK_BOT_TOKEN`, `SLACK_SIGNING_SECRET` - Slack integration
- `TWILIO_*` - Twilio integration
- `NEON_*` - Neon database
- `RESEND_API_KEY`, `SENDGRID_API_KEY` - Email services
