resource "random_password" "master" {
  length           = 24
  special          = true
  override_special = "_-"
}

resource "aws_db_subnet_group" "this" {
  name        = "${var.project}-db"
  description = "Private subnets for ${var.project} RDS"
  subnet_ids  = var.private_subnet_ids

  tags = { Name = "${var.project}-db" }
}

# RDS identifiers must start with a letter, hence the prefix-first names.
resource "aws_db_parameter_group" "this" {
  name        = "pg16-${var.project}"
  family      = "postgres16"
  description = "${var.project} PostgreSQL 16 parameters"

  # Log slow statements (>1 s) so the CloudWatch log group has something useful.
  parameter {
    name  = "log_min_duration_statement"
    value = "1000"
  }

  tags = { Name = "${var.project}-postgres16" }
}

resource "aws_db_instance" "this" {
  identifier = "db-${var.project}"

  engine                = "postgres"
  engine_version        = var.engine_version
  instance_class        = var.instance_class
  allocated_storage     = var.allocated_storage
  max_allocated_storage = 0
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.db_name
  username = var.master_username
  password = random_password.master.result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [var.rds_sg_id]
  parameter_group_name   = aws_db_parameter_group.this.name
  publicly_accessible    = false
  multi_az               = false

  backup_retention_period = 7
  backup_window           = "20:00-21:00"
  maintenance_window      = "sun:21:30-sun:22:30"
  copy_tags_to_snapshot   = true

  auto_minor_version_upgrade   = true
  performance_insights_enabled = false

  # Ship slow-query (and other postgres) logs to CloudWatch (see the
  # log_min_duration_statement parameter above).
  enabled_cloudwatch_logs_exports = ["postgresql"]

  # Disposable demo: no final snapshot and no deletion guard so `destroy` is
  # one step. For a real environment set skip_final_snapshot = false and
  # deletion_protection = true.
  skip_final_snapshot = true
  deletion_protection = false
  apply_immediately   = true

  tags = { Name = "${var.project}-db" }
}
