# See envs/dev/backend.tf for backend-config usage notes.
# Initialize with:
#
#   terraform init \
#     -backend-config="bucket=webhook-platform-tfstate-<account>-<region>" \
#     -backend-config="region=us-east-1" \
#     -backend-config="dynamodb_table=webhook-platform-tfstate-lock"
