# Development environment configuration

aws_region   = "us-west-2"
environment  = "dev"
project_name = "workflows"

# EKS Configuration
eks_cluster_name         = "workflows-dev"
eks_namespace            = "workflows"
eks_service_account_name = "workflows-sa"
# eks_oidc_provider_arn  = "" # Set after EKS cluster is created

# Feature Flags
enable_cognito   = true
enable_scheduler = true

# Background Task Queue (SQS)
#
# Backs TASK_QUEUE_PROVIDER=sqs. Creates evaluation-cases and webhook-processor, each
# with a dead-letter queue, and grants the workloads role SendMessage, ReceiveMessage
# and DeleteMessage on them.
#
# Order matters: create the queues before setting TASK_QUEUE_ENABLED=true on the
# services. With the queue enabled and nothing to enqueue into, every evaluation run is
# marked failed rather than falling back to in-process execution.
enable_task_queue = false

# After apply, `terraform output task_queue_env` prints the settings the services need.
# Queues are named <project>-<environment>-<queue>, so one account can hold several
# environments -- which means the application's own defaults ("evaluation-cases",
# "webhook-processor") no longer match and EVALUATION_QUEUE_NAME, WEBHOOK_QUEUE_NAME
# and SQS_CONSUMER_QUEUES have to be set explicitly. That output is the easiest way to
# get them right.

# Per-queue overrides. The defaults suit an evaluation case, which invokes an agent and
# then has a model judge the answer, so it is allowed 600s. Override to add a queue or
# to change one's timing:
#
# task_queues = {
#   "evaluation-cases"  = {}
#   "webhook-processor" = { visibility_timeout_seconds = 90, max_receive_count = 5 }
#   "export-jobs"       = {}
# }
#
# Note that the consumer sets the visibility timeout per receive from its own
# SQS_HANDLER_TIMEOUT_SECONDS, which is per process rather than per queue. A lower
# value here only takes effect for a consumer configured to match it.

# EventBridge Scheduler callback delivery
scheduler_api_destination_endpoint = "https://workflows-dev.example.com/api/scheduler/callback"

# Option 1: API Key authentication (simpler)
scheduler_api_destination_auth_type     = "API_KEY"
scheduler_api_destination_api_key_name  = "x-api-key"
scheduler_api_destination_api_key_value = "replace-with-a-strong-shared-secret"

# Option 2: Cognito OAuth M2M authentication (more secure)
# Uncomment the following and comment out Option 1:
# scheduler_api_destination_auth_type  = "OAUTH_CLIENT_CREDENTIALS"
# cognito_enable_scheduler_oauth       = true
# cognito_scheduler_api_identifier     = "https://workflows-dev.example.com/api"

# Cognito URLs
cognito_callback_urls = [
  "http://localhost:3000/auth/callback"
]
cognito_logout_urls = [
  "http://localhost:3000"
]

# S3 Configuration - more permissive for dev
s3_force_destroy                      = true
s3_versioning_enabled                 = true
s3_noncurrent_version_expiration_days = 30
