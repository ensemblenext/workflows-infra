# Okta OIDC Integration with AWS Cognito

This guide explains how to configure Okta as an OpenID Connect (OIDC) identity provider for AWS Cognito, enabling your users to sign in with their Okta credentials.

## Prerequisites

- An Okta organization (developer or enterprise account)
- An AWS account with Cognito User Pool already created
- AWS CLI configured with appropriate permissions

## Overview

The integration involves two parts:
1. **Okta Configuration**: Create an OIDC application in Okta
2. **AWS Cognito Configuration**: Add Okta as an identity provider in your Cognito User Pool

---

## Part 1: Okta Configuration

### Step 1: Create an OIDC Application in Okta

1. Log in to your **Okta Admin Console** (https://your-domain-admin.okta.com)

2. Navigate to **Applications** > **Applications** in the left sidebar

3. Click **Create App Integration**

4. Select the following options:
   - **Sign-in method**: OIDC - OpenID Connect
   - **Application type**: Web Application

5. Click **Next**

### Step 2: Configure the OIDC Application

Fill in the following fields:

| Field | Value |
|-------|-------|
| **App integration name** | `Ensemble` (or your preferred name) |
| **Grant type** | Check **Authorization Code** (required) |
| **Sign-in redirect URIs** | `https://<your-cognito-domain>.auth.<region>.amazoncognito.com/oauth2/idpresponse` |
| **Sign-out redirect URIs** | `https://<your-app-domain>/login` (optional) |
| **Controlled access** | Choose based on your organization's needs |

> **Note**: Replace `<your-cognito-domain>` with your Cognito domain prefix and `<region>` with your AWS region (e.g., `us-east-1`).

### Step 3: Get Okta Application Credentials

After creating the application, note down the following values from the **General** tab:

| Okta Field | Description |
|------------|-------------|
| **Client ID** | Found in the "Client Credentials" section |
| **Client Secret** | Click "Copy" next to the client secret |
| **Okta Domain** | Your Okta domain (e.g., `your-company.okta.com`) |

### Step 4: Find the Okta OIDC Endpoints

Your Okta issuer URL follows this pattern:
```
https://<your-okta-domain>/oauth2/default
```

For example: `https://your-company.okta.com/oauth2/default`

You can verify the OIDC endpoints by visiting:
```
https://<your-okta-domain>/oauth2/default/.well-known/openid-configuration
```

This returns a JSON document with all OIDC endpoints:
- `authorization_endpoint`
- `token_endpoint`
- `userinfo_endpoint`
- `jwks_uri`

### Step 5: Configure Attribute Statements (Optional)

To pass additional user attributes to Cognito:

1. Go to **Applications** > **Your App** > **Sign On** tab
2. Scroll to **OpenID Connect ID Token**
3. Add attribute statements as needed:

| Name | Value |
|------|-------|
| `email` | `user.email` |
| `given_name` | `user.firstName` |
| `family_name` | `user.lastName` |
| `name` | `user.displayName` |

---

## Part 2: AWS Cognito Configuration

### Option A: Using AWS Console

1. Open the **Amazon Cognito Console**
2. Select your **User Pool**
3. Go to **Sign-in experience** tab
4. Under **Federated identity provider sign-in**, click **Add identity provider**
5. Select **OpenID Connect (OIDC)**

Fill in the fields as follows:

| Cognito Field | Value |
|---------------|-------|
| **Provider name** | `Okta` (must match the provider name used in your app code) |
| **Client ID** | The Client ID from Okta (Step 3 above) |
| **Client secret** | The Client Secret from Okta (Step 3 above) |
| **Authorized scopes** | `openid email profile` |
| **Identifiers** | (Leave empty or add `okta.com` as optional identifier) |
| **Attribute request method** | `GET` |
| **Retrieve OIDC endpoints** | Select **Auto fill through issuer URL** |
| **Issuer URL** | `https://<your-okta-domain>/oauth2/default` |

#### Attribute Mapping

Map Okta attributes to Cognito user pool attributes:

| OIDC attribute | User pool attribute |
|----------------|---------------------|
| `sub` | `Username` |
| `email` | `email` |
| `email_verified` | `email_verified` |
| `given_name` | `given_name` |
| `family_name` | `family_name` |
| `name` | `name` |

### Option B: Using AWS CLI

#### Step 1: Create the OIDC Identity Provider

```bash
# Set your variables
USER_POOL_ID="your-user-pool-id"
OKTA_CLIENT_ID="your-okta-client-id"
OKTA_CLIENT_SECRET="your-okta-client-secret"
OKTA_ISSUER_URL="https://your-company.okta.com/oauth2/default"

# Create the identity provider
aws cognito-idp create-identity-provider \
  --user-pool-id "$USER_POOL_ID" \
  --provider-name "Okta" \
  --provider-type "OIDC" \
  --provider-details '{
    "client_id": "'"$OKTA_CLIENT_ID"'",
    "client_secret": "'"$OKTA_CLIENT_SECRET"'",
    "authorize_scopes": "openid email profile",
    "attributes_request_method": "GET",
    "oidc_issuer": "'"$OKTA_ISSUER_URL"'"
  }' \
  --attribute-mapping '{
    "username": "sub",
    "email": "email",
    "email_verified": "email_verified",
    "given_name": "given_name",
    "family_name": "family_name",
    "name": "name"
  }'
```

#### Step 2: Update the App Client to Support Okta

```bash
# Get your app client ID
APP_CLIENT_ID="your-app-client-id"
CALLBACK_URL="https://your-app-domain.com/auth/callback"
LOGOUT_URL="https://your-app-domain.com/login"

# Update the app client to include Okta as a supported identity provider
aws cognito-idp update-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-id "$APP_CLIENT_ID" \
  --supported-identity-providers "COGNITO" "Okta" \
  --callback-urls "$CALLBACK_URL" \
  --logout-urls "$LOGOUT_URL" \
  --allowed-o-auth-flows "code" \
  --allowed-o-auth-scopes "openid" "email" "profile" \
  --allowed-o-auth-flows-user-pool-client
```

#### Step 3: Verify the Configuration

```bash
# Describe the identity provider
aws cognito-idp describe-identity-provider \
  --user-pool-id "$USER_POOL_ID" \
  --provider-name "Okta"

# List all identity providers
aws cognito-idp list-identity-providers \
  --user-pool-id "$USER_POOL_ID"
```

---

## Complete AWS CLI Script

Here's a complete script to set up Okta integration:

```bash
#!/bin/bash

# ============================================
# Okta OIDC Integration with AWS Cognito
# ============================================

# Configuration - Replace these values
USER_POOL_ID="us-east-1_XXXXXXXXX"
APP_CLIENT_ID="xxxxxxxxxxxxxxxxxxxxxxxxxx"
OKTA_CLIENT_ID="0oaxxxxxxxxxxxxxxxxx"
OKTA_CLIENT_SECRET="your-okta-client-secret"
OKTA_DOMAIN="your-company.okta.com"
APP_DOMAIN="your-app-domain.com"
AWS_REGION="us-east-1"

# Derived values
OKTA_ISSUER_URL="https://${OKTA_DOMAIN}/oauth2/default"
CALLBACK_URL="https://${APP_DOMAIN}/auth/callback"
LOGOUT_URL="https://${APP_DOMAIN}/login"

echo "Creating Okta OIDC Identity Provider..."

# Create the identity provider
aws cognito-idp create-identity-provider \
  --user-pool-id "$USER_POOL_ID" \
  --provider-name "Okta" \
  --provider-type "OIDC" \
  --provider-details "{
    \"client_id\": \"$OKTA_CLIENT_ID\",
    \"client_secret\": \"$OKTA_CLIENT_SECRET\",
    \"authorize_scopes\": \"openid email profile\",
    \"attributes_request_method\": \"GET\",
    \"oidc_issuer\": \"$OKTA_ISSUER_URL\"
  }" \
  --attribute-mapping "{
    \"username\": \"sub\",
    \"email\": \"email\",
    \"email_verified\": \"email_verified\",
    \"given_name\": \"given_name\",
    \"family_name\": \"family_name\",
    \"name\": \"name\"
  }" \
  --region "$AWS_REGION"

if [ $? -eq 0 ]; then
  echo "✅ Identity provider created successfully"
else
  echo "❌ Failed to create identity provider"
  exit 1
fi

echo "Updating App Client to support Okta..."

# Get current app client configuration
CURRENT_CONFIG=$(aws cognito-idp describe-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-id "$APP_CLIENT_ID" \
  --region "$AWS_REGION" \
  --query 'UserPoolClient' \
  --output json)

# Update the app client
aws cognito-idp update-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-id "$APP_CLIENT_ID" \
  --supported-identity-providers "COGNITO" "Okta" \
  --callback-urls "$CALLBACK_URL" \
  --logout-urls "$LOGOUT_URL" \
  --allowed-o-auth-flows "code" \
  --allowed-o-auth-scopes "openid" "email" "profile" \
  --allowed-o-auth-flows-user-pool-client \
  --region "$AWS_REGION"

if [ $? -eq 0 ]; then
  echo "✅ App client updated successfully"
else
  echo "❌ Failed to update app client"
  exit 1
fi

echo ""
echo "============================================"
echo "Okta OIDC Integration Complete!"
echo "============================================"
echo ""
echo "Next steps:"
echo "1. Ensure your Okta app has the correct redirect URI:"
echo "   https://<cognito-domain>.auth.${AWS_REGION}.amazoncognito.com/oauth2/idpresponse"
echo ""
echo "2. Test the integration by signing in with Okta"
echo ""
```

---

## Updating an Existing Identity Provider

If you need to update the Okta configuration:

```bash
aws cognito-idp update-identity-provider \
  --user-pool-id "$USER_POOL_ID" \
  --provider-name "Okta" \
  --provider-details '{
    "client_id": "'"$NEW_OKTA_CLIENT_ID"'",
    "client_secret": "'"$NEW_OKTA_CLIENT_SECRET"'",
    "authorize_scopes": "openid email profile",
    "attributes_request_method": "GET",
    "oidc_issuer": "'"$OKTA_ISSUER_URL"'"
  }' \
  --attribute-mapping '{
    "username": "sub",
    "email": "email",
    "email_verified": "email_verified",
    "given_name": "given_name",
    "family_name": "family_name",
    "name": "name"
  }'
```

---

## Deleting the Identity Provider

If you need to remove the Okta integration:

```bash
# First, remove Okta from the app client's supported identity providers
aws cognito-idp update-user-pool-client \
  --user-pool-id "$USER_POOL_ID" \
  --client-id "$APP_CLIENT_ID" \
  --supported-identity-providers "COGNITO"

# Then delete the identity provider
aws cognito-idp delete-identity-provider \
  --user-pool-id "$USER_POOL_ID" \
  --provider-name "Okta"
```

---

## Troubleshooting

### Common Issues

1. **"Invalid redirect URI" error in Okta**
   - Ensure the redirect URI in Okta exactly matches:
     `https://<cognito-domain>.auth.<region>.amazoncognito.com/oauth2/idpresponse`
   - Check for trailing slashes

2. **"Invalid client_id" error**
   - Verify the Client ID is copied correctly from Okta
   - Ensure the Okta application is active (not deactivated)

3. **User attributes not mapping correctly**
   - Verify attribute statements are configured in Okta
   - Check the attribute mapping in Cognito matches Okta's claim names
   - Use the Okta token preview feature to verify claims

4. **"Invalid issuer" error**
   - Ensure the issuer URL follows the format: `https://<domain>/oauth2/default`
   - For custom authorization servers, use: `https://<domain>/oauth2/<server-id>`

5. **CORS errors during sign-in**
   - Add your application domain to Okta's trusted origins:
     Okta Admin > Security > API > Trusted Origins

### Verifying OIDC Configuration

Test your Okta OIDC configuration:

```bash
# Fetch the OpenID configuration
curl -s "https://your-company.okta.com/oauth2/default/.well-known/openid-configuration" | jq .
```

This should return a JSON document with all the OIDC endpoints.

---

## Reference: Field Mapping Summary

| AWS Cognito Field | Source/Value |
|-------------------|--------------|
| Provider name | `Okta` |
| Client ID | From Okta app's "Client Credentials" |
| Client secret | From Okta app's "Client Credentials" |
| Authorized scopes | `openid email profile` |
| Identifiers | (Optional) Leave empty |
| Attribute request method | `GET` |
| Retrieve OIDC endpoints | Auto fill through issuer URL |
| Issuer URL | `https://<okta-domain>/oauth2/default` |

---

## Security Recommendations

1. **Rotate client secrets periodically** - Update the secret in both Okta and Cognito
2. **Use a custom authorization server** - For production, consider creating a dedicated authorization server in Okta
3. **Limit scopes** - Only request the scopes your application needs
4. **Enable MFA in Okta** - Add an extra layer of security for your users
5. **Monitor sign-in activity** - Use Okta's system log and AWS CloudTrail to track authentication events
