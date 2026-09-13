output "endpoint" {
  description = "host:port"
  value       = aws_db_instance.this.endpoint
}

output "address" {
  description = "Hostname only."
  value       = aws_db_instance.this.address
}

output "port" {
  value = aws_db_instance.this.port
}

output "username" {
  value = aws_db_instance.this.username
}

output "password" {
  value     = random_password.master.result
  sensitive = true
}

output "db_name" {
  value = aws_db_instance.this.db_name
}

output "instance_id" {
  value = aws_db_instance.this.id
}
