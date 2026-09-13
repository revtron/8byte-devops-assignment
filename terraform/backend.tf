# Partial backend configuration: bucket/key/region/lock table are supplied at
# init time from a file that is not committed (see backend.hcl.example):
#   terraform init -backend-config=backend.hcl
terraform {
  backend "s3" {}
}
