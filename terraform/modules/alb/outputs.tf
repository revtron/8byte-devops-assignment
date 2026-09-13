output "alb_arn" {
  value = aws_lb.this.arn
}

output "alb_dns_name" {
  value = aws_lb.this.dns_name
}

output "target_group_arns" {
  description = "env => target group ARN"
  value       = { for k, tg in aws_lb_target_group.this : k => tg.arn }
}

output "logs_bucket" {
  value = aws_s3_bucket.logs.bucket
}
