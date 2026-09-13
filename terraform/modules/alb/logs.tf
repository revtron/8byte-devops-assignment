# Access-log bucket. ALB access logs are written by the regional AWS-owned
# ELB account (718504428378 in ap-south-1), which needs PutObject on the prefix.

data "aws_elb_service_account" "this" {}

resource "aws_s3_bucket" "logs" {
  bucket = "${var.project}-alb-logs-${var.account_id}"

  # Demo only: allow destroy with logs still inside.
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket = aws_s3_bucket.logs.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "expire"
    status = "Enabled"

    filter {}

    expiration {
      days = var.log_retention_days
    }
  }
}

data "aws_iam_policy_document" "logs" {
  statement {
    sid       = "AllowELBAccountPutObject"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.logs.arn}/${var.project}/AWSLogs/${var.account_id}/*"]

    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.this.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "logs" {
  bucket = aws_s3_bucket.logs.id
  policy = data.aws_iam_policy_document.logs.json

  depends_on = [aws_s3_bucket_public_access_block.logs]
}
