# The bucket name contains the account ID, so scripts/terraform-ci.sh passes the bucket, key,
# region, and lock setting to `terraform init` instead of committing them here.
terraform {
  backend "s3" {}
}
