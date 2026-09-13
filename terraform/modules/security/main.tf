# One security group per role. Rules live in separate resources because the
# backend <-> mon rules reference each other's group (Terraform would report
# a cycle if they were inline).

locals {
  groups = {
    alb        = "Internet-facing ALB"
    management = "Bastion + Jenkins"
    backend    = "Application host"
    mon        = "Monitoring host"
    rds        = "PostgreSQL"
  }
}

resource "aws_security_group" "this" {
  for_each = local.groups

  name        = "${var.project}-${each.key}"
  description = "${each.value} (${var.project})"
  vpc_id      = var.vpc_id

  tags = { Name = "${var.project}-${each.key}" }
}

resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = local.groups

  security_group_id = aws_security_group.this[each.key].id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- alb: 80 (prod), 8080 (staging) from anywhere ----------------------------

resource "aws_vpc_security_group_ingress_rule" "alb_public" {
  for_each = toset(["80", "8080"])

  security_group_id = aws_security_group.this["alb"].id
  description       = "HTTP ${each.key} from the internet"
  ip_protocol       = "tcp"
  from_port         = tonumber(each.key)
  to_port           = tonumber(each.key)
  cidr_ipv4         = "0.0.0.0/0"
}

# ---- management: 22 from admin_cidr -----------------------------------------

resource "aws_vpc_security_group_ingress_rule" "management_ssh" {
  security_group_id = aws_security_group.this["management"].id
  description       = "SSH from admin"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = var.admin_cidr
}

# ---- backend -----------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "backend_from_alb" {
  for_each = toset(["3000", "3001"])

  security_group_id            = aws_security_group.this["backend"].id
  description                  = "App port ${each.key} from ALB"
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
  referenced_security_group_id = aws_security_group.this["alb"].id
}

resource "aws_vpc_security_group_ingress_rule" "backend_ssh" {
  security_group_id            = aws_security_group.this["backend"].id
  description                  = "SSH from management"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.this["management"].id
}

resource "aws_vpc_security_group_ingress_rule" "backend_from_mon" {
  for_each = toset(["9100", "3000", "3001"])

  security_group_id            = aws_security_group.this["backend"].id
  description                  = "Prometheus scrape ${each.key} from mon"
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.key)
  to_port                      = tonumber(each.key)
  referenced_security_group_id = aws_security_group.this["mon"].id
}

# ---- mon ---------------------------------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "mon_ssh" {
  security_group_id            = aws_security_group.this["mon"].id
  description                  = "SSH from management"
  ip_protocol                  = "tcp"
  from_port                    = 22
  to_port                      = 22
  referenced_security_group_id = aws_security_group.this["management"].id
}

resource "aws_vpc_security_group_ingress_rule" "mon_loki_from_backend" {
  security_group_id            = aws_security_group.this["mon"].id
  description                  = "Loki push from backend promtail"
  ip_protocol                  = "tcp"
  from_port                    = 3100
  to_port                      = 3100
  referenced_security_group_id = aws_security_group.this["backend"].id
}

# ---- rds: 5432 from backend and mon ------------------------------------------

resource "aws_vpc_security_group_ingress_rule" "rds_postgres" {
  for_each = toset(["backend", "mon"])

  security_group_id            = aws_security_group.this["rds"].id
  description                  = "PostgreSQL from ${each.key}"
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
  referenced_security_group_id = aws_security_group.this[each.key].id
}
