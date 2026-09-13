output "state_bucket" {
  description = "S3 bucket holding the main root's remote state."
  value       = aws_s3_bucket.tfstate.bucket
}

output "lock_table" {
  description = "DynamoDB table used for state locking."
  value       = aws_dynamodb_table.tflock.name
}

output "region" {
  description = "Region of the state bucket."
  value       = var.region
}
