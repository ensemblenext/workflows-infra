import * as cdk from 'aws-cdk-lib';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as kms from 'aws-cdk-lib/aws-kms';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as scheduler from 'aws-cdk-lib/aws-scheduler';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

export interface WorkflowsStackProps extends cdk.StackProps {
  environment: string;
  eksClusterName: string;
  eksOidcProviderArn?: string;
  namespace: string;
  bucketPrefix?: string;
  serviceRootDomain?: string;
  enableCognito?: boolean;

  // Existing resources (optional) - leave undefined to create new
  existingKmsKeyArn?: string;
  existingUserFilesBucket?: string;
  existingDocumentsBucket?: string;
  existingTenantMigrationsBucket?: string;
}

export class WorkflowsStack extends cdk.Stack {
  // Public references for cross-stack usage
  // Using interfaces (IBucket, IKey) to support both created and imported resources
  public readonly userFilesBucket: s3.IBucket;
  public readonly documentsBucket: s3.IBucket;
  public readonly tenantMigrationsBucket: s3.IBucket;
  public readonly encryptionKey: kms.IKey;
  public readonly schedulerRole: iam.Role;
  public readonly workloadsRole: iam.Role;
  public readonly cognitoUserPool?: cognito.UserPool;
  public readonly cognitoUserPoolClient?: cognito.UserPoolClient;

  constructor(scope: Construct, id: string, props: WorkflowsStackProps) {
    super(scope, id, props);

    const {
      environment,
      eksClusterName,
      eksOidcProviderArn,
      namespace,
      bucketPrefix,
      serviceRootDomain,
      enableCognito,
      existingKmsKeyArn,
      existingUserFilesBucket,
      existingDocumentsBucket,
      existingTenantMigrationsBucket,
    } = props;
    const prefix = bucketPrefix || `workflows-${environment}`;
    const rootDomain = serviceRootDomain || 'example.com';

    // ============================================
    // KMS Key for Encryption
    // ============================================
    if (existingKmsKeyArn) {
      // Use existing KMS key
      this.encryptionKey = kms.Key.fromKeyArn(this, 'EncryptionKey', existingKmsKeyArn);
    } else {
      // Create new KMS key
      this.encryptionKey = new kms.Key(this, 'EncryptionKey', {
        alias: `${prefix}-encryption-key`,
        description: 'KMS key for Workflows platform encryption',
        enableKeyRotation: true,
        removalPolicy: cdk.RemovalPolicy.RETAIN,
      });
    }

    // ============================================
    // S3 Buckets
    // ============================================

    // User files bucket
    if (existingUserFilesBucket) {
      // Use existing bucket
      this.userFilesBucket = s3.Bucket.fromBucketName(this, 'UserFilesBucket', existingUserFilesBucket);
    } else {
      // Create new bucket with S3-managed encryption (SSE-S3)
      this.userFilesBucket = new s3.Bucket(this, 'UserFilesBucket', {
        bucketName: `${prefix}-user-files`,
        encryption: s3.BucketEncryption.S3_MANAGED,
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        versioned: true,
        removalPolicy: cdk.RemovalPolicy.RETAIN,
        cors: [
          {
            allowedMethods: [s3.HttpMethods.GET, s3.HttpMethods.PUT, s3.HttpMethods.POST],
            allowedOrigins: ['*'], // Restrict in production
            allowedHeaders: ['*'],
            maxAge: 3000,
          },
        ],
        lifecycleRules: [
          {
            id: 'DeleteOldVersions',
            noncurrentVersionExpiration: cdk.Duration.days(90),
          },
        ],
      });
    }

    // Documents bucket
    if (existingDocumentsBucket) {
      // Use existing bucket
      this.documentsBucket = s3.Bucket.fromBucketName(this, 'DocumentsBucket', existingDocumentsBucket);
    } else {
      // Create new bucket with S3-managed encryption (SSE-S3)
      this.documentsBucket = new s3.Bucket(this, 'DocumentsBucket', {
        bucketName: `${prefix}-documents`,
        encryption: s3.BucketEncryption.S3_MANAGED,
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        versioned: true,
        removalPolicy: cdk.RemovalPolicy.RETAIN,
        lifecycleRules: [
          {
            id: 'DeleteOldVersions',
            noncurrentVersionExpiration: cdk.Duration.days(90),
          },
        ],
      });
    }

    // Tenant migrations bucket
    if (existingTenantMigrationsBucket) {
      // Use existing bucket
      this.tenantMigrationsBucket = s3.Bucket.fromBucketName(this, 'TenantMigrationsBucket', existingTenantMigrationsBucket);
    } else {
      // Create new bucket with S3-managed encryption (SSE-S3)
      this.tenantMigrationsBucket = new s3.Bucket(this, 'TenantMigrationsBucket', {
        bucketName: `${prefix}-tenant-migrations`,
        encryption: s3.BucketEncryption.S3_MANAGED,
        blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
        versioned: true,
        removalPolicy: cdk.RemovalPolicy.RETAIN,
      });
    }

    // ============================================
    // EventBridge Scheduler Role
    // ============================================
    this.schedulerRole = new iam.Role(this, 'SchedulerRole', {
      roleName: `${prefix}-scheduler-role`,
      assumedBy: new iam.ServicePrincipal('scheduler.amazonaws.com'),
      description: 'IAM role for EventBridge Scheduler to invoke targets',
    });

    // EventBridge Scheduler group
    new scheduler.CfnScheduleGroup(this, 'SchedulerGroup', {
      name: `${prefix}-schedules`,
    });

    // ============================================
    // Cognito User Pool (Optional)
    // ============================================
    if (enableCognito !== false) {
      this.cognitoUserPool = new cognito.UserPool(this, 'UserPool', {
        userPoolName: `${prefix}-users`,
        selfSignUpEnabled: true,
        signInAliases: {
          email: true,
        },
        autoVerify: {
          email: true,
        },
        standardAttributes: {
          email: {
            required: true,
            mutable: true,
          },
          fullname: {
            required: false,
            mutable: true,
          },
        },
        passwordPolicy: {
          minLength: 8,
          requireLowercase: true,
          requireUppercase: true,
          requireDigits: true,
          requireSymbols: false,
        },
        accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
        removalPolicy: cdk.RemovalPolicy.RETAIN,
      });

      // Add Google OAuth provider (optional - configure in console or add here)
      // this.cognitoUserPool.registerIdentityProvider(
      //   new cognito.UserPoolIdentityProviderGoogle(this, 'Google', {
      //     userPool: this.cognitoUserPool,
      //     clientId: 'your-google-client-id',
      //     clientSecretValue: cdk.SecretValue.secretsManager('google-oauth-secret'),
      //     scopes: ['email', 'profile', 'openid'],
      //     attributeMapping: {
      //       email: cognito.ProviderAttribute.GOOGLE_EMAIL,
      //       fullname: cognito.ProviderAttribute.GOOGLE_NAME,
      //     },
      //   })
      // );

      this.cognitoUserPoolClient = new cognito.UserPoolClient(this, 'UserPoolClient', {
        userPool: this.cognitoUserPool,
        userPoolClientName: `${prefix}-web-client`,
        generateSecret: false, // For web/SPA clients
        authFlows: {
          userPassword: true,
          userSrp: true,
        },
        oAuth: {
          flows: {
            authorizationCodeGrant: true,
          },
          scopes: [
            cognito.OAuthScope.EMAIL,
            cognito.OAuthScope.OPENID,
            cognito.OAuthScope.PROFILE,
          ],
          callbackUrls: [
            'http://localhost:3000/auth/callback',
            `https://${prefix}.${rootDomain}/auth/callback`,
          ],
          logoutUrls: [
            'http://localhost:3000',
            `https://${prefix}.${rootDomain}`,
          ],
        },
        preventUserExistenceErrors: true,
        accessTokenValidity: cdk.Duration.hours(1),
        idTokenValidity: cdk.Duration.hours(1),
        refreshTokenValidity: cdk.Duration.days(30),
      });

      // Add domain for hosted UI (optional)
      this.cognitoUserPool.addDomain('CognitoDomain', {
        cognitoDomain: {
          domainPrefix: `${prefix}-auth`,
        },
      });
    }

    // ============================================
    // IAM Role for EKS Workloads (IRSA)
    // ============================================
    if (eksOidcProviderArn) {
      // Extract OIDC provider URL from ARN
      const oidcProviderUrl = cdk.Fn.select(1, cdk.Fn.split(':oidc-provider/', eksOidcProviderArn));

      this.workloadsRole = new iam.Role(this, 'WorkloadsRole', {
        roleName: `${prefix}-workloads-role`,
        assumedBy: new iam.FederatedPrincipal(
          eksOidcProviderArn,
          {
            StringEquals: {
              [`${oidcProviderUrl}:aud`]: 'sts.amazonaws.com',
              [`${oidcProviderUrl}:sub`]: `system:serviceaccount:${namespace}:workflows-sa`,
            },
          },
          'sts:AssumeRoleWithWebIdentity'
        ),
        description: 'IAM role for Workflows pods running in EKS',
      });
    } else {
      // Create a standard role for non-EKS environments
      this.workloadsRole = new iam.Role(this, 'WorkloadsRole', {
        roleName: `${prefix}-workloads-role`,
        assumedBy: new iam.ServicePrincipal('ec2.amazonaws.com'),
        description: 'IAM role for Workflows workloads',
      });
    }

    // ============================================
    // Permissions for Workloads Role
    // ============================================

    // S3 permissions
    this.userFilesBucket.grantReadWrite(this.workloadsRole);
    this.documentsBucket.grantReadWrite(this.workloadsRole);
    this.tenantMigrationsBucket.grantReadWrite(this.workloadsRole);

    // KMS permissions
    this.encryptionKey.grantEncryptDecrypt(this.workloadsRole);

    // EventBridge Scheduler permissions
    this.workloadsRole.addToPolicy(new iam.PolicyStatement({
      sid: 'EventBridgeSchedulerManagement',
      effect: iam.Effect.ALLOW,
      actions: [
        'scheduler:CreateSchedule',
        'scheduler:GetSchedule',
        'scheduler:UpdateSchedule',
        'scheduler:DeleteSchedule',
        'scheduler:ListSchedules',
      ],
      resources: [
        `arn:aws:scheduler:${this.region}:${this.account}:schedule/${prefix}-schedules/*`,
        `arn:aws:scheduler:${this.region}:${this.account}:schedule/default/*`,
      ],
    }));

    // Allow passing the scheduler role
    this.workloadsRole.addToPolicy(new iam.PolicyStatement({
      sid: 'PassSchedulerRole',
      effect: iam.Effect.ALLOW,
      actions: ['iam:PassRole'],
      resources: [this.schedulerRole.roleArn],
      conditions: {
        StringEquals: {
          'iam:PassedToService': 'scheduler.amazonaws.com',
        },
      },
    }));

    // Cognito permissions (if enabled)
    if (this.cognitoUserPool) {
      this.workloadsRole.addToPolicy(new iam.PolicyStatement({
        sid: 'CognitoUserManagement',
        effect: iam.Effect.ALLOW,
        actions: [
          'cognito-idp:AdminGetUser',
          'cognito-idp:AdminCreateUser',
          'cognito-idp:AdminUpdateUserAttributes',
          'cognito-idp:AdminDisableUser',
          'cognito-idp:AdminEnableUser',
          'cognito-idp:ListUsers',
        ],
        resources: [this.cognitoUserPool.userPoolArn],
      }));
    }

    // Secrets Manager permissions (for app secrets)
    this.workloadsRole.addToPolicy(new iam.PolicyStatement({
      sid: 'SecretsManagerAccess',
      effect: iam.Effect.ALLOW,
      actions: [
        'secretsmanager:GetSecretValue',
        'secretsmanager:DescribeSecret',
      ],
      resources: [
        `arn:aws:secretsmanager:${this.region}:${this.account}:secret:${prefix}/*`,
      ],
    }));

    // ============================================
    // Scheduler Role Permissions
    // ============================================

    // Allow scheduler to invoke HTTP endpoints (via Lambda or API Gateway)
    // For direct HTTP invocation, you'd need an API Destination
    this.schedulerRole.addToPolicy(new iam.PolicyStatement({
      sid: 'InvokeTargets',
      effect: iam.Effect.ALLOW,
      actions: [
        'lambda:InvokeFunction',
        'states:StartExecution',
        'events:PutEvents',
      ],
      resources: ['*'], // Restrict to specific resources in production
    }));

    // ============================================
    // Secrets Manager Secret Template
    // ============================================
    const appSecrets = new secretsmanager.Secret(this, 'AppSecrets', {
      secretName: `${prefix}/app-secrets`,
      description: 'Application secrets for Workflows platform',
      generateSecretString: {
        secretStringTemplate: JSON.stringify({
          ANTHROPIC_API_KEY: '',
          OPENAI_API_KEY: '',
          TEMPORAL_API_KEY: '',
          TEMPORAL_ADDRESS: '',
          DATABASE_PASSWORD: '',
          // Firebase credentials (if using Firebase)
          FIREBASE_PROJECT_ID: '',
          FIREBASE_CLIENT_EMAIL: '',
          FIREBASE_PRIVATE_KEY: '',
        }),
        generateStringKey: 'GENERATED_SECRET', // Placeholder
      },
    });

    // Allow workloads to read this secret
    appSecrets.grantRead(this.workloadsRole);

    // ============================================
    // Outputs
    // ============================================
    new cdk.CfnOutput(this, 'UserFilesBucketName', {
      value: this.userFilesBucket.bucketName,
      description: 'S3 bucket for user files',
      exportName: `${prefix}-user-files-bucket`,
    });

    new cdk.CfnOutput(this, 'DocumentsBucketName', {
      value: this.documentsBucket.bucketName,
      description: 'S3 bucket for documents',
      exportName: `${prefix}-documents-bucket`,
    });

    new cdk.CfnOutput(this, 'TenantMigrationsBucketName', {
      value: this.tenantMigrationsBucket.bucketName,
      description: 'S3 bucket for tenant migrations',
      exportName: `${prefix}-tenant-migrations-bucket`,
    });

    new cdk.CfnOutput(this, 'EncryptionKeyArn', {
      value: this.encryptionKey.keyArn,
      description: 'KMS key ARN for encryption',
      exportName: `${prefix}-encryption-key-arn`,
    });

    new cdk.CfnOutput(this, 'SchedulerRoleArn', {
      value: this.schedulerRole.roleArn,
      description: 'IAM role ARN for EventBridge Scheduler',
      exportName: `${prefix}-scheduler-role-arn`,
    });

    new cdk.CfnOutput(this, 'WorkloadsRoleArn', {
      value: this.workloadsRole.roleArn,
      description: 'IAM role ARN for EKS workloads',
      exportName: `${prefix}-workloads-role-arn`,
    });

    new cdk.CfnOutput(this, 'AppSecretsArn', {
      value: appSecrets.secretArn,
      description: 'Secrets Manager secret ARN',
      exportName: `${prefix}-app-secrets-arn`,
    });

    if (this.cognitoUserPool) {
      new cdk.CfnOutput(this, 'CognitoUserPoolId', {
        value: this.cognitoUserPool.userPoolId,
        description: 'Cognito User Pool ID',
        exportName: `${prefix}-cognito-user-pool-id`,
      });

      new cdk.CfnOutput(this, 'CognitoUserPoolClientId', {
        value: this.cognitoUserPoolClient!.userPoolClientId,
        description: 'Cognito User Pool Client ID',
        exportName: `${prefix}-cognito-client-id`,
      });

      new cdk.CfnOutput(this, 'CognitoUserPoolArn', {
        value: this.cognitoUserPool.userPoolArn,
        description: 'Cognito User Pool ARN',
        exportName: `${prefix}-cognito-user-pool-arn`,
      });
    }

    // Output environment variables for Helm
    new cdk.CfnOutput(this, 'HelmConfigValues', {
      value: JSON.stringify({
        CLOUD_PROVIDER: 'aws',
        AWS_REGION: this.region,
        STORAGE_USER_FILES_BUCKET: this.userFilesBucket.bucketName,
        STORAGE_DOCUMENTS_BUCKET: this.documentsBucket.bucketName,
        STORAGE_TENANT_MIGRATIONS_BUCKET: this.tenantMigrationsBucket.bucketName,
        KMS_KEY_ARN: this.encryptionKey.keyArn,
        SCHEDULER_ROLE_ARN: this.schedulerRole.roleArn,
        SCHEDULER_GROUP_NAME: `${prefix}-schedules`,
        ...(this.cognitoUserPool && {
          AUTH_PROVIDER: 'cognito',
          COGNITO_USER_POOL_ID: this.cognitoUserPool.userPoolId,
          COGNITO_REGION: this.region,
        }),
      }, null, 2),
      description: 'Environment variables for Helm chart',
    });
  }
}
