output "alb_sg_id" {
  value = aws_security_group.this["alb"].id
}

output "management_sg_id" {
  value = aws_security_group.this["management"].id
}

output "backend_sg_id" {
  value = aws_security_group.this["backend"].id
}

output "mon_sg_id" {
  value = aws_security_group.this["mon"].id
}

output "rds_sg_id" {
  value = aws_security_group.this["rds"].id
}
