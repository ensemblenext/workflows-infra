variable "name_prefix" { type = string }
variable "location" { type = string }
variable "workloads_sa_email" { type = string }

# One key ring holding the three app crypto keys. The app addresses them via
# KMS_{SECRETS,CONNECTIONS,ENVIRONMENT}_{KEYRING,KEY}.
resource "google_kms_key_ring" "this" {
  name     = "${var.name_prefix}-keyring"
  location = var.location
}

resource "google_kms_crypto_key" "keys" {
  for_each = toset(["secrets", "connections", "environment"])

  name            = "${var.name_prefix}-${each.key}"
  key_ring        = google_kms_key_ring.this.id
  purpose         = "ENCRYPT_DECRYPT"
  rotation_period = "7776000s" # 90 days

  # KMS keys can't be truly deleted, only versions destroyed — guard against
  # accidental removal from state.
  lifecycle {
    prevent_destroy = true
  }
}

# Let the workloads SA encrypt/decrypt with each key.
resource "google_kms_crypto_key_iam_member" "workloads" {
  for_each = google_kms_crypto_key.keys

  crypto_key_id = each.value.id
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${var.workloads_sa_email}"
}

output "key_ring_name" {
  value = google_kms_key_ring.this.name
}

output "key_names" {
  value = { for k, v in google_kms_crypto_key.keys : k => v.name }
}
