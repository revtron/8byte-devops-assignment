output "vpc_id" {
  value = aws_vpc.this.id
}

output "vpc_cidr" {
  value = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public subnet ids in AZ order."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet ids in AZ order."
  value       = aws_subnet.private[*].id
}

output "nat_public_ip" {
  value = aws_eip.nat.public_ip
}
