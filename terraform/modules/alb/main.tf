resource "aws_lb" "this" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  access_logs {
    bucket  = aws_s3_bucket.logs.bucket
    prefix  = var.project
    enabled = true
  }

  tags = { Name = "${var.project}-alb" }

  depends_on = [aws_s3_bucket_policy.logs]
}

locals {
  # env => host port on the backend instance
  target_groups = {
    prod    = 3000
    staging = 3001
  }

  # env => listener port on the ALB
  listeners = {
    prod    = 80
    staging = 8080
  }
}

resource "aws_lb_target_group" "this" {
  for_each = local.target_groups

  name        = "${var.project}-${each.key}"
  port        = each.value
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.project}-${each.key}" }
}

resource "aws_lb_target_group_attachment" "backend" {
  for_each = local.target_groups

  target_group_arn = aws_lb_target_group.this[each.key].arn
  target_id        = var.backend_instance_id
  port             = each.value
}

resource "aws_lb_listener" "this" {
  for_each = local.listeners

  load_balancer_arn = aws_lb.this.arn
  port              = each.value
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  tags = { Name = "${var.project}-${each.key}-listener" }
}

# ---- monitoring UIs on the mon host, same port on the ALB ---------------------
# The ALB security group admits these ports from admin_cidr only (see the
# security module), so this is an operator convenience, not a public surface.

locals {
  mon_uis = {
    grafana    = { port = 3000, health = "/api/health" }
    prometheus = { port = 9090, health = "/-/healthy" }
  }
}

resource "aws_lb_target_group" "mon" {
  for_each = local.mon_uis

  name        = "${var.project}-${each.key}"
  port        = each.value.port
  protocol    = "HTTP"
  target_type = "instance"
  vpc_id      = var.vpc_id

  health_check {
    path                = each.value.health
    matcher             = "200"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.project}-${each.key}" }
}

resource "aws_lb_target_group_attachment" "mon" {
  for_each = local.mon_uis

  target_group_arn = aws_lb_target_group.mon[each.key].arn
  target_id        = var.mon_instance_id
  port             = each.value.port
}

resource "aws_lb_listener" "mon" {
  for_each = local.mon_uis

  load_balancer_arn = aws_lb.this.arn
  port              = each.value.port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mon[each.key].arn
  }

  tags = { Name = "${var.project}-${each.key}-listener" }
}
