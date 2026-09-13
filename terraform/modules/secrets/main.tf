# Four secrets. Only 8byte/db gets a value from Terraform; the other three are
# empty containers filled by scripts/put-secrets.sh so those values never
# enter Terraform state.

locals {
  placeholders = {
    dockerhub = "Docker Hub credentials {username, token}"
    github    = "GitHub PAT {token}"
    jenkins   = "Jenkins admin credentials {admin_password}"
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
