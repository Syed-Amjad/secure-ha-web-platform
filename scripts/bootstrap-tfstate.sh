#!/usr/bin/env bash
# One-time creation of the Terraform remote state backend.
#
# Run this BEFORE uncommenting the backend block in terraform/providers.tf.
# The chicken-and-egg problem is real: Terraform cannot create the bucket that
# holds its own state, so this is deliberately plain AWS CLI.
#
# State encryption is not optional. Terraform state stores generated database
# passwords in PLAINTEXT — whoever can read this bucket can read your database
# credentials.
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="${TFSTATE_BUCKET:-tfstate-${ACCOUNT}-${REGION}}"
TABLE="${TFSTATE_LOCK_TABLE:-terraform-locks}"

echo "==> Account: $ACCOUNT   Region: $REGION"
echo "==> Bucket:  $BUCKET"
echo "==> Table:   $TABLE"

if aws s3api head-bucket --bucket "$BUCKET" 2>/dev/null; then
  echo "    Bucket already exists — skipping creation."
else
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION"
  else
    aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
      --create-bucket-configuration LocationConstraint="$REGION"
  fi
fi

echo "==> Blocking all public access"
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

# Versioning is the undo button for a corrupted or truncated state file.
echo "==> Enabling versioning"
aws s3api put-bucket-versioning --bucket "$BUCKET" \
  --versioning-configuration Status=Enabled

echo "==> Enabling default encryption"
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'

echo "==> Creating the lock table"
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" >/dev/null 2>&1; then
  echo "    Table already exists — skipping."
else
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" >/dev/null
  aws dynamodb wait table-exists --table-name "$TABLE" --region "$REGION"
fi

cat <<EOF

==> Done.

Now edit terraform/providers.tf: uncomment the backend block and set

    bucket         = "$BUCKET"
    region         = "$REGION"
    dynamodb_table = "$TABLE"

then run:

    cd terraform && terraform init -migrate-state
EOF
