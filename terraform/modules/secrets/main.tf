# Four secrets. 8byte/db and 8byte/jenkins get generated values from
# Terraform so hosts can boot without manual steps; 8byte/dockerhub and
# 8byte/github are empty containers filled by scripts/put-secrets.sh so
# those user-owned values never enter Terraform state.

locals {
  placeholders = {
    dockerhub = "Docker Hub credentials {username, token}"
    github    = "GitHub PAT {token}"
  }
}

resource "aws_secretsmanager_secret" "db" {
  name        = "${var.project}/db"
  description = "RDS master credentials {host, port, username, password, dbname_prod, dbname_staging}"

  # Demo: delete immediately so destroy + re-apply does not collide with a
  # secret still in its recovery window.
  recovery_window_in_days = 0

  tags = { Name = "${var.project}/db" }
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  # port is emitted as a JSON number (5432), not a string; consumers using
  # jq -r get "5432" either way.
  secret_string = jsonencode({
    host           = var.db_host
    port           = var.db_port
    username       = var.db_username
    password       = var.db_password
    dbname_prod    = var.db_name_prod
    dbname_staging = var.db_name_staging
  })
}

resource "aws_secretsmanager_secret" "placeholder" {
  for_each = local.placeholders

  name                    = "${var.project}/${each.key}"
  description             = "${each.value} - value written by scripts/put-secrets.sh"
  recovery_window_in_days = 0

  tags = { Name = "${var.project}/${each.key}" }
}

resource "random_password" "jenkins_admin" {
  length           = 20
  special          = true
  override_special = "_-"
}

resource "aws_secretsmanager_secret" "jenkins" {
  name                    = "${var.project}/jenkins"
  description             = "Jenkins admin credentials {admin_password}; also reused as the Grafana admin password"
  recovery_window_in_days = 0

  tags = { Name = "${var.project}/jenkins" }
}

resource "aws_secretsmanager_secret_version" "jenkins" {
  secret_id = aws_secretsmanager_secret.jenkins.id
  secret_string = jsonencode({
    admin_password = random_password.jenkins_admin.result
  })
}
