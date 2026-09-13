output "management_instance_id" {
  value = aws_instance.management.id
}

output "backend_instance_id" {
  value = aws_instance.backend.id
}

output "mon_instance_id" {
  value = aws_instance.mon.id
}

output "management_eip" {
  value = aws_eip.management.public_ip
}

output "backend_private_ip" {
  value = aws_instance.backend.private_ip
}

output "mon_private_ip" {
  value = aws_instance.mon.private_ip
}

output "role_arns" {
  description = "role => IAM role ARN"
  value       = { for k, r in aws_iam_role.this : k => r.arn }
}
