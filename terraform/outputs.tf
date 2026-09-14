output "alb_dns_name" {
  value = module.alb.alb_dns_name
}

output "prod_url" {
  value = "http://${module.alb.alb_dns_name}"
}

output "staging_url" {
  value = "http://${module.alb.alb_dns_name}:8080"
}

output "grafana_url" {
  description = "Grafana through the ALB; admitted from admin_cidr only."
  value       = "http://${module.alb.alb_dns_name}:3000"
}

output "prometheus_url" {
  description = "Prometheus through the ALB; admitted from admin_cidr only."
  value       = "http://${module.alb.alb_dns_name}:9090"
}

output "management_eip" {
  value = module.compute.management_eip
}

output "jenkins_url" {
  description = "Jenkins UI on the management EIP; the security group admits :8080 from admin_cidr only."
  value       = "http://${module.compute.management_eip}:8080/"
}

output "backend_private_ip" {
  value = module.compute.backend_private_ip
}

output "mon_private_ip" {
  value = module.compute.mon_private_ip
}

output "management_instance_id" {
  value = module.compute.management_instance_id
}

output "backend_instance_id" {
  value = module.compute.backend_instance_id
}

output "mon_instance_id" {
  value = module.compute.mon_instance_id
}

output "rds_endpoint" {
  value = module.database.endpoint
}

output "db_secret_arn" {
  value = module.secrets.db_secret_arn
}

output "sns_topic_arn" {
  value = module.notifications.topic_arn
}

output "state_bucket" {
  description = "Remote state bucket (same name the bootstrap root creates)."
  value       = "${var.project}-tfstate-${local.account_id}"
}

output "alb_logs_bucket" {
  value = module.alb.logs_bucket
}

output "ssh_config" {
  description = "Block for ~/.ssh/config; consumed by scripts/setup-ssh.*"
  value = templatefile("${path.module}/templates/ssh_config.tftpl", {
    management_ip = module.compute.management_eip
    backend_ip    = module.compute.backend_private_ip
    mon_ip        = module.compute.mon_private_ip
  })
}
