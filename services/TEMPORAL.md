# Temporal Self-Hosting Guide

This guide covers setting up Temporal for local development and production self-hosting.

## Local Development

### Option 1: Temporal CLI (Recommended)

The simplest way to run Temporal locally:

```bash
# Install
brew install temporal

# Run local dev server (includes UI at http://localhost:8233)
temporal server start-dev
```

This starts:
- Temporal server at `localhost:7233`
- Web UI at `localhost:8233`

### Option 2: Docker Compose

```bash
# Clone Temporal's docker-compose repo
git clone https://github.com/temporalio/docker-compose.git
cd docker-compose

# Start Temporal
docker compose up -d
```

This starts:
- Temporal server at `localhost:7233`
- Web UI at `localhost:8080`

## Configuration

### Environment Variables

| Variable | Description | Example |
|----------|-------------|---------|
| `TEMPORAL_HOST` | Temporal server address | `localhost:7233` |
| `TEMPORAL_NAMESPACE` | Namespace for workflows | `default` |
| `TEMPORAL_TASK_QUEUE` | Task queue name | `dynamic-workflow-task-queue-dev` |
| `TEMPORAL_TLS` | Enable TLS | `false` for local, `true` for production |
| `TEMPORAL_API_KEY` | API key (Temporal Cloud only) | - |

### Local Development `.env`

```bash
TEMPORAL_HOST=localhost:7233
TEMPORAL_NAMESPACE=default
TEMPORAL_TASK_QUEUE=dynamic-workflow-task-queue-dev
TEMPORAL_TLS=false
```

## Namespace Setup

### Create a Namespace

```bash
temporal operator namespace create my-namespace

# With retention period (default 72h)
temporal operator namespace create my-namespace --retention 7d
```

### Register Search Attributes

The application uses custom search attributes for filtering workflows:

```bash
temporal operator search-attribute create --namespace default \
  --name TenantId --type Keyword \
  --name UserId --type Keyword
```

Verify registration:
```bash
temporal operator search-attribute list --namespace default
```

## Production Self-Hosting

### TLS Options

#### No TLS (Development Only)
```bash
TEMPORAL_TLS=false
```

#### TLS with API Key (Temporal Cloud)
```bash
TEMPORAL_TLS=true
TEMPORAL_API_KEY=your-api-key
```

#### mTLS with Certificates (Self-Hosted Production)

1. **Generate CA and certificates:**

```bash
# Generate CA
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 1825 -out ca.crt \
  -subj "/CN=Temporal CA"

# Generate server cert
openssl genrsa -out temporal-server.key 2048
openssl req -new -key temporal-server.key -out temporal-server.csr \
  -subj "/CN=temporal.your-domain.com"
openssl x509 -req -in temporal-server.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out temporal-server.crt -days 365

# Generate client cert
openssl genrsa -out temporal-client.key 2048
openssl req -new -key temporal-client.key -out temporal-client.csr \
  -subj "/CN=temporal-client"
openssl x509 -req -in temporal-client.csr -CA ca.crt -CAkey ca.key \
  -CAcreateserial -out temporal-client.crt -days 365
```

2. **Configure environment:**

```bash
TEMPORAL_TLS_CA=/path/to/ca.crt
TEMPORAL_TLS_CERT=/path/to/temporal-client.crt
TEMPORAL_TLS_KEY=/path/to/temporal-client.key
```

### AWS Options

#### AWS Private Certificate Authority (ACM PCA)
For production mTLS with AWS-managed certificates:

```bash
# Export CA cert
aws acm-pca get-certificate-authority-certificate \
  --certificate-authority-arn arn:aws:acm-pca:region:account:certificate-authority/xxx \
  --output text > ca.pem
```

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│     Server      │────▶│    Temporal     │◀────│     Worker      │
│  (API/Routes)   │     │     Server      │     │  (Activities)   │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │
        │                       ▼
        │               ┌─────────────────┐
        │               │   PostgreSQL    │
        │               │  (Persistence)  │
        │               └─────────────────┘
        │
        ▼
┌─────────────────┐
│   Temporal UI   │
│ (localhost:8233)│
└─────────────────┘
```

## Connection Management

The application uses a singleton Temporal client:

1. **Initialization**: `initializeTemporalService()` called once at server startup
2. **Usage**: `getTemporalService().getClient()` returns the shared client
3. **Connection handling**: gRPC handles transient connection issues automatically

## Troubleshooting

### "Namespace has no mapping defined for search attribute"
Register the required search attributes:
```bash
temporal operator search-attribute create --namespace default \
  --name TenantId --type Keyword \
  --name UserId --type Keyword
```

### "Temporal client not initialized"
Ensure `initializeTemporalService()` is called at startup before any workflow operations.

### Connection issues
- Verify `TEMPORAL_HOST` is correct
- Check `TEMPORAL_TLS` matches your server configuration
- For local dev, ensure Temporal server is running

## Resources

- [Temporal Documentation](https://docs.temporal.io/)
- [Temporal TypeScript SDK](https://docs.temporal.io/develop/typescript)
- [Temporal Cloud](https://temporal.io/cloud) - Managed solution
- [Temporal GitHub](https://github.com/temporalio/temporal)
