#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { WorkflowsStack } from '../lib/workflows-stack';

const app = new cdk.App();

// Get configuration from context or environment
const environment = app.node.tryGetContext('environment') || 'dev';
const eksClusterName = app.node.tryGetContext('eksClusterName') || 'workflows-cluster';
const eksOidcProviderArn = app.node.tryGetContext('eksOidcProviderArn');
const namespace = app.node.tryGetContext('namespace') || 'workflows';
const serviceRootDomain = app.node.tryGetContext('serviceRootDomain') || 'example.com';

// Existing resources (optional) - leave undefined to create new
const existingKmsKeyArn = app.node.tryGetContext('existingKmsKeyArn');
const existingUserFilesBucket = app.node.tryGetContext('existingUserFilesBucket');
const existingDocumentsBucket = app.node.tryGetContext('existingDocumentsBucket');
const existingTenantMigrationsBucket = app.node.tryGetContext('existingTenantMigrationsBucket');

new WorkflowsStack(app, `Workflows-${environment}`, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION || 'us-west-2',
  },
  environment,
  eksClusterName,
  eksOidcProviderArn,
  namespace,
  serviceRootDomain,

  // Existing resources (leave undefined to create new)
  existingKmsKeyArn,
  existingUserFilesBucket,
  existingDocumentsBucket,
  existingTenantMigrationsBucket,

  // Optional: customize resource names
  // bucketPrefix: 'my-company-workflows',
  // serviceRootDomain: 'example.com',
  // enableCognito: true,
});
